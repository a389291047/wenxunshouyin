import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import '../models/login_model.dart';
import '../models/goods_model.dart'; // 外部模型文件（包含GoodsCat、Goods、CartItem）
import 'settlement_page.dart';

// 图片URL拼接常量（严格遵循你的规则）
const String _imageDomain = 'https://shop.wx-zf.com';
const String _goodsSegment = '/goods';

enum OrderPageMode { shouyin, diandan }

// 挂单模型（使用外部导入的CartItem）
class OrderHang {
  final String id;
  final String name;
  final List<CartItem> cartItems;
  final double totalPrice;
  final DateTime createTime;

  OrderHang({
    required this.id,
    required this.name,
    required this.cartItems,
    required this.totalPrice,
    required this.createTime,
  });
}

class OrderPage extends StatefulWidget {
  final OrderPageMode mode;
  const OrderPage({super.key, required this.mode});

  @override
  State<OrderPage> createState() => _OrderPageState();
}

// 【修复1：购物车数据页面切换消失】继承AutomaticKeepAliveClientMixin，保留页面状态
class _OrderPageState extends State<OrderPage> with AutomaticKeepAliveClientMixin {
  // 页面状态
  List<GoodsCat> _categories = [];
  List<Goods> _goodsList = [];
  List<Goods> _filteredGoods = [];
  List<CartItem> _cartItems = [];
  int? _selectedCatId;
  bool _isLoading = true;
  String? _errorMessage;
  final UserInfoManager _userManager = UserInfoManager();
  final String _goodsApiUrl = 'https://shop.wx-zf.com/shouyin/goodscat/catt';
  String? _currentWenxunId;
  final TextEditingController _searchController = TextEditingController();
  int _noCodeGoodsId = -1;
  bool _isNoCodePopupOpen = false;

  // 挂单相关
  List<OrderHang> _hangOrders = [];
  bool _isHangListOpen = false;

  // 无码商品控制器
  final TextEditingController _noCodeAmountController = TextEditingController();
  final TextEditingController _noCodeNameController = TextEditingController(text: "无码商品");
  final TextEditingController _noCodeGuigeController = TextEditingController(text: "无规格");
  bool _isNoCodeKeyboardActive = false;

  // 连续扫码修复核心配置
  late FocusNode _searchFocusNode;
  Timer? _scanDebounceTimer;
  static const _scanDebounceDelay = Duration(milliseconds: 300);
  String _lastScanContent = '';

