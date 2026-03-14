import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import '../models/login_model.dart'; // 复用用户信息管理

// 会员模型（移除车牌号字段）
class VipModel {
  final int id;
  final int vipId; // 会员所属商户ID
  final String? name;
  final String? phone;
  final double amount;
  final int score;
  final int status;
  final String? avatar;
  final String createTime;

  VipModel({
    required this.id,
    required this.vipId,
    this.name,
    this.phone,
    required this.amount,
    required this.score,
    required this.status,
    this.avatar,
    required this.createTime,
  });

  // 从JSON解析（移除车牌号相关逻辑）
  factory VipModel.fromJson(Map<String, dynamic> json) {
    // 修复：确保所有赋值给double的地方都是double类型（避免int→double?错误）
    double amountValue = 0.0;
    if (json['amount'] != null) {
      if (json['amount'] is int) {
        amountValue = (json['amount'] as int).toDouble();
      } else if (json['amount'] is double) {
        amountValue = json['amount'] as double;
      } else {
        amountValue = double.tryParse(json['amount'].toString()) ?? 0.0;
      }
    }

    return VipModel(
      id: json['id'] ?? 0,
      vipId: json['vip_id'] ?? 0,
      name: json['name'],
      phone: json['phone'],
      amount: amountValue, // 使用处理后的double值
      score: json['score'] ?? 0,
      status: json['status'] ?? 1,
      avatar: json['avatar'],
      createTime: json['create_time'] ?? '',
    );
  }
}

// 充值档次模型（增强容错性）
class VipHuodongModel {
  final String id;
  final String amount; // 充值金额
  final String zengsong; // 赠送金额
  final String createTime;

  VipHuodongModel({
    required this.id,
    required this.amount,
    required this.zengsong,
    required this.createTime,
  });

  // 增强容错：处理各种空值/类型错误
  factory VipHuodongModel.fromJson(Map<String, dynamic> json) {
    // 强制转换为字符串，避免null或int类型问题
    String getId() {
      if (json['id'] == null) return '';
      return json['id'].toString();
    }

    String getAmount() {
      if (json['amount'] == null) return '0';
      return json['amount'].toString();
    }

    String getZengsong() {
      if (json['zengsong'] == null) return '0';
      return json['zengsong'].toString();
    }

    String getCreateTime() {
      if (json['create_time'] == null) return '';
      return json['create_time'].toString();
    }

    return VipHuodongModel(
      id: getId(),
      amount: getAmount(),
      zengsong: getZengsong(),
      createTime: getCreateTime(),
    );
  }
}

/// 会员页面（完整修正版：顶部显示可用余额 + 修复充值列表放大转圈）
class HuiYuanPage extends StatefulWidget {
  const HuiYuanPage({super.key});

  @override
  State<HuiYuanPage> createState() => _HuiYuanPageState();
}

class _HuiYuanPageState extends State<HuiYuanPage> {
  final UserInfoManager _userManager = UserInfoManager();
  final String _vipListApi = 'https://shop.wx-zf.com/shouyin/vip/vipp';
  final String _addVipApi = 'https://shop.wx-zf.com/api/vip/v2add';
  final String _huodongApi = 'https://shop.wx-zf.com/shouyin/viphuodong/lst'; // 充值档次API
  final String _rechargeApi = 'https://shop.wx-zf.com/shouyin/vip/recharge'; // 充值API
  int? _currentWenxunId; // 当前登录商户ID
  List<VipModel> _vipList = [];
  List<VipModel> _filteredVipList = []; // 搜索过滤后的列表
  bool _isLoading = true;
  String? _errorMessage;
  final TextEditingController _searchController = TextEditingController(); // 搜索框控制器

  // 新增会员表单控制器
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _amountController = TextEditingController(text: '0.0');
  final TextEditingController _scoreController = TextEditingController(text: '0');

  // 数字键盘相关
  TextEditingController? _activeInputController;
  bool _isDialogBuilding = false;

  // 充值档次相关状态（重点修正）
  List<VipHuodongModel> _huodongList = [];
  VipHuodongModel? _selectedHuodong;
  bool _isHuodongLoading = false;
  String? _huodongErrorMessage; // 新增：充值档次加载错误提示

