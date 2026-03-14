import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/services.dart'; // 保留导入（避免影响其他潜在使用）
import '../models/login_model.dart';
import 'login_page.dart';

// 易联云打印机模型（复用设置页面的模型）
class YilianCloudPrinter {
  final String sn;
  final String name;
  final String status;
  final String type;

  YilianCloudPrinter({
    required this.sn,
    required this.name,
    required this.status,
    required this.type,
  });
}

// 交班数据模型
class JiaoBanData {
  final double totalTurnover; // 总营业额
  final int paymentCount; // 支付笔数
  final DateTime startTime; // 上班时间（第一笔订单时间）
  final DateTime endTime; // 下班时间（当前时间）

  JiaoBanData({
    required this.totalTurnover,
    required this.paymentCount,
    required this.startTime,
    required this.endTime,
  });
}

// 接口返回数据模型
class JiaoBanApiResponse {
  final int code;
  final double zongyingye;
  final int bishu;
  final String? firstOrderTime;

  JiaoBanApiResponse({
    required this.code,
    required this.zongyingye,
    required this.bishu,
    this.firstOrderTime,
  });

  factory JiaoBanApiResponse.fromJson(Map<String, dynamic> json) {
    return JiaoBanApiResponse(
      code: json['code'] ?? 0,
      zongyingye: (json['zongyingye'] ?? 0.0).toDouble(),
      bishu: (json['bishu'] ?? 0).toInt(),
      firstOrderTime: json['first_order_time'] ?? json['shijian'] ?? null,
    );
  }
}

/// 交班页面（修正按钮尺寸：适配小屏收银机）
class JiaoBanPage extends StatefulWidget {
  const JiaoBanPage({super.key});

  @override
  State<JiaoBanPage> createState() => _JiaoBanPageState();
}

class _JiaoBanPageState extends State<JiaoBanPage> {
  JiaoBanData? _currentData;
  bool? _isLoading;
  String? _errorMsg;

  // 云打印机相关状态（复用设置页面逻辑）
  List<YilianCloudPrinter> _cloudPrinters = [];
  bool _isLoadingPrinters = false;
  String? _printerErrorMsg;

  late Future<Map<String, String?>> _userInfoFuture;
  final UserInfoManager _userManager = UserInfoManager();
  static const String _jiaobanApiUrl = 'https://shop.wx-zf.com/shouyin/jiaoban/jintian';
  static const String _printApiUrl = 'https://shop.wx-zf.com/api/printer/jiaobanxiaopiao'; // 新增打印小票API
  static const String _printerListApiUrl = 'https://shop.wx-zf.com/api/printer/huoqu'; // 打印机列表API

  // 统一阴影样式（blurRadius=10，符合要求）
  final BoxShadow _defaultShadow = BoxShadow(
    color: Colors.grey.withOpacity(0.15),
    blurRadius: 10, // 核心：四周阴影半径10
    spreadRadius: 2,
    offset: const Offset(0, 4),
  );

  // 全局外层阴影（更强的视觉包裹感）
  final BoxShadow _globalShadow = BoxShadow(
    color: Colors.grey.withOpacity(0.2),
    blurRadius: 10,
    spreadRadius: 3,
    offset: const Offset(0, 6),
  );

  @override
  void initState() {
    super.initState();
    _userInfoFuture = _loadUserInfo();
    // 初始化时获取云打印机列表（和设置页面逻辑一致）
    _fetchCloudPrinters();
  }