  // 【修复1：必须重写】启用页面状态保留
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _searchFocusNode = FocusNode();
    _fetchGoodsData();
    // 【修正：调整listener顺序，先筛选后处理扫码，避免防抖影响搜索】
    _searchController.addListener(_filterGoodsBySearch);
    _searchController.addListener(_handleScanDebounce);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _noCodeAmountController.dispose();
    _noCodeNameController.dispose();
    _noCodeGuigeController.dispose();
    _searchFocusNode.dispose();
    _scanDebounceTimer?.cancel();
    super.dispose();
  }

  // ====================== 连续扫码修复核心方法（仅修正：区分扫码/手动输入） ======================
  void _handleScanDebounce() {
    final inputText = _searchController.text.trim().toLowerCase();
    if (inputText.isEmpty) {
      _scanDebounceTimer?.cancel();
      _lastScanContent = '';
      return;
    }

    // 【核心修正1：判断是否为手动输入（包含中文=商品名称查询，不触发扫码）】
    bool isManualInput = RegExp(r'[\u4e00-\u9fa5]').hasMatch(inputText);
    if (isManualInput) {
      _scanDebounceTimer?.cancel();
      _lastScanContent = '';
      return; // 中文输入仅做搜索筛选，不触发扫码逻辑
    }

    _scanDebounceTimer?.cancel();
    _scanDebounceTimer = Timer(_scanDebounceDelay, () {
      if (mounted && inputText != _lastScanContent) {
        _handleBarcodeScan(inputText);
        _lastScanContent = inputText;
      }
    });
  }

  void _handleBarcodeScan(String scanText) {
    if (scanText.isEmpty) return;

    final matchedGoods = _goodsList.firstWhere(
          (g) => g.code.trim().toLowerCase() == scanText || g.jianpin.trim().toLowerCase() == scanText,
      orElse: () => Goods(
        id: -1,
        name: '',
        title: '',
        amount: 0.0,
        goodsImage: '',
        code: '',
        catId: 0,
        guige: '',
        stock: '不限',
        status: 0,
        wenxunId: 0,
        jianpin: '',
      ),
    );

    if (matchedGoods.id != -1) {
      _addToCart(matchedGoods);
      Future.delayed(const Duration(milliseconds: 50), () {
        if (mounted) {
          _searchController.clear();
          _lastScanContent = '';
        }
      });
      if (!_searchFocusNode.hasFocus) {
        FocusScope.of(context).requestFocus(_searchFocusNode);
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('扫码成功：${matchedGoods.title} x1'),
          backgroundColor: Colors.green,
          duration: const Duration(milliseconds: 500),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('未找到商品：$scanText'),
          backgroundColor: Colors.orange,
          duration: const Duration(seconds: 1),
          behavior: SnackBarBehavior.floating,
        ),
      );
      Future.delayed(const Duration(milliseconds: 50), () {
        if (mounted) {
          _searchController.clear();
          _lastScanContent = '';
        }
      });
      FocusScope.of(context).requestFocus(_searchFocusNode);
    }
  }

  // ====================== 数据获取（原有逻辑，无修改） ======================
  Future<void> _fetchGoodsData() async {
    try {
      _currentWenxunId = await _userManager.getWenxunId();
      if (_currentWenxunId == null || _currentWenxunId!.isEmpty) {
        setState(() {
          _errorMessage = '未获取到商户信息，请重新登录';
          _isLoading = false;
        });
        return;
      }

      final response = await http.post(
        Uri.parse(_goodsApiUrl),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {'wenxun_id': _currentWenxunId},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final List<GoodsCat> filteredCats = (data['cat'] as List)
            .map((item) => GoodsCat.fromJson(item))
            .where((cat) => cat.wenxunId.toString() == _currentWenxunId || cat.wenxunId == int.tryParse(_currentWenxunId ?? ''))
            .toList();
        final List<Goods> filteredGoods = (data['goods'] as List)
            .map((item) => Goods.fromJson(item))
            .where((g) => g.status == 1 && g.catId != 0 && (g.wenxunId.toString() == _currentWenxunId || g.wenxunId == int.tryParse(_currentWenxunId ?? '')))
            .toList();

        setState(() {
          _categories = filteredCats;
          _goodsList = filteredGoods;
          _selectedCatId = _categories.isNotEmpty ? _categories.first.id : null;
          _filterGoodsBySearch();
          _isLoading = false;
        });

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_searchFocusNode.hasFocus) {
            FocusScope.of(context).requestFocus(_searchFocusNode);
          }
        });
      } else {
        setState(() {
          _errorMessage = '数据请求失败：${response.statusCode}';
          _isLoading = false;
        });
      }
    } on TimeoutException {
      setState(() {
        _errorMessage = '请求超时，请检查网络';
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = '加载失败：${e.toString()}';
        _isLoading = false;
      });
    }
  }

  // ====================== 筛选逻辑（原有逻辑，无修改） ======================
  void _filterGoodsByCategory(int catId) {
    setState(() => _selectedCatId = catId);
    _filterGoodsBySearch();
    FocusScope.of(context).requestFocus(_searchFocusNode);
  }

  void _filterGoodsBySearch() {
    final searchText = _searchController.text.trim().toLowerCase();
    List<Goods> tempGoods = [];

    if (searchText.isNotEmpty) {
      tempGoods = _goodsList.where((g) =>
      g.title.toLowerCase().contains(searchText) ||
          g.code.toLowerCase().contains(searchText) ||
          g.guige.toLowerCase().contains(searchText) ||
          g.jianpin.toLowerCase().contains(searchText)
      ).toList();
    } else {
      tempGoods = _goodsList.where((g) => g.catId == _selectedCatId).toList();
    }

    setState(() => _filteredGoods = tempGoods);
  }

  // ====================== 数字键盘通用方法（适配数量/金额两种场景） ======================
  void _onNumericKeyPressed(String key, TextEditingController controller, bool isQuantity) {
    final currentText = controller.text.trim();

    setState(() {
      if (key == '←') {
        // 退格逻辑
        if (currentText.isNotEmpty) {
          controller.text = currentText.substring(0, currentText.length - 1);
        }
      } else if (key == '00' && isQuantity) {
        // 【修复：修正字符串插值语法错误】
        if (currentText.isEmpty) {
          controller.text = '0'; // 空值时输入00变为0
        } else if (currentText == '0') {
          controller.text = '0'; // 已有0时输入00仍为0
        } else {
          // 正确写法：用 ${变量} 明确插值范围，再拼接00
          controller.text = '${currentText}00';
          // 也可以用字符串拼接：controller.text = currentText + '00';
        }
      } else if (key == '.' && !isQuantity) {
        // 金额模式下的小数点逻辑
        if (!currentText.contains('.')) {
          controller.text = currentText.isEmpty ? '0.' : '$currentText.';
        }
      } else if (RegExp(r'^\d$').hasMatch(key)) {
        // 数字键逻辑
        if (!isQuantity && currentText.contains('.')) {
          final decimalPart = currentText.split('.').last;
          if (decimalPart.length >= 2) return; // 金额小数位最多2位
        }
        if (currentText == '0') {
          controller.text = key; // 替换初始的0
          return;
        }
        controller.text = '$currentText$key';
      }
    });

    // 确保光标始终在末尾
    controller.selection = TextSelection.fromPosition(
      TextPosition(offset: controller.text.length),
    );
  }

  Widget _buildNumericKeyboard(TextEditingController controller, bool isQuantity) {
    // 【修改2：数量模式键盘布局，将小数点替换为00】
    final List<List<String>> keys = isQuantity
        ? [['1', '2', '3'], ['4', '5', '6'], ['7', '8', '9'], ['0', '00', '←']] // 数量键盘（00替换小数点）
        : [['1', '2', '3'], ['4', '5', '6'], ['7', '8', '9'], ['0', '.', '←']]; // 金额键盘（保留小数点）

    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200, width: 1),
      ),
      child: Column(
        children: keys.map((row) {
          return Expanded(
            flex: 1,
            child: Row(
              children: row.map((key) {
                return Expanded(
                  flex: 1,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: _buildKeyButton(key, () => _onNumericKeyPressed(key, controller, isQuantity)),
                  ),
                );
              }).toList(),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildKeyButton(String key, VoidCallback onPressed) {
    bool _isPressed = false;

    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) {
        setState(() => _isPressed = false);
        onPressed();
      },
      onTapCancel: () => setState(() => _isPressed = false),
      child: Container(
        decoration: BoxDecoration(
          color: _isPressed ? Colors.red.shade100 : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade200, width: 1),
          boxShadow: [
            BoxShadow(
              blurRadius: 3,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: key == '←'
            ? const Icon(Icons.backspace, size: 26, color: Colors.red)
            : Text(
          key,
          style: TextStyle(
            fontSize: (key == '.' || key == '00') ? 22 : 22, // 00按钮字体大小适配
            fontWeight: FontWeight.w600,
            color: Colors.black87,
          ),
        ),
      ),
    );
  }

  // ====================== 无码商品弹窗（修复复用数字键盘逻辑） ======================
  void _onNoCodeGoodsTap() {
    _noCodeAmountController.clear();
    _noCodeNameController.text = "无码商品"; // 【修复3：固定4字开头】
    _noCodeGuigeController.text = "无规格";

    // 【修复3：强制保留开头“无码商品”，后面可修改】
    void _nameControllerListener() {
      final text = _noCodeNameController.text;
      if (text.isEmpty || !text.startsWith("无码商品")) {
        _noCodeNameController.text = "无码商品${text.replaceAll("无码商品", "")}";
      }
      // 光标定位到末尾，方便用户修改后面的内容
      _noCodeNameController.selection = TextSelection.fromPosition(
        TextPosition(offset: _noCodeNameController.text.length),
      );
    }

    _noCodeNameController.addListener(_nameControllerListener);

    setState(() => _isNoCodePopupOpen = true);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        // 【修复4：弹窗尺寸统一为屏幕的50%，居中显示】
        final popupSize = MediaQuery.of(context).size.width * 0.5;
        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 8,
          child: SizedBox(
            width: popupSize,
            height: popupSize, // 正方形，尺寸统一
            child: Column(
              children: [
                // 顶部标题栏
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: const BoxDecoration(
                    border: Border(bottom: BorderSide(color: Colors.grey)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Expanded(
                        child: Text(
                          '无码商品',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF333333),
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Color(0xFF666666), size: 22),
                        onPressed: () {
                          Navigator.pop(context);
                          setState(() {
                            _isNoCodePopupOpen = false;
                            _isNoCodeKeyboardActive = false;
                          });
                          _noCodeNameController.removeListener(_nameControllerListener); // 移除监听器
                          FocusScope.of(context).requestFocus(_searchFocusNode);
                          _searchController.clear();
                        },
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 40),
                      ),
                    ],
                  ),
                ),

                // 内容区域
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextField(
                          controller: _noCodeNameController,
                          decoration: InputDecoration(
                            hintText: '请输入商品名称（开头固定“无码商品”）',
                            labelText: '商品名称',
                            labelStyle: const TextStyle(color: Color(0xFF666666)),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(color: Color(0xFFEEEEEE)),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(color: Color(0xFFFF4444), width: 1.5),
                            ),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          ),
                          textInputAction: TextInputAction.next,
                          style: const TextStyle(fontSize: 16),
                        ),
                        const SizedBox(height: 18),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '商品金额（必填）',
                              style: TextStyle(
                                color: Color(0xFFFF4444),
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 6),
                            TextField(
                              controller: _noCodeAmountController,
                              decoration: InputDecoration(
                                hintText: '请输入商品金额（如：68.00）',
                                prefixText: '¥',
                                prefixStyle: const TextStyle(
                                  color: Color(0xFFFF4444),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: const BorderSide(color: Color(0xFFEEEEEE)),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: const BorderSide(color: Color(0xFFFF4444), width: 1.5),
                                ),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                              ),
                              readOnly: true,
                              onTap: () => setState(() => _isNoCodeKeyboardActive = true),
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        TextField(
                          controller: _noCodeGuigeController,
                          decoration: InputDecoration(
                            hintText: '请输入商品规格（可选）',
                            labelText: '商品规格',
                            labelStyle: const TextStyle(color: Color(0xFF666666)),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(color: Color(0xFFEEEEEE)),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(color: Color(0xFFFF4444), width: 1.5),
                            ),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          ),
                          style: const TextStyle(fontSize: 16),
                        ),
                        const SizedBox(height: 20),
                        // 【修复5：数字键盘高度统一为200，复用通用数字键盘】
                        SizedBox(
                          height: 200,
                          child: _buildNumericKeyboard(_noCodeAmountController, false), // 金额模式（显示小数点）
                        ),
                      ],
                    ),
                  ),
                ),

                // 确认按钮
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFF4444),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        elevation: 4,
                      ),
                      onPressed: () {
                        final amountText = _noCodeAmountController.text.trim();
                        if (amountText.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('商品金额为必填项，请输入有效的金额！'),
                              backgroundColor: Colors.red,
                              behavior: SnackBarBehavior.floating,
                              duration: Duration(seconds: 2),
                            ),
                          );
                          return;
                        }

                        final amount = double.tryParse(amountText);
                        if (amount == null || amount <= 0) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('请输入有效的金额（大于0的数字）！'),
                              backgroundColor: Colors.red,
                              behavior: SnackBarBehavior.floating,
                              duration: Duration(seconds: 2),
                            ),
                          );
                          return;
                        }

                        final name = _noCodeNameController.text.trim();
                        final guige = _noCodeGuigeController.text.trim().isEmpty ? "无规格" : _noCodeGuigeController.text.trim();
                        final uniqueId = _noCodeGoodsId--;
                        final code = 'no_code_$uniqueId';
                        final jianpin = 'no_code';

                        _addToCart(Goods(
                          id: uniqueId,
                          name: name,
                          title: name,
                          amount: amount,
                          goodsImage: '',
                          code: code,
                          catId: _selectedCatId ?? 0,
                          guige: guige,
                          stock: '不限',
                          status: 1,
                          wenxunId: int.tryParse(_currentWenxunId ?? '0') ?? 0,
                          jianpin: jianpin,
                        ));

                        Navigator.pop(context);
                        setState(() {
                          _isNoCodePopupOpen = false;
                          _isNoCodeKeyboardActive = false;
                        });
                        _noCodeNameController.removeListener(_nameControllerListener); // 移除监听器
                        FocusScope.of(context).requestFocus(_searchFocusNode);
                        _searchController.clear();

                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('添加无码商品成功：$name（¥${amount.toStringAsFixed(2)}）'),
                            backgroundColor: Colors.green,
                            behavior: SnackBarBehavior.floating,
                            duration: Duration(seconds: 2),
                          ),
                        );
                      },
                      child: const Text('确认'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ).whenComplete(() {
      if (mounted) {
        setState(() {
          _isNoCodePopupOpen = false;
          _isNoCodeKeyboardActive = false;
        });
        _noCodeNameController.removeListener(_nameControllerListener); // 确保移除监听器，防止内存泄漏
        FocusScope.of(context).requestFocus(_searchFocusNode);
        _searchController.clear();
      }
    });
  }

  // ====================== 购物车相关方法（原有逻辑，无修改） ======================
  void _addToCart(Goods goods) {
    setState(() {
      final existingIndex = _cartItems.indexWhere((item) => item.goods.id == goods.id);
      if (existingIndex != -1) {
        _cartItems[existingIndex].quantity++;
      } else {
        _cartItems.add(CartItem(goods: goods));
      }
    });
    if (!_searchFocusNode.hasFocus) {
      FocusScope.of(context).requestFocus(_searchFocusNode);
    }
  }

  void _removeFromCart(Goods goods) {
    setState(() {
      final existingIndex = _cartItems.indexWhere((item) => item.goods.id == goods.id);
      if (existingIndex != -1) {
        final existing = _cartItems[existingIndex];
        if (existing.quantity > 1) {
          existing.quantity--;
        } else {
          _cartItems.removeAt(existingIndex);
        }
      }
    });
  }

  void _deleteCartItem(Goods goods) {
    setState(() {
      _cartItems.removeWhere((item) => item.goods.id == goods.id);
    });
    FocusScope.of(context).requestFocus(_searchFocusNode);
  }

  // ====================== 修改数量弹窗（仅修改此处：移除取消/X、改为点击空白关闭、调整为居中正方形） ======================
  void _showModifyQuantityDialog(CartItem item) {
    final TextEditingController quantityController = TextEditingController(
      text: item.quantity.toString(),
    );

    showDialog(
      context: context,
      barrierDismissible: true, // 点击空白区域关闭弹窗
      builder: (context) {
        // 弹窗尺寸：屏幕宽度的50%，设置为正方形
        final screenWidth = MediaQuery.of(context).size.width;
        final popupSize = screenWidth * 0.5;
        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 8,
          child: SizedBox(
            width: popupSize,
            height: popupSize, // 宽高一致，实现正方形
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 顶部标题栏：移除右上角X按钮，标题居中
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 12),
                    decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: Colors.grey)),
                    ),
                    child: const Text(
                      '修改数量',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF333333),
                      ),
                    ),
                  ),

                  // 内容区域（保留原有样式）
                  const SizedBox(height: 20),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '商品数量（必填）',
                        style: TextStyle(
                          color: Color(0xFFFF4444),
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: quantityController,
                        decoration: InputDecoration(
                          hintText: '请输入商品数量（如：5）',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: Color(0xFFEEEEEE)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: Color(0xFFFF4444), width: 1.5),
                          ),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        ),
                        readOnly: false,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(5),
                        ],
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),

                  // 底部按钮区域：移除取消按钮，仅保留确认按钮并占满宽度
                  const Spacer(),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFF4444),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        elevation: 4,
                      ),
                      onPressed: () {
                        int newQuantity = int.tryParse(quantityController.text) ?? 1;
                        if (newQuantity < 1) newQuantity = 1;

                        setState(() {
                          final index = _cartItems.indexWhere((i) => i.goods.id == item.goods.id);
                          if (index != -1) {
                            _cartItems[index].quantity = newQuantity;
                          }
                        });

                        Navigator.pop(context);
                        FocusScope.of(context).requestFocus(_searchFocusNode);
                      },
                      child: const Text('确认'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ====================== 剩余方法（原有逻辑，无任何修改） ======================
  void _clearCart() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认清空'),
        content: const Text('是否确定清空购物车？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              setState(() => _cartItems.clear());
              Navigator.pop(context);
              FocusScope.of(context).requestFocus(_searchFocusNode);
            },
            child: const Text('确认'),
          ),
        ],
      ),
    );
  }

  void _hangOrder() {
    if (_cartItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('购物车为空，无法挂单')),
      );
      return;
    }

    final TextEditingController nameController = TextEditingController(
      text: '挂单${_hangOrders.length + 1}',
    );

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('挂单命名'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(
            hintText: '请输入挂单名称',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              String name = nameController.text.trim();
              if (name.isEmpty) {
                name = '挂单${_hangOrders.length + 1}';
              }
              List<CartItem> hangCart = _cartItems.map((item) => CartItem(
                goods: item.goods,
                quantity: item.quantity,
              )).toList();
              setState(() {
                _hangOrders.add(OrderHang(
                  id: DateTime.now().millisecondsSinceEpoch.toString(),
                  name: name,
                  cartItems: hangCart,
                  totalPrice: _cartTotal,
                  createTime: DateTime.now(),
                ));
                _cartItems.clear();
              });
              Navigator.pop(context);
              FocusScope.of(context).requestFocus(_searchFocusNode);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('挂单成功：$name')),
              );
            },
            child: const Text('确认'),
          ),
        ],
      ),
    );
  }

  void _restoreHangOrder(OrderHang order) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认恢复'),
        content: Text('是否恢复挂单「${order.name}」？当前购物车数据将被覆盖'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                _cartItems = order.cartItems.map((item) => CartItem(
                  goods: item.goods,
                  quantity: item.quantity,
                )).toList();
                _hangOrders.removeWhere((o) => o.id == order.id);
              });
              Navigator.pop(context);
              FocusScope.of(context).requestFocus(_searchFocusNode);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('已恢复挂单：${order.name}')),
              );
            },
            child: const Text('确认'),
          ),
        ],
      ),
    );
  }

  void _deleteHangOrder(String id) {
    setState(() {
      _hangOrders.removeWhere((o) => o.id == id);
    });
    FocusScope.of(context).requestFocus(_searchFocusNode);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('挂单已删除')),
    );
  }

  void _showHangList() {
    setState(() => _isHangListOpen = true);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '挂单列表',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const Divider(),
            _hangOrders.isEmpty
                ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Text('暂无挂单'),
            )
                : ListView.builder(
              shrinkWrap: true,
              itemCount: _hangOrders.length,
              itemBuilder: (context, index) {
                final order = _hangOrders[index];
                return ListTile(
                  title: Text(order.name),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('总计：¥${order.totalPrice.toStringAsFixed(2)}'),
                      Text(
                        '创建时间：${order.createTime.toString().substring(0, 16)}',
                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.restore, color: Colors.blue),
                        onPressed: () {
                          Navigator.pop(context);
                          _restoreHangOrder(order);
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        onPressed: () => _deleteHangOrder(order.id),
                      ),
                    ],
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _restoreHangOrder(order);
                  },
                );
              },
            ),
          ],
        ),
      ),
    ).whenComplete(() {
      if (mounted) {
        setState(() => _isHangListOpen = false);
      }
      FocusScope.of(context).requestFocus(_searchFocusNode);
    });
  }

  int get _cartTotalCount => _cartItems.fold(0, (sum, item) => sum + item.quantity);

  double get _cartTotal => _cartItems.fold(0, (sum, item) => sum + item.totalPrice);

  void _navigateToSettlement() {
    if (_cartItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.mode == OrderPageMode.shouyin ? '购物车为空，无法结算' : '购物车为空，无法下单')),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SettlementPage(
          cartItems: _cartItems,
          totalPrice: _cartTotal,
          wenxunId: _currentWenxunId,
          mode: widget.mode,
        ),
      ),
    ).then((value) {
      if (value == true) {
        setState(() => _cartItems.clear());
      }
      FocusScope.of(context).requestFocus(_searchFocusNode);
    });
  }

  Widget _dashedDivider() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final boxWidth = constraints.maxWidth;
        const dashWidth = 5.0;
        const dashHeight = 1.0;
        final dashCount = (boxWidth / (2 * dashWidth)).floor();
        return Flex(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          direction: Axis.horizontal,
          children: List.generate(dashCount, (_) {
            return SizedBox(
              width: dashWidth,
              height: dashHeight,
              child: DecoratedBox(
                decoration: BoxDecoration(color: Colors.grey.shade300),
              ),
            );
          }),
        );
      },
    );
  }

  Widget _quantityControlWidget(CartItem item) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth * 0.8;
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(17.5),
              border: Border.all(color: Colors.grey.shade200, width: 1.0),
              color: Colors.white,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Expanded(
                  flex: 1,
                  child: InkWell(
                    onTap: () => _removeFromCart(item.goods),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(17.5),
                      bottomLeft: Radius.circular(17.5),
                    ),
                    child: SizedBox(
                      height: 35.0,
                      child: Center(
                        child: Icon(
                          Icons.remove,
                          color: Colors.red.shade600,
                          size: 18.0,
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  flex: 1,
                  child: Container(
                    height: 35.0,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      border: Border.symmetric(
                        vertical: BorderSide(color: Colors.grey.shade200, width: 0.5),
                      ),
                    ),
                    child: Text(
                      item.quantity.toString(),
                      style: const TextStyle(
                        fontSize: 16.0,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                Expanded(
                  flex: 1,
                  child: InkWell(
                    onTap: () => _addToCart(item.goods),
                    borderRadius: const BorderRadius.only(
                      topRight: Radius.circular(17.5),
                      bottomRight: Radius.circular(17.5),
                    ),
                    child: SizedBox(
                      height: 35.0,
                      child: Center(
                        child: Icon(
                          Icons.add,
                          color: Colors.red.shade600,
                          size: 18.0,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ====================== Build方法（仅修改商品分类样式，其余无变动） ======================
  @override
  Widget build(BuildContext context) {
    // 【修复1：必须调用super.build，否则keepAlive无效】
    super.build(context);

    final screenWidth = MediaQuery.of(context).size.width;
    final rightPanelFlex = widget.mode == OrderPageMode.shouyin ? 1 : 2;
    final rightPanelWidth = screenWidth * (rightPanelFlex / (2 + rightPanelFlex));
    final isSmallScreen = screenWidth < 1200;
    final goodsTitleFontSize = isSmallScreen ? 15.0 : 17.0;

    return Scaffold(
      backgroundColor: Colors.white,
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.red))
          : _errorMessage != null
          ? Center(child: Text(_errorMessage!, style: const TextStyle(color: Colors.red, fontSize: 18)))
          : Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: Container(
              margin: const EdgeInsets.only(left: 10, top: 10, bottom: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(25),
                boxShadow: [BoxShadow(color: Colors.grey.withOpacity(0.3), blurRadius: 10, offset: const Offset(0, 5))],
              ),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Container(
                            height: 70,
                            child: TextField(
                              controller: _searchController,
                              focusNode: _searchFocusNode,
                              // 【核心修正2：启用交互选择，支持手动输入的光标/删除等操作】
                              enableInteractiveSelection: true,
                              keyboardType: TextInputType.text,
                              decoration: InputDecoration(
                                hintText: '扫码/搜索商品...',
                                hintStyle: const TextStyle(fontSize: 16, color: Colors.grey),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(16),
                                  borderSide: const BorderSide(color: Colors.grey),
                                ),
                                prefixIcon: const Icon(Icons.search, size: 26, color: Colors.grey),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 22),
                                filled: true,
                                fillColor: Colors.grey.shade50,
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(16),
                                  borderSide: const BorderSide(color: Colors.red, width: 2),
                                ),
                              ),
                              style: const TextStyle(fontSize: 16),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Divider(height: 1, color: Colors.grey.withOpacity(0.2)),
                  Expanded(
                    child: Row(
                      children: [
                        Container(
                          width: screenWidth / 4 / 2,
                          height: double.infinity,
                          padding: const EdgeInsets.all(8),
                          child: ListView.builder(
                            itemCount: _categories.length,
                            itemExtent: 100,
                            // ========== 核心修改：商品分类样式（调整颜色+取消边框） ==========
                            itemBuilder: (context, index) {
                              final cat = _categories[index];
                              final isSelected = _selectedCatId == cat.id;
                              return GestureDetector(
                                onTap: () => _filterGoodsByCategory(cat.id),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                                  child: Container(
                                    margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                                    decoration: BoxDecoration(
                                      // 选中状态：淡红色背景（匹配示例样式）
                                      color: isSelected ? const Color(0xFFFFE6E6) : Colors.white,
                                      borderRadius: BorderRadius.circular(12),
                                      // 取消边框
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.grey.shade100!,
                                          blurRadius: 2,
                                          offset: const Offset(0, 1),
                                        )
                                      ],
                                    ),
                                    child: Center(
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                        child: Text(
                                          cat.name,
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w500,
                                            // 选中状态：红色文字（匹配示例样式）
                                            color: isSelected ? const Color(0xFFD32F2F) : Colors.black87,
                                            height: 1.2,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            child: _filteredGoods.isEmpty
                                ? const Center(child: Text('暂无商品', style: TextStyle(fontSize: 16)))
                                : GridView.builder(
                              padding: const EdgeInsets.all(10),
                              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: screenWidth > 1000 ? 5 : (screenWidth > 600 ? 4 : 3),
                                crossAxisSpacing: 10,
                                mainAxisSpacing: 10,
                                childAspectRatio: 1.0,
                              ),
                              itemCount: _filteredGoods.length,
                              itemBuilder: (context, index) {
                                final goods = _filteredGoods[index];
                                final fullImageUrl = goods.goodsImage.isNotEmpty
                                    ? '$_imageDomain$_goodsSegment${goods.goodsImage}'
                                    : '';

                                return InkWell(
                                  onTap: () => _addToCart(goods),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: Colors.grey.withOpacity(0.2)),
                                      boxShadow: [BoxShadow(color: Colors.grey.withOpacity(0.1), blurRadius: 3)],
                                    ),
                                    child: Column(
                                      children: [
                                        Expanded(
                                          flex: 3,
                                          child: ClipRRect(
                                            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                                            child: fullImageUrl.isNotEmpty
                                                ? Image.network(
                                              fullImageUrl,
                                              fit: BoxFit.cover,
                                              width: double.infinity,
                                              height: double.infinity,
                                              errorBuilder: (_, __, ___) => Container(
                                                color: Colors.white,
                                              ),
                                              loadingBuilder: (_, child, loadingProgress) =>
                                              loadingProgress == null ? child : Container(
                                                color: Colors.white,
                                                child: const Center(child: CircularProgressIndicator(strokeWidth: 2, color: Colors.red)),
                                              ),
                                            )
                                                : Container(
                                              color: Colors.white,
                                            ), // 核心修改：移除默认图标，仅保留空白占位
                                          ),
                                        ),
                                        Padding(
                                          padding: const EdgeInsets.only(top: 8.0),
                                          child: Text(
                                            goods.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: goodsTitleFontSize,
                                              fontWeight: FontWeight.w500,
                                              color: Colors.black87,
                                            ),
                                          ),
                                        ),
                                        Padding(
                                          padding: const EdgeInsets.symmetric(vertical: 6.0),
                                          child: Text(
                                            '¥${goods.amount.toStringAsFixed(2)}',
                                            style: const TextStyle(
                                              color: Colors.red,
                                              fontSize: 14,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            flex: rightPanelFlex,
            child: Container(
              margin: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(25),
                boxShadow: [BoxShadow(color: Colors.grey.withOpacity(0.3), blurRadius: 10, offset: const Offset(0, 5))],
              ),
              child: Column(
                children: [
                  ClipRect(
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          InkWell(
                            onTap: _onNoCodeGoodsTap,
                            borderRadius: BorderRadius.circular(20),
                            child: Container(
                              width: screenWidth < 600 ? 80.0 : 95.0,
                              height: 60,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: Colors.red.shade500,
                                borderRadius: BorderRadius.circular(16),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.red.shade200,
                                    blurRadius: 5,
                                    offset: const Offset(0, 3),
                                  )
                                ],
                              ),
                              child: const Text(
                                '无码',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    shadows: [
                                      Shadow(
                                        color: Colors.black12,
                                        offset: Offset(1, 1),
                                        blurRadius: 2,
                                      )
                                    ]),
                              ),
                            ),
                          ),
                          Flexible(
                            fit: FlexFit.loose,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                InkWell(
                                  onTap: _cartItems.isEmpty ? null : _clearCart,
                                  borderRadius: BorderRadius.circular(20),
                                  child: Container(
                                    width: 40.0,
                                    height: 60,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: _cartItems.isEmpty ? Colors.grey.shade100 : Colors.white,
                                      borderRadius: BorderRadius.circular(16),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.grey.shade200,
                                          blurRadius: 2,
                                          offset: const Offset(0, 1),
                                        )
                                      ],
                                    ),
                                    child: Icon(
                                      Icons.delete_sweep,
                                      color: _cartItems.isEmpty ? Colors.grey.shade400 : Colors.red,
                                      size: 24,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 5),
                                InkWell(
                                  onTap: _cartItems.isEmpty ? null : _hangOrder,
                                  borderRadius: BorderRadius.circular(20),
                                  child: Container(
                                    width: 40.0,
                                    height: 60,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: _cartItems.isEmpty ? Colors.grey.shade100 : Colors.white,
                                      borderRadius: BorderRadius.circular(16),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.grey.shade200,
                                          blurRadius: 2,
                                          offset: const Offset(0, 1),
                                        )
                                      ],
                                    ),
                                    child: Icon(
                                      Icons.bookmark_add_outlined,
                                      color: _cartItems.isEmpty ? Colors.grey.shade400 : Colors.red,
                                      size: 24,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 5),
                                InkWell(
                                  onTap: _showHangList,
                                  borderRadius: BorderRadius.circular(20),
                                  child: Container(
                                    width: 40.0,
                                    height: 60,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(16),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.grey.shade200,
                                          blurRadius: 2,
                                        )
                                      ],
                                    ),
                                    child: Icon(
                                      Icons.bookmark_rounded,
                                      color: Colors.red,
                                      size: 24,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 15),
                    child: _dashedDivider(),
                  ),
                  Expanded(
                    child: OverflowBox(
                      maxWidth: rightPanelWidth,
                      child: _cartItems.isEmpty
                          ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              widget.mode == OrderPageMode.shouyin ? '请添加商品' : '购物车为空，请添加商品',
                              style: TextStyle(fontSize: 16, color: Colors.grey.shade500),
                            ),
                          ],
                        ),
                      )
                          : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                        itemCount: _cartItems.length,
                        itemBuilder: (context, index) {
                          final item = _cartItems[index];
                          return InkWell(
                            onTap: () => _showModifyQuantityDialog(item),
                            splashColor: Colors.red.withOpacity(0.1),
                            highlightColor: Colors.red.withOpacity(0.05),
                            child: Container(
                              height: isSmallScreen ? 100.0 : 120.0,
                              margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(16),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.grey.shade100,
                                    blurRadius: 4,
                                    offset: const Offset(0, 2),
                                  )
                                ],
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Expanded(
                                    flex: 3,
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          item.goods.title,
                                          style: TextStyle(
                                            fontSize: goodsTitleFontSize,
                                            fontWeight: FontWeight.w500,
                                            color: Colors.black87,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          '¥${item.goods.amount.toStringAsFixed(2)}',
                                          style: TextStyle(
                                            fontSize: isSmallScreen ? 15.0 : 17.0,
                                            color: Colors.red.shade600,
                                            fontWeight: FontWeight.w600,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        if (item.goods.guige.isNotEmpty)
                                          Padding(
                                            padding: const EdgeInsets.only(top: 2),
                                            child: Text(
                                              '规格：${item.goods.guige}',
                                              style: TextStyle(
                                                fontSize: isSmallScreen ? 12.0 : 13.0,
                                                color: Colors.grey.shade600,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  Expanded(
                                    flex: 2,
                                    child: Center(
                                      child: _quantityControlWidget(item),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 35.0,
                                    child: Align(
                                      alignment: Alignment.centerRight,
                                      child: InkWell(
                                        onTap: () => _deleteCartItem(item.goods),
                                        borderRadius: BorderRadius.circular(20),
                                        child: Container(
                                          width: 35.0,
                                          height: 35.0,
                                          alignment: Alignment.center,
                                          decoration: BoxDecoration(
                                            color: Colors.red.shade50,
                                            borderRadius: BorderRadius.circular(17.5),
                                            boxShadow: [
                                              BoxShadow(
                                                color: Colors.red.shade100,
                                                blurRadius: 2,
                                                offset: const Offset(0, 1),
                                              )
                                            ],
                                          ),
                                          child: const Text(
                                            'X',
                                            style: TextStyle(
                                              fontSize: 16,
                                              color: Colors.red,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _cartItems.isEmpty ? Colors.red.shade300 : Colors.red.shade600,
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(vertical: isSmallScreen ? 16.0 : 28.0),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                        minimumSize: Size(double.infinity, isSmallScreen ? 50.0 : 88.0),
                        elevation: 8,
                        shadowColor: Colors.red.shade300,
                      ),
                      onPressed: _cartItems.isEmpty || _isLoading ? null : _navigateToSettlement,
                      child: _isLoading
                          ? const CircularProgressIndicator(color: Colors.white, strokeWidth: 2)
                          : _cartItems.isEmpty
                          ? const Text(
                        '去结算',
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.bold,
                        ),
                      )
                          : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '共${_cartTotalCount}件 ',
                            style: TextStyle(
                              fontSize: isSmallScreen ? 12.0 : 14.0,
                              fontWeight: FontWeight.normal,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              '去结算 ¥${_cartTotal.toStringAsFixed(2)}',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: isSmallScreen ? 16.0 : 23.0,
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}