  @override
  void initState() {
    super.initState();
    _fetchVipData();
    _searchController.addListener(() => _filterVipList(_searchController.text.trim()));
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _amountController.dispose();
    _scoreController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  // 获取会员数据
  Future<void> _fetchVipData() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _vipList.clear();
      _filteredVipList.clear();
      _errorMessage = null;
    });

    try {
      final wenxunIdStr = await _userManager.getWenxunId();
      if (!mounted) return;

      if (wenxunIdStr == null || wenxunIdStr.isEmpty) {
        setState(() {
          _errorMessage = '未获取到商户信息，请重新登录';
          _isLoading = false;
        });
        return;
      }

      _currentWenxunId = int.tryParse(wenxunIdStr);
      if (_currentWenxunId == null) {
        setState(() {
          _errorMessage = '商户ID格式错误，请重新登录';
          _isLoading = false;
        });
        return;
      }

      final response = await http.post(
        Uri.parse(_vipListApi),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {'vip_id': _currentWenxunId.toString()},
      ).timeout(const Duration(seconds: 10));

      if (!mounted) return;
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['code'] == 200) {
          final vipJsonList = data['huiyuan'] ?? [];
          final filteredVips = (vipJsonList as List)
              .map((json) => VipModel.fromJson(json))
              .where((vip) => vip.vipId == _currentWenxunId)
              .toList();

          setState(() {
            _vipList = filteredVips;
            _filteredVipList = filteredVips;
            _isLoading = false;
          });
        } else {
          setState(() {
            _errorMessage = data['msg'] ?? '获取会员列表失败';
            _isLoading = false;
          });
        }
      } else {
        setState(() {
          _errorMessage = '请求失败：状态码${response.statusCode}';
          _isLoading = false;
        });
      }
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _errorMessage = '请求超时，请检查网络';
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '加载失败：${e.toString()}';
        _isLoading = false;
      });
    }
  }

  // 获取充值档次数据（核心修复：移除多余mounted判断，确保放大时能正常更新状态）
  Future<void> _fetchHuodongData() async {
    // 强制重置loading状态为true（无论弹窗大小，都要重置）
    setState(() {
      _isHuodongLoading = true;
      _huodongErrorMessage = null;
    });

    if (_currentWenxunId == null) {
      setState(() {
        _isHuodongLoading = false;
        _huodongErrorMessage = '商户ID为空，无法获取充值档次';
      });
      return;
    }

    try {
      debugPrint('请求充值档次参数：wenxun_id=${_currentWenxunId.toString()}');

      final response = await http.post(
        Uri.parse(_huodongApi),
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Accept': 'application/json',
        },
        body: {'wenxun_id': _currentWenxunId.toString()},
      ).timeout(const Duration(seconds: 15));

      debugPrint('充值档次响应状态码：${response.statusCode}');
      debugPrint('充值档次响应内容：${response.body}');

      // 处理500状态码（后端接口错误）
      if (response.statusCode == 500) {
        String errorMsg = '服务器内部错误：充值档次接口异常';
        try {
          final errorData = json.decode(response.body);
          if (errorData['message'] != null) {
            errorMsg = '服务器错误：${errorData['message']}';
          }
        } catch (e) {
          errorMsg = '服务器内部错误（500）：无法解析错误信息';
        }
        setState(() {
          _isHuodongLoading = false;
          _huodongErrorMessage = errorMsg;
        });
        return;
      }

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        // 检查接口返回码
        if (data['code'] != null && data['code'] != 200) {
          setState(() {
            _isHuodongLoading = false;
            _huodongErrorMessage = data['msg'] ?? data['message'] ?? '获取充值档次失败：接口返回错误';
          });
          return;
        }

        // 兼容多种返回结构
        List<dynamic> huodongJsonList = [];
        if (data['huodong'] != null && data['huodong'] is List) {
          huodongJsonList = data['huodong'];
        } else if (data['data'] != null && data['data'] is List) {
          huodongJsonList = data['data'];
        } else if (data is List) {
          huodongJsonList = data;
        }

        // 解析数据
        List<VipHuodongModel> huodongList = [];
        for (var json in huodongJsonList) {
          try {
            huodongList.add(VipHuodongModel.fromJson(json));
          } catch (e) {
            debugPrint('解析充值档次失败：$e，数据：$json');
            continue;
          }
        }

        setState(() {
          _huodongList = huodongList;
          _isHuodongLoading = false;
          // 默认选中第一个
          if (_huodongList.isNotEmpty) {
            _selectedHuodong = _huodongList.first;
          }
        });
      } else {
        setState(() {
          _isHuodongLoading = false;
          _huodongErrorMessage = '请求失败：状态码${response.statusCode}';
        });
      }
    } on TimeoutException {
      setState(() {
        _isHuodongLoading = false;
        _huodongErrorMessage = '获取充值档次超时，请检查网络或稍后重试';
      });
    } on FormatException {
      setState(() {
        _isHuodongLoading = false;
        _huodongErrorMessage = '充值档次数据格式错误，无法解析';
      });
    } catch (e) {
      // 终极兜底：所有未捕获的异常都重置loading状态
      setState(() {
        _isHuodongLoading = false;
        _huodongErrorMessage = '获取充值档次失败：${e.toString()}';
      });
      debugPrint('获取充值档次异常：$e');
    }
  }

  // 搜索过滤会员列表
  void _filterVipList(String keyword) {
    if (!mounted) return;
    if (keyword.isEmpty) {
      setState(() => _filteredVipList = _vipList);
      return;
    }
    final filtered = _vipList.where((vip) => vip.phone?.contains(keyword) == true).toList();
    setState(() => _filteredVipList = filtered);
  }

  // 显示新增会员弹窗
  void _showAddVipDialog() {
    if (_isDialogBuilding || !mounted || _currentWenxunId == null) {
      if (_currentWenxunId == null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('商户信息异常，无法新增会员'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    _isDialogBuilding = true;

    // 重置表单
    _phoneController.clear();
    _amountController.text = '0.0';
    _scoreController.text = '0';
    _activeInputController = _phoneController;

    showDialog(
      context: context,
      barrierDismissible: false,
      useSafeArea: true,
      builder: (context) => PopScope(
        onPopInvoked: (didPop) {
          if (didPop) {
            _isDialogBuilding = false;
          }
        },
        child: Dialog(
          backgroundColor: Colors.white,
          elevation: 8,
          insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 60),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Container(
            width: MediaQuery.of(context).size.width * 0.75,
            constraints: BoxConstraints(
              maxWidth: 800,
              minHeight: 500,
              maxHeight: MediaQuery.of(context).size.height * 0.85,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 标题栏
                Container(
                  height: 70,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        '新增会员',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF333333),
                        ),
                      ),
                      SizedBox(
                        width: 48,
                        height: 48,
                        child: InkWell(
                          onTap: () {
                            _isDialogBuilding = false;
                            Navigator.pop(context);
                          },
                          borderRadius: BorderRadius.circular(24),
                          child: const Center(
                            child: Icon(Icons.close, color: Color(0xFF666666), size: 24),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: Color(0xFFE0E0E0)),

                // 核心布局：表单+键盘
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                    child: SizedBox(
                      width: double.infinity,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 左侧表单区域
                          Expanded(
                            flex: 6,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // 1. 会员手机号
                                _buildCashStyleTextField(
                                  controller: _phoneController,
                                  label: '会员手机号*',
                                  hint: '请输入11位手机号',
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly,
                                    LengthLimitingTextInputFormatter(11),
                                  ],
                                  onTap: () => setState(() => _activeInputController = _phoneController),
                                ),
                                const SizedBox(height: 24),

                                // 2. 初始余额
                                _buildCashStyleTextField(
                                  controller: _amountController,
                                  label: '初始余额（元）',
                                  hint: '默认0元',
                                  prefixText: '¥',
                                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d+\.?\d{0,2}$'))],
                                  onTap: () => setState(() => _activeInputController = _amountController),
                                ),
                                const SizedBox(height: 24),

                                // 3. 初始积分
                                _buildCashStyleTextField(
                                  controller: _scoreController,
                                  label: '初始积分',
                                  hint: '默认0分',
                                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                  onTap: () => setState(() => _activeInputController = _scoreController),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 24),

                          // 右侧数字键盘
                          Expanded(
                            flex: 4,
                            child: _buildCashStyleNumericKeyboard(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // 底部保存按钮
                Container(
                  height: 100,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        _isDialogBuilding = false;
                        _submitAddVip();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFF4444),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        minimumSize: const Size(double.infinity, 80),
                        elevation: 8,
                        shadowColor: const Color(0xFFFF4444).withOpacity(0.4),
                        textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                      ),
                      child: const Text('保存'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ).whenComplete(() {
      _isDialogBuilding = false;
    });
  }

  // 构建现金支付样式的输入框
  Widget _buildCashStyleTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    String? prefixText,
    List<TextInputFormatter>? inputFormatters,
    VoidCallback? onTap,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 18, color: Color(0xFF666666)),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          inputFormatters: inputFormatters,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w500, color: Color(0xFF333333)),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Color(0xFF999999), fontSize: 20),
            prefixText: prefixText,
            prefixStyle: const TextStyle(color: Color(0xFFFF4444), fontSize: 22),
            contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            border: const OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(16)),
              borderSide: BorderSide(width: 2, color: Color(0xFFEEEEEE)),
            ),
            enabledBorder: const OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(16)),
              borderSide: BorderSide(width: 2, color: Color(0xFFEEEEEE)),
            ),
            focusedBorder: const OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(16)),
              borderSide: BorderSide(width: 3, color: Color(0xFFFF4444)),
            ),
            filled: true,
            fillColor: Colors.white,
            suffixIcon: controller.text.isNotEmpty
                ? IconButton(
              icon: const Icon(Icons.clear, size: 28, color: Color(0xFF999999)),
              onPressed: () => controller.clear(),
            )
                : null,
            alignLabelWithHint: true,
          ),
          readOnly: true,
          onTap: onTap,
          cursorColor: const Color(0xFFFF4444),
        ),
      ],
    );
  }

  // 构建现金支付样式的数字键盘
  Widget _buildCashStyleNumericKeyboard() {
    final List<List<String>> keys = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['0', '.', '←'],
    ];

    return Container(
      height: 320,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(16),
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
                    padding: const EdgeInsets.all(3),
                    child: _buildCashStyleKeyButton(key),
                  ),
                );
              }).toList(),
            ),
          );
        }).toList(),
      ),
    );
  }

  // 现金支付样式的键盘按键
  Widget _buildCashStyleKeyButton(String key) {
    bool _isPressed = false;

    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) {
        setState(() => _isPressed = false);
        _onKeyPressed(key);
      },
      onTapCancel: () => setState(() => _isPressed = false),
      child: Container(
        decoration: BoxDecoration(
          color: _isPressed ? const Color(0xFFF0F0F0) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE0E0E0), width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.grey.withOpacity(0.1),
              blurRadius: 3,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: key == '←'
            ? const Icon(Icons.backspace, size: 28, color: Color(0xFFFF4444))
            : Text(
          key,
          style: TextStyle(
            fontSize: key == '.' ? 28 : 24,
            fontWeight: FontWeight.w500,
            color: const Color(0xFF333333),
          ),
        ),
      ),
    );
  }

  // 键盘按键事件
  void _onKeyPressed(String key) {
    if (!mounted || _activeInputController == null) return;

    final controller = _activeInputController!;
    final currentText = controller.text;

    setState(() {
      if (key == '←') {
        if (currentText.isNotEmpty) {
          controller.text = currentText.substring(0, currentText.length - 1);
        }
      } else if (key == '.' && controller == _amountController) {
        if (!currentText.contains('.')) {
          controller.text = currentText.isEmpty ? '0.' : '$currentText.';
        }
      } else if (RegExp(r'^\d$').hasMatch(key)) {
        if (controller == _phoneController && currentText.length >= 11) return;

        if (controller == _amountController) {
          if (currentText.contains('.') && currentText.split('.').last.length >= 2) return;
          if (currentText == '0' || currentText == '0.0') {
            controller.text = key;
            return;
          }
        }

        if (controller == _scoreController && currentText == '0') {
          controller.text = key;
          return;
        }

        controller.text = '$currentText$key';
      }
    });
  }

  // 提交新增会员
  Future<void> _submitAddVip() async {
    final phone = _phoneController.text.trim();
    final amount = double.tryParse(_amountController.text.trim()) ?? 0.0;
    final score = int.tryParse(_scoreController.text.trim()) ?? 0;

    if (!mounted) return;

    if (phone.isEmpty || phone.length != 11) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请输入有效的11位手机号'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    if (_currentWenxunId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('商户信息异常，无法新增会员'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    Navigator.pop(context);

    try {
      final response = await http.post(
        Uri.parse(_addVipApi),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'vip_id': _currentWenxunId.toString(),
          'name': '',
          'phone': phone,
          'amount': amount.toStringAsFixed(2),
          'score': score.toString(),
        },
      ).timeout(const Duration(seconds: 10));

      if (!mounted) return;
      final data = json.decode(response.body);
      if (data['code'] == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('新增会员成功：${data['msg'] ?? ''}'),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 2),
          ),
        );
        _fetchVipData();
      } else {
        throw Exception(data['msg'] ?? '新增会员失败');
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('新增失败：$e'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  // 构建会员列表项
  Widget _buildVipItem(VipModel vip) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.grey.withOpacity(0.08),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 15),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 头像
            SizedBox(
              width: 55,
              height: 55,
              child: vip.avatar?.isNotEmpty == true
                  ? ClipOval(
                child: Image.network(
                  vip.avatar!,
                  width: 55,
                  height: 55,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const Icon(Icons.person, size: 55, color: Color(0xFFA0AEC0)),
                  loadingBuilder: (_, child, loadingProgress) =>
                  loadingProgress == null ? child : const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              )
                  : const Icon(Icons.person, size: 55, color: Color(0xFFA0AEC0)),
            ),
            const SizedBox(width: 18),
            // 会员信息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    vip.name ?? '未知会员',
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Color(0xFF2D3748)),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '手机号：${vip.phone ?? '未填写'}',
                    style: const TextStyle(fontSize: 15, color: Color(0xFF718096)),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '余额：¥${vip.amount.toStringAsFixed(2)} | 积分：${vip.score}',
                    style: const TextStyle(fontSize: 15, color: Color(0xFF718096)),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '状态：${vip.status == 1 ? '启用' : '禁用'} | 注册时间：${vip.createTime.substring(0, 10)}',
                    style: TextStyle(
                      fontSize: 14,
                      color: vip.status == 1 ? const Color(0xFF22C55E) : const Color(0xFFA0AEC0),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // 充值按钮
            SizedBox(
              width: 80,
              height: 40,
              child: ElevatedButton(
                onPressed: () => _showRechargeDialog(vip),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF5252),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                ),
                child: const Text('充值'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 执行充值操作
  Future<void> _doRecharge(VipModel vip, String payType) async {
    if (!mounted || _selectedHuodong == null) return;

    final rechargeAmount = double.tryParse(_selectedHuodong!.amount) ?? 0.0;
    if (rechargeAmount <= 0.0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('充值金额无效'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    try {
      final response = await http.post(
        Uri.parse(_rechargeApi),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'vip_id': _currentWenxunId.toString(),
          'user_id': vip.id.toString(),
          'amount': rechargeAmount.toString(),
          'pay_type': payType,
        },
      ).timeout(const Duration(seconds: 10));

      if (!mounted) return;
      final data = json.decode(response.body);
      if (data['code'] == 200) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${payType == 'cash' ? '现金' : '扫码'}充值成功：${data['msg'] ?? ''}'),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
          ),
        );
        _fetchVipData();
      } else {
        throw Exception(data['msg'] ?? '充值失败');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('充值失败：$e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  // 充值弹窗（重点修正：顶部标题栏 + 修复放大转圈）
  void _showRechargeDialog(VipModel vip) {
    if (!mounted || vip.vipId != _currentWenxunId) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('无权操作其他商户的会员'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    // 第一步：先重置充值档次所有状态（关键修复：避免上次加载状态残留）
    setState(() {
      _isHuodongLoading = false;
      _huodongList.clear();
      _selectedHuodong = null;
      _huodongErrorMessage = null;
    });

    // 第二步：再请求数据
    _fetchHuodongData();

    showDialog(
      context: context,
      barrierDismissible: true,
      useSafeArea: true,
      builder: (context) => Dialog(
        backgroundColor: Colors.white,
        elevation: 8,
        insetPadding: const EdgeInsets.all(20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Container(
          // 调整约束：移除固定高度，使用最小高度，避免放大时布局异常
          width: MediaQuery.of(context).size.width > 800 ? 800 : MediaQuery.of(context).size.width * 0.95,
          constraints: const BoxConstraints(
            minWidth: 400,
            minHeight: 400,
            maxWidth: 800,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 标题栏（核心修改：一排显示会员名称、手机号、可用余额，字体加粗一致，移除“手机号”文字）
              Container(
                height: 80,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // 左侧：会员名称 + 手机号（移除“手机号”文字）
                    Text(
                      '${vip.name ?? '未知会员'} ${vip.phone ?? ''}',
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF2D3748),
                      ),
                    ),
                    // 右侧：可用余额
                    Text(
                      '可用余额 ¥${vip.amount.toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF2D3748),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Color(0xFFE2E8F0)),

              // 充值档次选择区（重点修正：显示错误信息）
              Expanded(
                flex: 2,
                child: _isHuodongLoading
                    ? const Center(
                  child: CircularProgressIndicator(
                    color: Color(0xFFFF5252),
                    strokeWidth: 3,
                  ),
                )
                    : _huodongErrorMessage != null
                    ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      _huodongErrorMessage!,
                      style: const TextStyle(color: Color(0xFFFF5252), fontSize: 18, height: 1.5),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
                    : _huodongList.isEmpty
                    ? const Center(
                  child: Text(
                    '暂无充值档次配置',
                    style: TextStyle(fontSize: 18, color: Color(0xFF718096)),
                  ),
                )
                    : GridView.builder(
                  padding: const EdgeInsets.all(20),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                    childAspectRatio: 3,
                  ),
                  itemCount: _huodongList.length,
                  itemBuilder: (context, index) {
                    final huodong = _huodongList[index];
                    final isSelected = _selectedHuodong?.id == huodong.id;
                    return GestureDetector(
                      onTap: () => setState(() => _selectedHuodong = huodong),
                      child: Container(
                        decoration: BoxDecoration(
                          color: isSelected ? const Color(0xFFFF5252) : const Color(0xFFF7FAFC),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isSelected ? const Color(0xFFFF5252) : const Color(0xFFE2E8F0),
                            width: 2,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              '充值${huodong.amount}元',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: isSelected ? Colors.white : const Color(0xFF2D3748),
                              ),
                            ),
                            if (huodong.zengsong != '0' && huodong.zengsong.isNotEmpty)
                              Text(
                                '赠送${huodong.zengsong}元',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: isSelected ? Colors.white.withOpacity(0.8) : const Color(0xFF718096),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),

              const Divider(height: 1, color: Color(0xFFE2E8F0)),

              // 支付方式选择区
              Expanded(
                flex: 1,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // 现金充值按钮
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _selectedHuodong == null
                              ? null
                              : () => _doRecharge(vip, 'cash'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF38A169),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                          ),
                          child: const Text('现金充值'),
                        ),
                      ),
                      const SizedBox(width: 20),
                      // 扫码充值按钮
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _selectedHuodong == null
                              ? null
                              : () => _doRecharge(vip, 'scan'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF3182CE),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                          ),
                          child: const Text('扫码充值'),
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
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7FAFC),
      body: Container(
        width: MediaQuery.of(context).size.width,
        height: MediaQuery.of(context).size.height,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 左侧功能区
            SizedBox(
              width: 200,
              child: Container(
                margin: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.grey.withOpacity(0.1),
                      blurRadius: 6,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    const SizedBox(height: 30),
                    // 新增会员按钮
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 15),
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFFF5252),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            padding: const EdgeInsets.symmetric(vertical: 20),
                            textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
                          ),
                          onPressed: _showAddVipDialog,
                          child: const Text('新增会员'),
                        ),
                      ),
                    ),
                    const SizedBox(height: 30),
                  ],
                ),
              ),
            ),

            // 右侧会员列表区
            Expanded(
              child: Container(
                margin: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.grey.withOpacity(0.1),
                      blurRadius: 6,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    // 搜索框
                    SizedBox(
                      height: 80,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
                        child: TextField(
                          controller: _searchController,
                          decoration: InputDecoration(
                            hintText: '输入手机号搜索会员',
                            hintStyle: const TextStyle(color: Color(0xFFA0AEC0)),
                            prefixIcon: const Icon(Icons.search, color: Color(0xFF718096)),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(color: Color(0xFFE2E8F0), width: 1.5),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(color: Color(0xFFFF5252), width: 2),
                            ),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
                          ),
                          style: const TextStyle(fontSize: 16),
                        ),
                      ),
                    ),
                    const Divider(height: 1, color: Color(0xFFE2E8F0)),
                    // 会员列表
                    Expanded(
                      child: _isLoading
                          ? const Center(
                        child: CircularProgressIndicator(
                          color: Color(0xFFFF5252),
                          strokeWidth: 3,
                        ),
                      )
                          : _errorMessage != null
                          ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            _errorMessage!,
                            style: const TextStyle(color: Color(0xFFFF5252), fontSize: 18, height: 1.5),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                          : _filteredVipList.isEmpty
                          ? const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.group_add, size: 80, color: Color(0xFFA0AEC0)),
                            SizedBox(height: 20),
                            Text(
                              '暂无会员数据',
                              style: TextStyle(fontSize: 18, color: Color(0xFF718096)),
                            ),
                            SizedBox(height: 10),
                            Text(
                              '点击左侧"新增会员"添加第一个会员吧',
                              style: TextStyle(fontSize: 14, color: Color(0xFFA0AEC0)),
                            ),
                          ],
                        ),
                      )
                          : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        itemCount: _filteredVipList.length,
                        itemBuilder: (context, index) => _buildVipItem(_filteredVipList[index]),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}