  // 获取云打印机列表（复用设置页面逻辑）
  Future<void> _fetchCloudPrinters() async {
    setState(() {
      _isLoadingPrinters = true;
      _printerErrorMsg = null;
    });

    try {
      // 从本地获取当前商户的wenxun_id
      String? wenxunIdStr = await _userManager.getWenxunId();
      if (wenxunIdStr == null || wenxunIdStr.isEmpty) {
        throw Exception('未获取到商户ID，无法加载打印机');
      }

      // 调用打印机列表接口
      final response = await http.post(
        Uri.parse(_printerListApiUrl),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {'wenxun_id': wenxunIdStr},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['code'] == 200) {
          final printerData = data['data'];
          setState(() {
            _cloudPrinters = [
              YilianCloudPrinter(
                sn: printerData['machine_code'],
                name: printerData['name'],
                status: '在线', // 可根据实际接口返回字段调整
                type: '易联云打印机', // 可根据实际接口返回字段调整
              )
            ];
          });
        } else {
          throw Exception(data['msg'] ?? '获取打印机失败');
        }
      } else {
        throw Exception('打印机列表请求失败，状态码：${response.statusCode}');
      }
    } catch (e) {
      setState(() {
        _printerErrorMsg = e.toString();
      });
    } finally {
      setState(() {
        _isLoadingPrinters = false;
      });
    }
  }

  Future<Map<String, String?>> _loadUserInfo() async {
    if (!await _userManager.isLoggedIn()) {
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const LoginPage()),
        );
      }
      return {};
    }

    final userName = await _userManager.getUserName() ?? '未设置';
    final userPhone = await _userManager.getUserPhone() ?? '未设置';
    final renyuan = await _userManager.getRenyuan() ?? '未设置';
    final cashierId = await _userManager.getCashierId();

    if (cashierId != null && cashierId.isNotEmpty) {
      await _fetchJiaoBanData(cashierId);
    } else {
      setState(() {
        _isLoading = false;
        _errorMsg = '员工ID缺失，无法获取交班数据';
      });
    }

    return {
      'userName': userName,
      'userPhone': userPhone,
      'renyuan': renyuan,
    };
  }

  // 解析时间字符串
  DateTime _parseOrderTime(String? timeStr) {
    if (timeStr == null || timeStr.isEmpty) {
      final now = DateTime.now();
      return DateTime(now.year, now.month, now.day);
    }
    try {
      return DateTime.parse(timeStr);
    } catch (e) {
      final now = DateTime.now();
      return DateTime(now.year, now.month, now.day);
    }
  }

  Future<void> _fetchJiaoBanData(String cashierId) async {
    setState(() {
      _isLoading = true;
      _errorMsg = null;
    });

    final client = http.Client();
    try {
      final requestBody = jsonEncode({
        'renyuan_id': cashierId,
      });

      final response = await client.post(
        Uri.parse(_jiaobanApiUrl),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: requestBody,
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final jsonData = jsonDecode(response.body);
        final apiResponse = JiaoBanApiResponse.fromJson(jsonData);

        if (apiResponse.code == 200) {
          final now = DateTime.now();
          final startTime = _parseOrderTime(apiResponse.firstOrderTime);
          final endTime = now;

          setState(() {
            _currentData = JiaoBanData(
              totalTurnover: apiResponse.zongyingye,
              paymentCount: apiResponse.bishu,
              startTime: startTime,
              endTime: endTime,
            );
            _isLoading = false;
          });
        } else {
          setState(() {
            _isLoading = false;
            _errorMsg = '接口返回失败：${jsonData['msg'] ?? '未知错误'}';
          });
        }
      } else {
        setState(() {
          _isLoading = false;
          _errorMsg = '请求失败，状态码：${response.statusCode}';
        });
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMsg = '网络异常：${e.toString()}';
      });
    } finally {
      client.close();
    }
  }

  // 新增：打印交班小票（调用指定API）
  Future<void> _printJiaoBanTicket() async {
    // 1. 检查打印机状态
    if (_isLoadingPrinters) {
      _showSnackBar('正在加载打印机，请稍后...', Colors.orange);
      return;
    }

    if (_printerErrorMsg != null) {
      _showSnackBar('打印机加载失败：$_printerErrorMsg', Colors.red);
      return;
    }

    if (_cloudPrinters.isEmpty) {
      _showSnackBar('暂无可用打印机，请先在设置页面配置', Colors.red);
      return;
    }

    // 2. 筛选在线打印机
    final onlinePrinters = _cloudPrinters.where((p) => p.status == '在线').toList();
    if (onlinePrinters.isEmpty) {
      _showSnackBar('暂无在线打印机，请检查设备状态', Colors.red);
      return;
    }

    // 3. 选择打印机（如果只有一个直接使用，多个则弹窗选择）
    YilianCloudPrinter selectedPrinter;
    if (onlinePrinters.length == 1) {
      selectedPrinter = onlinePrinters.first;
    } else {
      // 多打印机时弹窗选择
      selectedPrinter = await _showPrinterSelectDialog(onlinePrinters);
      if (selectedPrinter.sn.isEmpty) return; // 用户取消选择
    }

    // 4. 调用打印API
    try {
      _showSnackBar('正在发送打印请求...', Colors.blue);

      // 获取必要参数
      String? wenxunIdStr = await _userManager.getWenxunId();
      String? cashierId = await _userManager.getCashierId();
      if (wenxunIdStr == null || wenxunIdStr.isEmpty) {
        throw Exception('未获取到商户ID');
      }
      if (cashierId == null || cashierId.isEmpty) {
        throw Exception('未获取到员工ID');
      }

      // 调用打印接口（POST请求，x-www-form-urlencoded格式）
      final response = await http.post(
        Uri.parse(_printApiUrl),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'wenxun_id': wenxunIdStr,
          'machine_code': selectedPrinter.sn, // 打印机SN
          'renyuan_id': cashierId, // 员工ID
          'zongyingye': _currentData?.totalTurnover.toStringAsFixed(2) ?? '0.00', // 总营业额
          'bishu': _currentData?.paymentCount.toString() ?? '0', // 订单数
          'start_time': _currentData != null ? _formatDateTime(_currentData!.startTime) : '', // 上班时间
          'end_time': _currentData != null ? _formatDateTime(_currentData!.endTime) : '', // 下班时间
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['code'] == 200) {
          _showSnackBar('${data['msg'] ?? '打印请求发送成功'}', Colors.green);
        } else {
          throw Exception(data['msg'] ?? '打印失败');
        }
      } else {
        throw Exception('请求失败，状态码：${response.statusCode}');
      }
    } catch (e) {
      _showSnackBar('打印失败：${e.toString()}', Colors.red);
    }
  }

  // 多打印机选择弹窗
  Future<YilianCloudPrinter> _showPrinterSelectDialog(List<YilianCloudPrinter> printers) async {
    YilianCloudPrinter? selected;
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('选择打印机', style: TextStyle(fontSize: 18)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: printers.map((printer) {
              return ListTile(
                title: Text(printer.name),
                subtitle: Text('SN: ${printer.sn} | ${printer.status}'),
                leading: Icon(Icons.print, color: printer.status == '在线' ? Colors.green : Colors.grey),
                onTap: () {
                  selected = printer;
                  Navigator.pop(context);
                },
              );
            }).toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消', style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );
    return selected ?? YilianCloudPrinter(sn: '', name: '', status: '', type: '');
  }

  // 显示提示信息
  void _showSnackBar(String message, Color color) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: color,
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(8))),
        ),
      );
    }
  }

  Future<void> _confirmJiaoBan() async {
    await _userManager.clearUserInfo();

    if (mounted) {
      _showSnackBar('交班成功！', Colors.green);
    }

    await Future.delayed(const Duration(seconds: 2));
    if (mounted) {
      // 交班成功后返回登录页
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const LoginPage()),
      );
    }
  }

  String _formatDateTime(DateTime dateTime) {
    String _padZero(int number) => number.toString().padLeft(2, '0');
    final year = dateTime.year;
    final month = _padZero(dateTime.month);
    final day = _padZero(dateTime.day);
    final hour = _padZero(dateTime.hour);
    final minute = _padZero(dateTime.minute);
    return '$year-$month-$day $hour:$minute';
  }

  // 构建信息行（标签+值）- 美化版
  Widget _buildInfoRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 16,
            color: Color(0xFF666666),
            fontWeight: FontWeight.w400,
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontSize: 16,
            color: Color(0xFF333333),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  // 修正：构建小屏适配的操作按钮（核心修改：降低高度、缩小文字、优化间距）
  Widget _buildActionButton({
    required String text,
    required Color backgroundColor,
    required VoidCallback? onPressed,
  }) {
    return SizedBox(
      height: 70, // 核心修正1：从140dp降至70dp，小屏不挤压（可根据需求微调为60-80dp）
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: onPressed == null ? Colors.grey[300] : backgroundColor,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12), // 修正2：圆角从16降至12，更贴合小屏比例
          ),
          elevation: 4, // 修正3：阴影从6降至4，小屏视觉更清爽
          shadowColor: backgroundColor.withOpacity(0.3),
          disabledForegroundColor: Colors.white.withOpacity(0.6),
          padding: const EdgeInsets.symmetric(horizontal: 12), // 修正4：内边距从16降至12，减少横向占用
        ),
        onPressed: onPressed,
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 16, // 核心修正5：文字从22号降至16号，小屏不换行
            fontWeight: FontWeight.bold,
            letterSpacing: 1, // 修正6：字母间距从2降至1，避免小屏文字挤压
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5), // 更舒适的浅灰背景
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16), // 外层全局间距（保留，小屏友好）
          child: Container(
            // 全局外层容器：带10半径阴影
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16), // 修正7：全局圆角从20降至16，适配小屏
              boxShadow: [_globalShadow], // 全局外层阴影
            ),
            padding: const EdgeInsets.all(16), // 修正8：全局容器内边距从20降至16，减少内容拥挤
            child: Column(
              children: [
                // 可滚动内容区域（占满剩余空间）
                Expanded(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(), // 弹性滚动，体验更好
                    child: Column(
                      children: [
                        // 模块1：店铺信息（带阴影）
                        Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(bottom: 16), // 修正9：模块间距从20降至16，小屏更紧凑
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [_defaultShadow], // 统一阴影（blurRadius=10）
                            border: Border.all(color: const Color(0xFFF0F0F0), width: 1), // 细边框增强质感
                          ),
                          padding: const EdgeInsets.all(20), // 修正10：模块内边距从24降至20，适配小屏
                          child: FutureBuilder<Map<String, String?>>(
                            future: _userInfoFuture,
                            builder: (context, snapshot) {
                              if (_isLoading == true) {
                                return const Center(
                                  child: CircularProgressIndicator(
                                    color: Color(0xFFE53935),
                                    strokeWidth: 2,
                                  ),
                                );
                              }

                              if (_isLoading == false && _errorMsg != null) {
                                return Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFEF2F2),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: const Color(0xFFFEE2E2), width: 1),
                                  ),
                                  child: Text(
                                    _errorMsg!,
                                    style: const TextStyle(
                                      color: Color(0xFFE53935),
                                      fontSize: 16,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                );
                              }

                              final userInfo = snapshot.data ?? {};
                              final shopName = userInfo['userName'] ?? '未设置';
                              final staffName = userInfo['renyuan'] ?? '未设置';
                              final staffPhone = userInfo['userPhone'] ?? '未设置';

                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // 标题
                                  const Text(
                                    '店铺信息',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF333333),
                                    ),
                                  ),
                                  const Divider(height: 20, thickness: 1, color: Color(0xFFEEEEEE)),

                                  // 店铺名称
                                  _buildInfoRow('店铺名称', shopName),
                                  const SizedBox(height: 12),

                                  // 员工姓名（替换原收银员姓名）
                                  _buildInfoRow('员工姓名', staffName),
                                  const SizedBox(height: 12),

                                  // 员工手机（替换原收银员手机号）
                                  _buildInfoRow('员工手机', staffPhone),
                                  const SizedBox(height: 12),

                                  // 上班时间
                                  _buildInfoRow(
                                    '上班时间',
                                    _currentData != null ? _formatDateTime(_currentData!.startTime) : '---- --:--',
                                  ),
                                  const SizedBox(height: 12),

                                  // 下班时间
                                  _buildInfoRow(
                                    '下班时间',
                                    _currentData != null ? _formatDateTime(_currentData!.endTime) : '---- --:--',
                                  ),
                                ],
                              );
                            },
                          ),
                        ),

                        // 模块2：交易数据（带阴影，一行两列）
                        Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(bottom: 16), // 修正11：模块间距从20降至16
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [_defaultShadow], // 统一阴影（blurRadius=10）
                            border: Border.all(color: const Color(0xFFF0F0F0), width: 1),
                          ),
                          padding: const EdgeInsets.all(20), // 修正12：模块内边距从24降至20
                          child: _isLoading == true
                              ? const Center(
                            child: CircularProgressIndicator(
                              color: Color(0xFFE53935),
                              strokeWidth: 2,
                            ),
                          )
                              : Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              // 左侧：总营业额
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    const Text(
                                      '总营业额',
                                      style: TextStyle(
                                        fontSize: 16,
                                        color: Color(0xFF666666),
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      '¥${_currentData?.totalTurnover.toStringAsFixed(2) ?? '0.00'}',
                                      style: const TextStyle(
                                        fontSize: 28, // 修正13：金额文字从42降至28，小屏不溢出
                                        color: Color(0xFFE53935),
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 2,
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              // 分割线
                              Container(
                                width: 1,
                                height: 60, // 修正14：分割线高度从80降至60，适配小屏
                                color: const Color(0xFFEEEEEE),
                                margin: const EdgeInsets.symmetric(horizontal: 16), // 修正15：分割线间距从20降至16
                              ),

                              // 右侧：订单数
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    const Text(
                                      '订单数',
                                      style: TextStyle(
                                        fontSize: 16,
                                        color: Color(0xFF666666),
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      '${_currentData?.paymentCount ?? 0}',
                                      style: const TextStyle(
                                        fontSize: 28, // 修正16：订单数文字从42降至28，小屏不溢出
                                        color: Color(0xFF333333),
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 2,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // 底部固定按钮区域（始终显示）- 移除返回桌面按钮
                // 修正17：按钮之间间距从12降至8，小屏横向不挤压
                Row(
                  children: [
                    // 确认交班按钮
                    Expanded(
                      child: _buildActionButton(
                        text: '确认交班',
                        backgroundColor: const Color(0xFFE53935),
                        onPressed: _isLoading == true ? null : _confirmJiaoBan,
                      ),
                    ),
                    const SizedBox(width: 8),

                    // 打印小票按钮（修改为调用新API）
                    Expanded(
                      child: _buildActionButton(
                        text: '打印小票',
                        backgroundColor: const Color(0xFFF44336).withOpacity(0.9),
                        onPressed: _currentData == null || _isLoadingPrinters ? null : _printJiaoBanTicket,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}