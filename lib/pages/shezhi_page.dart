import 'package:flutter/material.dart';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart'; // 新增：导入本地存储包
import '../models/login_model.dart'; // 引入UserInfoManager

/// 设置页面（新增在线客服按钮+语音播报开关，保留云打印机功能+美化版下载说明）
class SheZhiPage extends StatefulWidget {
  const SheZhiPage({super.key});

  @override
  State<SheZhiPage> createState() => _SheZhiPageState();
}

class _SheZhiPageState extends State<SheZhiPage> {
  // 易联云打印机列表（从后端接口获取）
  List<YilianCloudPrinter> _cloudPrinters = [];
  bool _isLoadingCloud = true; // 云打印机加载状态
  String? _cloudErrorMsg;

  // 新增：语音播报开关相关
  bool _isVoiceEnabled = true; // 语音播报开关状态（默认开启）
  late SharedPreferences _prefs; // 本地存储实例
  bool _isVoiceInit = false; // 语音开关初始化状态

  @override
  void initState() {
    super.initState();
    // 初始化时先加载本地存储，再获取云打印机数据
    _initSharedPreferences();
    _fetchCloudPrintersFromServer();
  }

  // 新增：初始化SharedPreferences并读取语音开关状态
  Future<void> _initSharedPreferences() async {
    _prefs = await SharedPreferences.getInstance();
    // 读取本地存储的语音开关状态（默认开启）
    setState(() {
      _isVoiceEnabled = _prefs.getBool('voice_broadcast_enabled') ?? true;
      _isVoiceInit = true;
    });
  }

  // 新增：切换语音开关状态并保存到本地
  Future<void> _toggleVoiceSetting(bool value) async {
    setState(() {
      _isVoiceEnabled = value;
    });
    // 保存开关状态到本地
    await _prefs.setBool('voice_broadcast_enabled', value);

    // 提示用户开关状态
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          value ? '语音播报已开启' : '语音播报已关闭',
          textAlign: TextAlign.center,
        ),
        backgroundColor: value ? Colors.green : Colors.grey,
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // 调用ThinkPHP8后端接口获取云打印机列表（动态传wenxun_id）
  Future<void> _fetchCloudPrintersFromServer() async {
    setState(() {
      _isLoadingCloud = true;
      _cloudErrorMsg = null;
    });

    try {
      // 1. 从本地获取当前商户的wenxun_id
      final UserInfoManager userManager = UserInfoManager();
      String? wenxunIdStr = await userManager.getWenxunId();
      if (wenxunIdStr == null || wenxunIdStr.isEmpty) {
        throw Exception('未获取到商户ID，请重新登录');
      }

      // 2. 调用后端接口（POST请求）
      final response = await http.post(
        Uri.parse('https://shop.wx-zf.com/api/printer/huoqu'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {'wenxun_id': wenxunIdStr},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['code'] == 200) {
          // 3. 解析接口返回的打印机数据
          final printerData = data['data'];
          setState(() {
            _cloudPrinters = [
              YilianCloudPrinter(
                sn: printerData['machine_code'] ?? '',
                name: printerData['name'] ?? '易联云打印机',
                status: '在线', // 可根据实际接口返回字段调整
                type: '易联云打印机', // 可根据实际接口返回字段调整
              )
            ];
          });
        } else {
          throw Exception(data['msg'] ?? '获取打印机失败');
        }
      } else {
        throw Exception('请求失败，状态码：${response.statusCode}');
      }
    } catch (e) {
      setState(() {
        _cloudErrorMsg = e.toString();
      });
    } finally {
      setState(() {
        _isLoadingCloud = false;
      });
    }
  }

