import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:async';
import '../models/login_model.dart';
import '../models/goods_model.dart';
import 'order_page.dart' show OrderPageMode;
import 'login_page.dart';

// 枚举定义
enum PaymentType {
  scan,
  cash,
  member,
}

enum CashierPermission {
  normal,
  manager,
  admin,
}

extension PaymentTypeExt on PaymentType {
  String get showName {
    switch (this) {
      case PaymentType.scan:
        return '扫码';
      case PaymentType.cash:
        return '现金';
      case PaymentType.member:
        return '会员';
    }
  }

  String get backendValue {
    switch (this) {
      case PaymentType.scan:
        return '微信支付';
      case PaymentType.cash:
        return '现金';
      case PaymentType.member:
        return '会员支付';
    }
  }
}

class SettlementPage extends StatefulWidget {
  final List<CartItem> cartItems;
  final double totalPrice;
  final String? wenxunId;
  final OrderPageMode mode;
  final CashierPermission cashierPermission;
  final int? renyuanId;
  final String? cashierName;

  const SettlementPage({
    super.key,
    required this.cartItems,
    required this.totalPrice,
    required this.wenxunId,
    required this.mode,
    this.cashierPermission = CashierPermission.admin,
    this.renyuanId,
    this.cashierName,
  });

  @override
  State<SettlementPage> createState() => _SettlementPageState();
}

class _SettlementPageState extends State<SettlementPage> {
  PaymentType _selectedPaymentType = PaymentType.scan;
  final TextEditingController _paymentCodeController = TextEditingController();
  final TextEditingController _memberPhoneController = TextEditingController();
  final FocusNode _paymentCodeFocusNode = FocusNode();
  final FocusNode _memberPhoneFocusNode = FocusNode();

  final TextEditingController _receivedMoneyController = TextEditingController();
  final FocusNode _receivedMoneyFocusNode = FocusNode();
  double _changeMoney = 0.0;
  bool _isReceivedMoneyEdited = false;

  final TextEditingController _discountController = TextEditingController();
  final FocusNode _discountFocusNode = FocusNode();
  final TextEditingController _preferentialController = TextEditingController();
  final FocusNode _preferentialFocusNode = FocusNode();

  double _originalTotalPrice = 0.0;
  double _discountRate = 1.0;
  double _preferentialAmount = 0.0;

  bool _isLoading = false;
  Map<String, dynamic>? _vipInfo;
  String? _effectiveWenxunId;
  final UserInfoManager _userManager = UserInfoManager();

  String? _realCashierName;
  int? _realRenyuanId;

  String? _scanPayOrderNo;
  String? _scanPayStatus;

  final FlutterTts _flutterTts = FlutterTts();
  bool _isTtsInitialized = false;

  @override
  void initState() {
    super.initState();
    _originalTotalPrice = widget.totalPrice;
    _initEffectiveWenxunId();
    _initCashierInfo();
    _initTts();

    _discountController.addListener(_onDiscountChanged);
    _preferentialController.addListener(_onPreferentialChanged);

    // 修正：找零金额失效问题 - 移除焦点判断，实时监听输入变化并计算找零
    _receivedMoneyController.addListener(() {
      _isReceivedMoneyEdited = true;
      _calculateChange(); // 实时计算找零
    });

    WidgetsBinding.instance.addPostFrameCallback((_) => FocusScope.of(context).requestFocus(_paymentCodeFocusNode));
  }

  @override
  void dispose() {
    _paymentCodeController.dispose();
    _memberPhoneController.dispose();
    _discountController.dispose();
    _preferentialController.dispose();
    _receivedMoneyController.dispose();
    _paymentCodeFocusNode.dispose();
    _memberPhoneFocusNode.dispose();
    _receivedMoneyFocusNode.dispose();
    _discountFocusNode.dispose();
    _preferentialFocusNode.dispose();
    _flutterTts.stop();
    super.dispose();
  }

  Future<void> _initTts() async {
    try {
      await _flutterTts.setLanguage("zh-CN");
      await _flutterTts.setSpeechRate(0.6);
      await _flutterTts.setVolume(1.0);
      await _flutterTts.setPitch(1.0);

      _flutterTts.setCompletionHandler(() {
        debugPrint("收款语音播报完成");
      });

      _flutterTts.setErrorHandler((msg) {
        debugPrint("语音播报错误：$msg");
      });

      setState(() {
        _isTtsInitialized = true;
      });
    } catch (e) {
      debugPrint("TTS初始化失败：$e");
      setState(() {
        _isTtsInitialized = false;
      });
    }
  }

  String _formatAmountToChinese(double amount) {
    int yuan = amount.floor();
    int jiao = ((amount - yuan) * 10).floor();
    int fen = ((amount - yuan - jiao/10) * 100).floor() % 10;

    String text = "收款";
    if (yuan > 0) text += "$yuan元";
    if (jiao > 0) text += "$jiao角";
    if (fen > 0) text += "$fen分";
    if (yuan == 0 && jiao == 0 && fen > 0) text += "$fen分";
    if (yuan == 0 && jiao == 0 && fen == 0) text += "0元";

    return text + "，收款成功";
  }

  Future<void> _broadcastPaymentSuccess(double amount) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    bool isVoiceEnabled = prefs.getBool('voice_broadcast_enabled') ?? true;
    if (!isVoiceEnabled) {
      debugPrint("语音播报已关闭，跳过本次播报");
      return;
    }

    if (!_isTtsInitialized) {
      debugPrint("TTS未初始化，跳过语音播报");
      return;
    }

    try {
      await _flutterTts.stop();
      String broadcastText = _formatAmountToChinese(amount);
      await _flutterTts.speak(broadcastText);
      debugPrint("开始播报：$broadcastText");
    } catch (e) {
      debugPrint("播报失败：$e");
    }
  }

  Future<void> _initCashierInfo() async {
    if (!await _userManager.isLoggedIn()) {
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const LoginPage()),
        );
      }
      return;
    }

    String? cashierName = widget.cashierName;
    if (cashierName == null || cashierName.isEmpty) {
      cashierName = await _userManager.getRenyuan();
    }

    final String? cashierIdStr = await _userManager.getCashierId();
    int? renyuanId;
    if (cashierIdStr != null && cashierIdStr.isNotEmpty) {
      renyuanId = int.tryParse(cashierIdStr);
    }
    renyuanId ??= widget.renyuanId;

    if (mounted) {
      setState(() {
        _realCashierName = cashierName;
        _realRenyuanId = renyuanId;
      });
    }
  }

  Future<void> _initEffectiveWenxunId() async {
    if (widget.wenxunId != null && widget.wenxunId!.isNotEmpty) {
      setState(() => _effectiveWenxunId = widget.wenxunId);
      return;
    }
    final localWenxunId = await _userManager.getWenxunId();
    if (mounted) setState(() => _effectiveWenxunId = localWenxunId);
  }

  void _onDiscountChanged() {
    if (_discountController.text.isEmpty) {
      setState(() => _discountRate = 1.0);
      return;
    }

    final input = double.tryParse(_discountController.text);
    if (input != null) {
      if (input >= 0.1 && input <= 1.0) {
        setState(() => _discountRate = input);
      } else {
        return;
      }
    }

    if (_selectedPaymentType == PaymentType.cash && !_isReceivedMoneyEdited) {
      _autoUpdateReceivedMoney();
    }
  }

  void _onPreferentialChanged() {
    if (_preferentialController.text.isEmpty) {
      setState(() => _preferentialAmount = 0.0);
      return;
    }

    final input = double.tryParse(_preferentialController.text);
    if (input != null && input >= 0 && input <= _calculateDiscountPrice()) {
      setState(() => _preferentialAmount = double.parse(input.toStringAsFixed(2)));
    } else if (input != null && input > _calculateDiscountPrice()) {
      return;
    }

    if (_selectedPaymentType == PaymentType.cash && !_isReceivedMoneyEdited) {
      _autoUpdateReceivedMoney();
    }
  }

  void _autoUpdateReceivedMoney() {
    final double finalPrice = _calculateFinalPrice();
    _receivedMoneyController.text = finalPrice.toStringAsFixed(2);
    _calculateChange(); // 确保自动填充时也计算找零
  }

  void _calculateChange() {
    final double received = double.tryParse(_receivedMoneyController.text) ?? 0.0;
    final double finalPrice = _calculateFinalPrice();
    setState(() {
      _changeMoney = received >= finalPrice ? (received - finalPrice) : 0.0;
    });
  }

  double _calculateDiscountPrice() => _originalTotalPrice * _discountRate;

  double _calculateFinalPrice() {
    double discountPrice = _calculateDiscountPrice();
    double finalPrice = discountPrice - _preferentialAmount;
    return finalPrice < 0 ? 0 : finalPrice;
  }

  Future<void> _verifyVip() async {
    final String phone = _memberPhoneController.text.trim();
    if (phone.isEmpty) {
      _showSnackBar('请输入会员手机号');
      return;
    }
    if (phone.length != 11) {
      _showSnackBar('请输入有效的11位手机号');
      return;
    }
    if (_effectiveWenxunId == null || _effectiveWenxunId!.isEmpty) {
      _showSnackBar('商户ID为空，请重新登录');
      return;
    }

    setState(() => _isLoading = true);
    try {
      final response = await http.post(
        Uri.parse('https://shop.wx-zf.com/shouyin/vip/vipp'),
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Accept': 'application/json',
        },
        body: {'vip_id': _effectiveWenxunId!, 'phone': phone},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final Map<String, dynamic> result = json.decode(response.body);
        if (result['code'] == 200) {
          final List<dynamic> vipList = result['huiyuan'] ?? [];
          final List<dynamic> matchedVips = vipList
              .where((vip) => vip['phone'] == phone && vip['vip_id'].toString() == _effectiveWenxunId)
              .toList();
          if (matchedVips.isNotEmpty) {
            setState(() => _vipInfo = matchedVips.first);
            final double balance = double.tryParse(_vipInfo!['amount'].toString()) ?? 0.0;
            final double finalPrice = _calculateFinalPrice();

            if (mounted) {
              _showMemberPayConfirmDialog(
                vipName: _vipInfo!['name'] ?? '未知会员',
                vipPhone: phone,
                currentBalance: balance,
                payAmount: finalPrice,
              );
            }
          } else {
            _showSnackBar('该手机号未注册为会员，请检查手机号或新增会员');
          }
        } else {
          _showSnackBar(result['msg'] ?? '获取会员信息失败');
        }
      } else {
        _showSnackBar('请求失败，状态码：${response.statusCode}');
      }
    } on TimeoutException {
      _showSnackBar('请求超时，请检查网络');
    } on http.ClientException {
      _showSnackBar('网络异常，请检查连接');
    } catch (e) {
      _showSnackBar('会员验证失败：${e.toString()}');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _showMemberPayConfirmDialog({
    required String vipName,
    required String vipPhone,
    required double currentBalance,
    required double payAmount,
  }) async {
    if (currentBalance < payAmount) {
      _showSnackBar('会员余额不足！当前余额：¥${currentBalance.toStringAsFixed(2)}，需支付：¥${payAmount.toStringAsFixed(2)}');
      return;
    }

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          '确认会员支付',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF333333)),
          textAlign: TextAlign.center,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Divider(height: 20, thickness: 1, color: Color(0xFFEEEEEE)),
            _buildDialogInfoItem('会员姓名', vipName),
            _buildDialogInfoItem('会员手机号', vipPhone),
            _buildDialogInfoItem('当前余额', '¥${currentBalance.toStringAsFixed(2)}'),
            _buildDialogInfoItem('本次支付金额', '¥${payAmount.toStringAsFixed(2)}', isRed: true),
            _buildDialogInfoItem('支付后余额', '¥${(currentBalance - payAmount).toStringAsFixed(2)}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF666666),
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('取消', style: TextStyle(fontSize: 18)),
          ),
          ElevatedButton(
            onPressed: _isLoading ? null : () async {
              Navigator.pop(context);
              await _submitOrderToDB(
                paymentMethod: PaymentType.member.backendValue,
                paymentCode: vipPhone,
                paymentStatus: '1',
                receivedMoney: payAmount,
                changeMoney: 0.0,
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF4444),
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              elevation: 8,
              shadowColor: const Color(0xFFFF4444).withOpacity(0.4),
            ),
            child: _isLoading
                ? const CircularProgressIndicator(color: Colors.white, strokeWidth: 2)
                : const Text('扣款', style: TextStyle(fontSize: 18, color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildDialogInfoItem(String label, String value, {bool isRed = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 16, color: Color(0xFF666666))),
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              color: isRed ? const Color(0xFFFF4444) : const Color(0xFF333333),
              fontWeight: isRed ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _submitOrderToDB({
    required String paymentMethod,
    required String paymentCode,
    required String paymentStatus,
    String? tradeNo,
    double receivedMoney = 0.0,
    double changeMoney = 0.0,
  }) async {
    final List<Map<String, dynamic>> cartList = widget.cartItems.map((item) => {
      'id': item.goods.id.toString(),
      'name': item.goods.title,
      'price': item.goods.amount.toStringAsFixed(2),
      'quantity': item.quantity.toString(),
      'image': item.goods.goodsImage ?? '',
    }).toList();

    final int totalCount = widget.cartItems.fold(0, (int sum, CartItem item) => sum + item.quantity);
    final double finalPrice = _calculateFinalPrice();

    final Map<String, String> formData = {
      'id': _effectiveWenxunId!,
      'wenxun_id': _effectiveWenxunId!,
      'renyuan_id': _realRenyuanId!.toString(),
      'cashier_name': _realCashierName!,
      'cashier_permission': widget.cashierPermission.name,
      'total': _originalTotalPrice.toStringAsFixed(2),
      'final_total': finalPrice.toStringAsFixed(2),
      'discount_rate': _discountRate.toStringAsFixed(2),
      'discount_amount': (_originalTotalPrice - _calculateDiscountPrice()).toStringAsFixed(2),
      'preferential_amount': _preferentialAmount.toStringAsFixed(2),
      'total_count': totalCount.toString(),
      'cart': json.encode(cartList),
      'goods_list': json.encode(cartList),
      'paymentMethod': paymentMethod,
      'payment_code': paymentCode,
      'payment_status': paymentStatus,
      'payment_channel': paymentMethod == '微信支付' ? '1' : '0',
      'received_money': receivedMoney.toStringAsFixed(2),
      'change_money': changeMoney.toStringAsFixed(2),
      'gt_order_no': tradeNo ?? '',
      'order_number': tradeNo ?? '',
      'ip': '127.0.0.1',
      'device_type': 'A',
      'refund_status': '0',
      'refund_amount': '0.00',
      'refund_time': '',
      'refund_reason': '',
      'refund_trade_no': '',
      'vip_id': '',
      'phone': '',
      'balance_before': '0.00',
      'balance_after': '0.00',
    };

    try {
      final response = await http.post(
        Uri.parse('https://shop.wx-zf.com/shouyin/order/add'),
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Accept': 'application/json',
          'Charset': 'utf-8',
        },
        body: formData,
      ).timeout(const Duration(seconds: 15));

      final String responseBody = utf8.decode(response.bodyBytes);
      final Map<String, dynamic> result = json.decode(responseBody);

      if (mounted) {
        if (response.statusCode == 200) {
          if (result['code'] == 200) {
            _broadcastPaymentSuccess(finalPrice);

            // 移除订单号、支付方式、最终支付相关文字
            String tipText = '${widget.mode == OrderPageMode.shouyin ? '结算' : '下单'}成功！';
            if (paymentMethod == '现金') {
              tipText += '\n实收金额：¥${receivedMoney.toStringAsFixed(2)}\n找零金额：¥${changeMoney.toStringAsFixed(2)}';
            }

            // 调用美化后的正方形弹窗
            _showSuccessDialog(tipText);

            if (paymentMethod == '现金') {
              _receivedMoneyController.clear();
              _isReceivedMoneyEdited = false;
            } else if (paymentMethod == '微信支付') {
              _paymentCodeController.clear();
            } else if (paymentMethod == '会员支付') {
              _memberPhoneController.clear();
              _vipInfo = null;
            }

            // 弹窗关闭后延迟返回
            Timer(const Duration(seconds: 3), () => Navigator.pop(context, true));
          } else {
            final String errorMsg = result['msg'] ?? '提交失败';
            _showSnackBar(errorMsg);
            throw Exception(errorMsg);
          }
        } else {
          final String errorMsg = '提交失败，状态码：${response.statusCode}';
          _showSnackBar(errorMsg);
          throw Exception(errorMsg);
        }
      }
    } on TimeoutException {
      _showSnackBar('请求超时，请检查网络');
      throw Exception('请求超时');
    } on http.ClientException {
      _showSnackBar('网络异常，请检查连接');
      throw Exception('网络异常');
    } catch (e) {
      _showSnackBar('订单提交失败：${e.toString()}');
      throw Exception('订单提交失败：$e');
    }
  }

  Future<void> _scanPay() async {
    final String amount = _calculateFinalPrice().toStringAsFixed(2);
    final String paymentCode = _paymentCodeController.text.trim();

    if (paymentCode.length < 15 || paymentCode.length > 30) {
      _showSnackBar('付款码长度需在15-30位之间');
      return;
    }

    if (paymentCode.isEmpty) {
      _showSnackBar('请输入顾客付款码');
      return;
    }
    if (_effectiveWenxunId == null || _effectiveWenxunId!.isEmpty) {
      _showSnackBar('商户ID为空，请重新登录');
      return;
    }

    setState(() => _isLoading = true);
    try {
      final response = await http.post(
        Uri.parse('https://shop.wx-zf.com/shouyin/payment/codePay'),
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Accept': 'application/json',
        },
        body: {
          'amount': amount,
          'code': paymentCode,
          'denglu': _effectiveWenxunId!,
          'type': 'A',
          'txamt': (double.parse(amount) * 100).round().toString(),
        },
      ).timeout(const Duration(seconds: 15));

      final Map<String, dynamic> payResult = json.decode(response.body);
      if (payResult['code'] == 0) {
        _scanPayOrderNo = payResult['orderNo'] ?? payResult['tradeNo'] ?? '';
        _scanPayStatus = '1';

        await _submitOrderToDB(
          paymentMethod: _selectedPaymentType.backendValue,
          paymentCode: paymentCode,
          paymentStatus: _scanPayStatus!,
          tradeNo: _scanPayOrderNo,
          receivedMoney: double.parse(amount),
          changeMoney: 0.0,
        );

        _showSnackBar('扫码支付成功！最终支付：¥$amount');
      } else {
        _scanPayStatus = '0';
        throw Exception(payResult['message'] ?? '扫码支付失败，请重试');
      }
    } on TimeoutException {
      _showSnackBar('支付请求超时，请检查网络');
      throw Exception('请求超时');
    } on http.ClientException {
      _showSnackBar('网络异常，请检查连接');
      throw Exception('网络异常');
    } catch (e) {
      _showSnackBar('扫码支付失败：${e.toString()}');
      throw Exception('扫码支付失败：$e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _submitOrder() async {
    if (!mounted) return;

    if (_realCashierName == null || _realCashierName!.isEmpty) {
      _showSnackBar('收银员姓名异常，请重新登录');
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const LoginPage()),
      );
      return;
    }
    if (_realRenyuanId == null || _realRenyuanId! <= 0) {
      _showSnackBar('归属收银员ID无效，请重新登录');
      return;
    }
    if (_effectiveWenxunId == null || _effectiveWenxunId!.isEmpty) {
      _showSnackBar('商户ID为空，请重新登录');
      return;
    }

    setState(() => _isLoading = true);
    try {
      if (_selectedPaymentType == PaymentType.cash) {
        final double received = double.tryParse(_receivedMoneyController.text.trim()) ?? 0.0;
        final double finalPrice = _calculateFinalPrice();
        if (received < finalPrice) {
          _showSnackBar('实收金额不能小于最终支付金额！');
          setState(() => _isLoading = false);
          return;
        }

        await _submitOrderToDB(
          paymentMethod: _selectedPaymentType.backendValue,
          paymentCode: '',
          paymentStatus: '1',
          receivedMoney: received,
          changeMoney: _changeMoney,
        );
      } else if (_selectedPaymentType == PaymentType.scan) {
        await _scanPay();
      }
    } catch (e) {
      _showSnackBar('提交失败：${e.toString()}');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // 美化后的正方形结算成功弹窗
  void _showSuccessDialog(String message) {
    showDialog(
      context: context,
      barrierDismissible: false, // 禁止手动关闭
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: Container(
          width: 300, // 正方形宽度
          height: 300, // 正方形高度
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black12,
                blurRadius: 15,
                spreadRadius: 5,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 成功图标（美化）
              Container(
                width: 80,
                height: 80,
                decoration: const BoxDecoration(
                  color: Color(0xFFE8F5E9),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check,
                  color: Color(0xFF4CAF50),
                  size: 50,
                ),
              ),
              const SizedBox(height: 24),
              // 提示文本（美化）
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  message,
                  style: const TextStyle(
                    fontSize: 18,
                    color: Color(0xFF333333),
                    height: 1.4,
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 16),
              // 倒计时提示
              const Text(
                '3秒后自动关闭',
                style: TextStyle(
                  fontSize: 14,
                  color: Color(0xFF999999),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // 3秒后自动关闭弹窗
    Timer(const Duration(seconds: 3), () {
      if (mounted) {
        Navigator.pop(context);
      }
    });
  }

  void _showSnackBar(String message, {int duration = 2}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(fontSize: 16),
          textAlign: TextAlign.center,
        ),
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.symmetric(
          horizontal: MediaQuery.of(context).size.width * 0.1,
          vertical: 20,
        ),
        duration: Duration(seconds: duration),
        backgroundColor: Colors.red.withOpacity(0.9),
        elevation: 8,
      ),
    );
  }

  void _resetDiscountAndPreferential() {
    setState(() {
      _discountRate = 1.0;
      _preferentialAmount = 0.0;
      _discountController.clear();
      _preferentialController.clear();
    });

    if (_selectedPaymentType == PaymentType.cash && !_isReceivedMoneyEdited) {
      _autoUpdateReceivedMoney();
    }
  }

  Widget _buildPaymentCard(PaymentType type) {
    final isSelected = _selectedPaymentType == type;
    return Expanded(
      child: InkWell(
        onTap: () {
          setState(() {
            _selectedPaymentType = type;
            if (type == PaymentType.scan) {
              _paymentCodeController.clear();
              WidgetsBinding.instance.addPostFrameCallback((_) => FocusScope.of(context).requestFocus(_paymentCodeFocusNode));
            } else if (type == PaymentType.cash) {
              _receivedMoneyController.clear();
              _changeMoney = 0.0;
              _isReceivedMoneyEdited = false;
              _autoUpdateReceivedMoney();
              WidgetsBinding.instance.addPostFrameCallback((_) => FocusScope.of(context).requestFocus(_receivedMoneyFocusNode));
            } else if (type == PaymentType.member) {
              _vipInfo = null;
              _memberPhoneController.clear();
              WidgetsBinding.instance.addPostFrameCallback((_) => FocusScope.of(context).requestFocus(_memberPhoneFocusNode));
            } else {
              FocusScope.of(context).unfocus();
            }
          });
        },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFFFF4444) : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? const Color(0xFFFF4444) : Colors.grey.shade300,
              width: 1.5,
            ),
            boxShadow: isSelected
                ? [BoxShadow(color: Colors.red.withOpacity(0.2), blurRadius: 6, offset: const Offset(0, 3))]
                : [BoxShadow(color: Colors.grey.withOpacity(0.1), blurRadius: 4, offset: const Offset(0, 2))],
          ),
          child: Center(
            child: Text(
              type.showName,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.grey.shade600,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNumberKeyboard(TextEditingController controller, PaymentType paymentType) {
    List<String> keys;
    if (paymentType == PaymentType.cash) {
      keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '.', ''];
    } else {
      keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '00', ''];
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: keys.length,
      itemBuilder: (context, index) {
        final String key = keys[index];
        return ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: key.isEmpty ? Colors.red : Colors.black87,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            elevation: 2,
          ),
          onPressed: () {
            if (key.isEmpty) {
              if (controller.text.isNotEmpty) {
                controller.text = controller.text.substring(0, controller.text.length - 1);
              }
            } else if (key == '.') {
              if (!controller.text.contains('.')) {
                controller.text += '.';
              }
            } else if (key == '00') {
              controller.text += '00';
            } else {
              controller.text += key;
            }

            if (paymentType == PaymentType.cash) {
              if (controller.text.length > 5) {
                controller.text = controller.text.substring(0, 5);
              }

              if (controller.text.contains('.')) {
                final parts = controller.text.split('.');
                if (parts.length > 1 && parts[1].length > 2) {
                  controller.text = '${parts[0]}.${parts[1].substring(0, 2)}';
                }
              }
              _calculateChange();
            }

            if (controller == _preferentialController) {
              if (controller.text.contains('.')) {
                final parts = controller.text.split('.');
                if (parts.length > 1 && parts[1].length > 2) {
                  controller.text = '${parts[0]}.${parts[1].substring(0, 2)}';
                }
              }
            }
          },
          child: key.isEmpty
              ? const Icon(Icons.backspace, size: 24)
              : Text(
            key,
            style: TextStyle(
              fontSize: 20,
              fontWeight: key.isEmpty ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        );
      },
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required FocusNode focusNode,
    required String hintText,
    required String labelText,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    bool autofocus = false,
    bool readOnly = false,
  }) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      readOnly: readOnly,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      decoration: InputDecoration(
        hintText: hintText,
        labelText: labelText,
        labelStyle: const TextStyle(fontSize: 20, color: Color(0xFF666666)),
        hintStyle: const TextStyle(fontSize: 18, color: Color(0xFF999999)),
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
        contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        suffixIcon: controller.text.isNotEmpty
            ? IconButton(
          icon: const Icon(Icons.clear, size: 28, color: Color(0xFF999999)),
          onPressed: () {
            controller.clear();
            if (controller == _receivedMoneyController) {
              _calculateChange();
            }
          },
        )
            : null,
        filled: true,
        fillColor: Colors.white,
        alignLabelWithHint: true,
      ),
      style: const TextStyle(fontSize: 22, color: Color(0xFF333333), height: 1.2),
    );
  }

  Widget _buildInputField() {
    if (_selectedPaymentType == PaymentType.scan) {
      return Column(
        children: [
          _buildTextField(
            controller: _paymentCodeController,
            focusNode: _paymentCodeFocusNode,
            hintText: '请输入微信/支付宝/银联付款码（15-30位）',
            labelText: '顾客付款码',
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(30),
            ],
            autofocus: true,
          ),
          const SizedBox(height: 20),
          _buildNumberKeyboard(_paymentCodeController, PaymentType.scan),
        ],
      );
    } else if (_selectedPaymentType == PaymentType.cash) {
      return Column(
        children: [
          _buildTextField(
            controller: _receivedMoneyController,
            focusNode: _receivedMoneyFocusNode,
            hintText: '请输入实收金额（最多5位）',
            labelText: '实收金额',
            keyboardType: TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^\d+\.?\d{0,2}$')),
              LengthLimitingTextInputFormatter(5),
            ],
            autofocus: true,
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade200, width: 1),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('找零金额', style: TextStyle(fontSize: 18, color: Color(0xFF666666))),
                Text(
                  '¥${_changeMoney.toStringAsFixed(2)}',
                  style: const TextStyle(fontSize: 18, color: Color(0xFFFF4444), fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _buildNumberKeyboard(_receivedMoneyController, PaymentType.cash),
        ],
      );
    } else if (_selectedPaymentType == PaymentType.member) {
      return Column(
        children: [
          _buildTextField(
            controller: _memberPhoneController,
            focusNode: _memberPhoneFocusNode,
            hintText: '请输入会员手机号（11位）',
            labelText: '会员手机号',
            keyboardType: TextInputType.phone,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(11),
            ],
            autofocus: true,
            readOnly: false,
          ),
          const SizedBox(height: 20),
          _buildNumberKeyboard(_memberPhoneController, PaymentType.member),
        ],
      );
    } else {
      return Container();
    }
  }

  Widget _buildDiscountPreferentialArea() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200, width: 2),
        boxShadow: [BoxShadow(color: Colors.grey.withOpacity(0.08), blurRadius: 8, offset: const Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('优惠信息', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF333333))),
              TextButton(
                onPressed: _resetDiscountAndPreferential,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  minimumSize: const Size(80, 40),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  backgroundColor: const Color(0xFFFEEEEE),
                ),
                child: const Text('重置优惠', style: TextStyle(color: Color(0xFFFF4444), fontSize: 16)),
              ),
            ],
          ),
          const SizedBox(height: 24),
          _buildAmountItem('整单折扣(${(_discountRate * 10).toStringAsFixed(1)}折)',
              '-¥${(_originalTotalPrice - _calculateDiscountPrice()).toStringAsFixed(2)}',
              const Color(0xFFFF4444)),
          const SizedBox(height: 16),
          _buildAmountItem('整单优惠',
              '-¥${_preferentialAmount.toStringAsFixed(2)}',
              const Color(0xFF2196F3)),
          const SizedBox(height: 24),
          _buildTextField(
            controller: _discountController,
            focusNode: _discountFocusNode,
            hintText: '输入折扣率（如0.8=8折，范围0.1-1.0）',
            labelText: '整单折扣率',
            keyboardType: TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^\d+\.?\d{0,2}$')),
              LengthLimitingTextInputFormatter(4),
            ],
          ),
          const SizedBox(height: 20),
          _buildTextField(
            controller: _preferentialController,
            focusNode: _preferentialFocusNode,
            hintText: '输入优惠金额（最高${_calculateDiscountPrice().toStringAsFixed(2)}元）',
            labelText: '整单优惠金额',
            keyboardType: TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^\d+\.?\d{0,2}$')),
              LengthLimitingTextInputFormatter(7),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAmountItem(String label, String value, Color textColor, {bool isBold = false, double fontSize = 20}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: fontSize,
            color: const Color(0xFF666666),
            fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: fontSize,
            color: textColor,
            fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_realCashierName == null || _realRenyuanId == null) {
      return const Scaffold(
        backgroundColor: Color(0xFFF5F5F5),
        body: Center(child: CircularProgressIndicator(color: Color(0xFFFF4444), strokeWidth: 4)),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF8F8F8),
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: Colors.black, size: 24),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          widget.mode == OrderPageMode.shouyin ? '结算页面' : '提交订单',
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF333333)),
        ),
        centerTitle: true,
        backgroundColor: Colors.white,
        elevation: 2,
        shadowColor: Colors.grey.withOpacity(0.15),
        toolbarHeight: 70,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(bottom: Radius.circular(16)),
        ),
        actions: const [],
      ),
      body: Row(
        children: [
          Expanded(
            flex: 6,
            child: Container(
              margin: const EdgeInsets.all(20),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [BoxShadow(color: Colors.grey.withOpacity(0.1), blurRadius: 12, offset: const Offset(0, 6))],
              ),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.grey.shade200, width: 2),
                      boxShadow: [BoxShadow(color: Colors.grey.withOpacity(0.08), blurRadius: 8, offset: const Offset(0, 4))],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('订单信息', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF333333))),
                        const SizedBox(height: 24),
                        _buildAmountItem(
                          '商品数量',
                          '${widget.cartItems.fold(0, (int sum, CartItem item) => sum + item.quantity)}件',
                          const Color(0xFF333333),
                        ),
                        const SizedBox(height: 16),
                        _buildAmountItem(
                          '商品总价',
                          '¥${widget.totalPrice.toStringAsFixed(2)}',
                          const Color(0xFF333333),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: _buildDiscountPreferentialArea(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            flex: 4,
            child: Container(
              margin: const EdgeInsets.all(20),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [BoxShadow(color: Colors.grey.withOpacity(0.1), blurRadius: 12, offset: const Offset(0, 6))],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _buildPaymentCard(PaymentType.cash),
                      _buildPaymentCard(PaymentType.scan),
                      _buildPaymentCard(PaymentType.member),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: _buildInputField(),
                    ),
                  ),
                  const SizedBox(height: 30),
                  SizedBox(
                    width: double.infinity,
                    height: 128,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFF4444),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        elevation: 8,
                        shadowColor: const Color(0xFFFF4444).withOpacity(0.4),
                      ),
                      onPressed: _isLoading ? null : (_selectedPaymentType == PaymentType.member ? _verifyVip : _submitOrder),
                      child: _isLoading
                          ? const CircularProgressIndicator(color: Colors.white, strokeWidth: 4)
                          : Text(
                        _selectedPaymentType == PaymentType.member
                            ? '扣款 ¥${_calculateFinalPrice().toStringAsFixed(2)}'
                            : '结算 ¥${_calculateFinalPrice().toStringAsFixed(2)}',
                        style: const TextStyle(
                          fontSize: 26,
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.5,
                        ),
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