  // 调用打印测试页接口
  Future<void> _printTestPage(YilianCloudPrinter printer) async {
    try {
      // 1. 获取当前商户的wenxun_id
      final UserInfoManager userManager = UserInfoManager();
      String? wenxunIdStr = await userManager.getWenxunId();
      if (wenxunIdStr == null || wenxunIdStr.isEmpty) {
        throw Exception('未获取到商户ID，请重新登录');
      }

      // 2. 调用打印测试接口（传递wenxun_id和打印机SN）
      final response = await http.post(
        Uri.parse('https://shop.wx-zf.com/api/printer/printTest'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'wenxun_id': wenxunIdStr,
          'machine_code': printer.sn, // 传递打印机SN
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['code'] == 200) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('${data['msg'] ?? '打印测试页已发送'}'), backgroundColor: Colors.green),
            );
          }
        } else {
          throw Exception(data['msg'] ?? '打印测试失败');
        }
      } else {
        throw Exception('请求失败，状态码：${response.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打印测试失败：$e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // 显示客服图片弹窗（和登录页样式一致，支持缩放/点击关闭）
  void _showKefuImage(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black54,
      builder: (BuildContext context) {
        return GestureDetector(
          // 点击图片区域关闭弹窗
          onTap: () => Navigator.pop(context),
          child: Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 20),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  )
                ],
              ),
              padding: const EdgeInsets.all(4),
              child: InteractiveViewer(
                panEnabled: true,
                boundaryMargin: const EdgeInsets.all(10),
                minScale: 0.8,
                maxScale: 2.0,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.asset(
                    'assets/kefu.png', // 客服图片路径（和登录页一致）
                    fit: BoxFit.contain,
                    width: MediaQuery.of(context).size.width * 0.9,
                    height: MediaQuery.of(context).size.height * 0.7,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // 构建美化版下载说明组件
  Widget _buildDownloadInstruction() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.grey.withOpacity(0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.withOpacity(0.1)),
          boxShadow: [
            BoxShadow(
              color: Colors.grey.withOpacity(0.08),
              blurRadius: 8,
              offset: const Offset(0, 2),
            )
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题
            const Text(
              'APP下载说明',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Color(0xFF333333),
              ),
            ),
            const SizedBox(height: 12),
            // 苹果手机说明
            _buildSystemInstructionRow(
              system: '苹果手机',
              color: const Color(0xFF007AFF),
              content: '前往苹果应用商店下载稳讯收银APP，可添加商品或联系客服协助批量导入商品、批量导入会员',
            ),
            const SizedBox(height: 8),
            // 安卓手机说明
            _buildSystemInstructionRow(
              system: '安卓手机',
              color: const Color(0xFF3DDC84),
              content: '前往各应用市场下载稳讯收银APP，可添加商品或联系客服协助批量导入商品、批量导入会员',
            ),
            const SizedBox(height: 8),
            // 鸿蒙手机说明
            _buildSystemInstructionRow(
              system: '鸿蒙手机',
              color: const Color(0xFFFF6700),
              content: '前往应用市场下载稳讯收银APP，可添加商品或联系客服协助批量导入商品、批量导入会员',
            ),
          ],
        ),
      ),
    );
  }

  // 构建单个系统的说明行
  Widget _buildSystemInstructionRow({
    required String system,
    required Color color,
    required String content,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 系统标签
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          margin: const EdgeInsets.only(right: 8, top: 2),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: color.withOpacity(0.2)),
          ),
          child: Text(
            system,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        // 说明内容
        Expanded(
          child: Text(
            content,
            style: const TextStyle(
              fontSize: 14,
              color: Color(0xFF666666),
              height: 1.4, // 行高优化可读性
            ),
          ),
        ),
      ],
    );
  }

  // 构建在线客服按钮（绿色背景+白色文字）
  Widget _buildOnlineServiceButton() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: SizedBox(
        width: double.infinity,
        height: 55, // 适配触屏的按钮高度
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF00C853), // 绿色背景
            foregroundColor: Colors.white, // 白色文字
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12), // 圆角美化
            ),
            elevation: 4,
            shadowColor: const Color(0xFF00C853).withOpacity(0.3),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
          ),
          onPressed: () => _showKefuImage(context),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.headset_mic, size: 20, color: Colors.white),
              SizedBox(width: 8),
              Text(
                '在线客服',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 新增：构建语音播报开关组件
  Widget _buildVoiceSwitch() {
    // 未初始化完成时显示加载占位
    if (!_isVoiceInit) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 20, vertical: 15),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '语音播报',
              style: TextStyle(fontSize: 18, color: Color(0xFF333333)),
            ),
            CircularProgressIndicator(
              color: Color(0xFF00C853),
              strokeWidth: 2,

            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.grey.withOpacity(0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.withOpacity(0.1)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(
                  _isVoiceEnabled ? Icons.volume_up : Icons.volume_off,
                  color: _isVoiceEnabled ? const Color(0xFF00C853) : const Color(0xFF999999),
                  size: 24,
                ),
                const SizedBox(width: 12),
                const Text(
                  '语音播报',
                  style: TextStyle(
                    fontSize: 18,
                    color: Color(0xFF333333),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            Switch(
              value: _isVoiceEnabled,
              onChanged: _toggleVoiceSetting,
              activeColor: const Color(0xFF00C853), // 开启时绿色
              activeTrackColor: const Color(0xFF00C853).withOpacity(0.2),
              inactiveThumbColor: const Color(0xFF999999), // 关闭时灰色
              inactiveTrackColor: const Color(0xFFEEEEEE),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ],
        ),
      ),
    );
  }

  // 构建云打印机页面
  Widget _buildCloudPrinterPage() {
    return Column(
      children: [
        // 下载说明区域
        _buildDownloadInstruction(),
        const Divider(height: 1, color: Color(0xFFEEEEEE)),
        // 在线客服按钮
        _buildOnlineServiceButton(),
        const Divider(height: 1, color: Color(0xFFEEEEEE)),
        // 新增：语音播报开关
        _buildVoiceSwitch(),
        const Divider(height: 1, color: Color(0xFFEEEEEE)),
        // 云打印机说明
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.blue.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.blue.withOpacity(0.2)),
            ),
            child: const Text(
              '易联云打印机列表',
              style: TextStyle(color: Color(0xFF333333), fontSize: 15),
            ),
          ),
        ),
        const Divider(height: 1, color: Color(0xFFEEEEEE)),
        // 云打印机列表
        Expanded(
          child: _isLoadingCloud
              ? const Center(
            child: CircularProgressIndicator(
              color: Color(0xFFFF4444),
              strokeWidth: 3,
            ),
          )
              : _cloudErrorMsg != null
              ? Center(
            child: Text(
              _cloudErrorMsg!,
              style: const TextStyle(color: Colors.red, fontSize: 16),
              textAlign: TextAlign.center,
            ),
          )
              : _cloudPrinters.isEmpty
              ? const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.print, size: 80, color: Color(0xFFCCCCCC)),
                SizedBox(height: 20),
                Text(
                  '暂无云打印机数据',
                  style: TextStyle(fontSize: 18, color: Color(0xFF666666)),
                ),
              ],
            ),
          )
              : ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 10),
            itemCount: _cloudPrinters.length,
            itemBuilder: (context, index) {
              final printer = _cloudPrinters[index];
              return _buildCloudPrinterItem(printer);
            },
          ),
        ),
      ],
    );
  }

  // 构建云打印机列表项（保留打印测试按钮）
  Widget _buildCloudPrinterItem(YilianCloudPrinter printer) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(color: Colors.grey.withOpacity(0.1), blurRadius: 4, offset: const Offset(0, 2)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 15),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              Icons.print,
              size: 45,
              color: printer.status == '在线' ? const Color(0xFF00B42A) : const Color(0xFF999999),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    printer.name,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w600, color: Color(0xFF333333)),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'SN码：${printer.sn}',
                    style: const TextStyle(fontSize: 15, color: Color(0xFF666666)),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '型号：${printer.type}',
                    style: const TextStyle(fontSize: 15, color: Color(0xFF666666)),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // 状态标签 + 打印测试按钮
            Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: printer.status == '在线'
                        ? const Color(0xFF00B42A).withOpacity(0.1)
                        : const Color(0xFF999999).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    printer.status,
                    style: TextStyle(
                      color: printer.status == '在线' ? const Color(0xFF00B42A) : const Color(0xFF999999),
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // 打印测试页按钮
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2196F3),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  ),
                  onPressed: () => _printTestPage(printer),
                  child: const Text('打印测试页', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: Container(
        margin: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(color: Colors.grey.withOpacity(0.1), blurRadius: 6, offset: const Offset(0, 3)),
          ],
        ),
        child: _buildCloudPrinterPage(),
      ),
    );
  }
}

// 易联云打印机模型
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