import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import '../models/login_model.dart';
import 'din_can_page.dart';

// 桌台模型（修正状态样式+过滤无效状态）
class ZhuotaiModel {
  final int id;
  final String name;
  final String? quyu;
  final String renshu;
  final int wenxunId;
  final String status; // 仅保留：0-空闲 1-已预定 2-就餐中 3-扫码点餐
  final String title;

  ZhuotaiModel({
    required this.id,
    required this.name,
    this.quyu,
    required this.renshu,
    required this.wenxunId,
    required this.status,
    required this.title,
  });

  factory ZhuotaiModel.fromJson(Map<String, dynamic> json) {
    final dynamic statusValue = json['status'] ?? 0;
    final String status = statusValue is int ? statusValue.toString() : (statusValue as String? ?? '0');

    // 过滤无效状态，仅保留0/1/2/3
    final validStatus = ['0', '1', '2', '3'].contains(status) ? status : '0';

    return ZhuotaiModel(
      id: json['id'] is int ? json['id'] : 0,
      name: json['name'] is String ? json['name'] : '',
      quyu: json['quyu'] is String ? json['quyu'] : null,
      renshu: json['renshu'] is String ? json['renshu'] : '',
      wenxunId: json['wenxun_id'] is int ? json['wenxun_id'] : 0,
      status: validStatus,
      title: json['title'] is String ? json['title'] : '',
    );
  }

  // 复制模型（用于更新状态）
  ZhuotaiModel copyWith({
    int? id,
    String? name,
    String? quyu,
    String? renshu,
    int? wenxunId,
    String? status,
    String? title,
  }) {
    return ZhuotaiModel(
      id: id ?? this.id,
      name: name ?? this.name,
      quyu: quyu ?? this.quyu,
      renshu: renshu ?? this.renshu,
      wenxunId: wenxunId ?? this.wenxunId,
      status: status ?? this.status,
      title: title ?? this.title,
    );
  }

  // 桌台卡片背景色（修正：空闲-白 预定/扫码点餐-绿 就餐中-红）
  Color get cardBgColor {
    switch (status) {
      case '1': // 已预定
      case '3': // 扫码点餐（原8改为3）
        return Colors.green.shade500;
      case '2': // 就餐中
        return Colors.red.shade500;
      default: // 0-空闲
        return Colors.white;
    }
  }

  // 桌台卡片文字颜色（修正：空闲-黑 其他-白）
  Color get cardTextColor {
    switch (status) {
      case '0': // 空闲
        return Colors.black87;
      default: // 预定/就餐中/扫码点餐
        return Colors.white;
    }
  }

  // 状态文字颜色
  Color get statusTextColor => cardTextColor;

  // 桌台卡片边框颜色
  Color get cardBorderColor {
    switch (status) {
      case '1':
      case '3':
        return Colors.green.shade200;
      case '2':
        return Colors.red.shade200;
      default:
        return Colors.grey.shade200;
    }
  }
}

class KaiTaiPage extends StatefulWidget {
  const KaiTaiPage({super.key});

  @override
  State<KaiTaiPage> createState() => _KaiTaiPageState();
}

class _KaiTaiPageState extends State<KaiTaiPage> {
  final UserInfoManager _userManager = UserInfoManager();
  final String _zhuotaiApiUrl = 'https://shop.wx-zf.com/shouyin/zhuotai';
  final String _kaitaiApiUrl = 'https://shop.wx-zf.com/shouyin/zhuotai/kaitai';
  final String _sseUrl = 'https://shop.wx-zf.com/shouyin/zhuotai/sseConnect';
  final String _updateStatusUrl = 'https://shop.wx-zf.com/shouyin/zhuotai/updateStatus';
  // 新增：取消订单接口地址
  final String _cancelOrderUrl = 'https://shop.wx-zf.com/shouyin/zhuotai/cancelOrder';

  int? _currentWenxunId;
  Map<String, List<ZhuotaiModel>> _quyuZhuotaiMap = {};
  List<String> _quyuList = [];
  String _selectedQuyu = '全部';
  bool _isLoading = true;
  String? _errorMessage;

  // SSE 相关
  StreamController<Map<String, dynamic>>? _sseController;
  Timer? _sseReconnectTimer;
  Timer? _debounceTimer;
  // 顶部提示相关
  OverlayEntry? _toastEntry;
  Timer? _toastTimer;

  // 样式常量
  final Color _selectedTextColor = Colors.red;
  final Color _unselectedTextColor = Colors.black;
  final Color _unselectedBgColor = Colors.white;
  final Color _cardShadowColor = Colors.grey.withOpacity(0.2);
  final Color _grey500 = Colors.grey.shade500;
  final BorderRadius _borderRadius12 = BorderRadius.circular(12);

  @override
  void initState() {
    super.initState();
    _fetchZhuotaiList();
    _initSSE();
  }

  @override
  void dispose() {
    _sseController?.close();
    _sseReconnectTimer?.cancel();
    _debounceTimer?.cancel();
    _toastTimer?.cancel();
    _removeToast();
    super.dispose();
  }

  /// 显示顶部提示弹窗（1秒后消失）
  void _showTopToast(String message, {Color backgroundColor = Colors.green}) {
    // 先移除之前的提示
    _removeToast();

    // 创建顶部提示弹窗
    _toastEntry = OverlayEntry(
      builder: (context) => Positioned(
        top: MediaQuery.of(context).padding.top + 10,
        left: 20,
        right: 20,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                )
              ],
            ),
            child: Text(
              message,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );

    // 添加到Overlay
    Overlay.of(context).insert(_toastEntry!);

    // 1秒后移除
    _toastTimer = Timer(const Duration(seconds: 1), () {
      _removeToast();
    });
  }

  /// 移除顶部提示弹窗
  void _removeToast() {
    _toastTimer?.cancel();
    _toastEntry?.remove();
    _toastEntry = null;
  }

  /// 初始化 SSE 连接
  void _initSSE() async {
    final wenxunId = await _userManager.getWenxunId();
    if (wenxunId == null || wenxunId.isEmpty) return;

    _sseController = StreamController.broadcast();
    _connectSSE(wenxunId);

    _sseController?.stream.listen((event) {
      if (event['type'] == 'zhuotai_update') {
        _handleZhuotaiUpdate(event['data']);
      }
    });
  }

  /// 建立 SSE 连接
  void _connectSSE(String wenxunId) async {
    try {
      final url = Uri.parse('$_sseUrl?wx_id=$wenxunId');
      final request = http.Request('GET', url);
      request.headers['Accept'] = 'text/event-stream';
      final response = await request.send();

      await for (var chunk in response.stream.transform(utf8.decoder)) {
        _parseSSEChunk(chunk);
      }
    } catch (e) {
      print('SSE 连接异常: $e');
      _showTopToast('SSE连接异常，正在重连', backgroundColor: Colors.orange);
      _reconnectSSE();
    }
  }

  /// 解析 SSE 数据块
  void _parseSSEChunk(String chunk) {
    final lines = chunk.split('\n');
    String? eventType;
    String? data;

    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('event: ')) {
        eventType = line.replaceFirst('event: ', '');
      } else if (line.startsWith('data: ')) {
        data = line.replaceFirst('data: ', '');
      }
    }

    if (eventType != null && data != null && data.isNotEmpty) {
      if (eventType == 'ping') {
        return;
      } else if (eventType == 'zhuotai_update') {
        _sseController?.add({
          'type': 'zhuotai_update',
          'data': json.decode(data)
        });
      }
    }
  }

  /// SSE 断线重连
  void _reconnectSSE() {
    _sseReconnectTimer?.cancel();
    _sseReconnectTimer = Timer(const Duration(seconds: 3), () async {
      final wenxunId = await _userManager.getWenxunId();
      if (wenxunId != null) {
        _connectSSE(wenxunId);
      }
    });
  }

  /// 处理桌台状态更新
  void _handleZhuotaiUpdate(dynamic updateData) {
    if (updateData['code'] != 200 || updateData['updated_list'].isEmpty) return;

    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(seconds: 1), () {
      setState(() {
        List<dynamic> updatedList = updateData['updated_list'];
        for (var item in updatedList) {
          ZhuotaiModel updatedZhuotai = ZhuotaiModel.fromJson(item);
          _quyuZhuotaiMap.forEach((quyu, list) {
            for (int i = 0; i < list.length; i++) {
              if (list[i].id == updatedZhuotai.id) {
                _quyuZhuotaiMap[quyu]![i] = updatedZhuotai;
                break;
              }
            }
          });
        }
      });

      // 替换为顶部提示
      _showTopToast('桌台状态已更新');
    });
  }

  /// 获取桌台列表
  Future<void> _fetchZhuotaiList() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final wenxunIdStr = await _userManager.getWenxunId();
      if (wenxunIdStr == null || wenxunIdStr.isEmpty) {
        setState(() {
          _errorMessage = '未获取到商户信息，请重新登录';
          _isLoading = false;
        });
        _showTopToast('未获取到商户信息，请重新登录', backgroundColor: Colors.red);
        return;
      }

      _currentWenxunId = int.tryParse(wenxunIdStr);
      if (_currentWenxunId == null) {
        setState(() {
          _errorMessage = '商户ID格式错误，请重新登录';
          _isLoading = false;
        });
        _showTopToast('商户ID格式错误，请重新登录', backgroundColor: Colors.red);
        return;
      }

      final response = await http.post(
        Uri.parse(_zhuotaiApiUrl),
        headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {'wenxun_id': _currentWenxunId.toString()},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['code'] == 200) {
          final List<dynamic> zhuotaiJsonList = data['canyin'] ?? [];
          final List<ZhuotaiModel> zhuotaiList = zhuotaiJsonList
              .map((json) => ZhuotaiModel.fromJson(json))
              .where((z) => z.wenxunId == _currentWenxunId)
              .toList();

          final Map<String, List<ZhuotaiModel>> groupMap = {};
          groupMap['全部'] = List.from(zhuotaiList);
          for (final z in zhuotaiList) {
            final quyu = z.quyu ?? '未分组';
            if (!groupMap.containsKey(quyu)) {
              groupMap[quyu] = [];
            }
            groupMap[quyu]!.add(z);
          }

          _quyuList = ['全部'] + groupMap.keys.where((key) => key != '全部').toList();

          setState(() {
            _quyuZhuotaiMap = groupMap;
            _isLoading = false;
          });
        } else {
          setState(() {
            _errorMessage = data['msg'] ?? '获取桌台列表失败';
            _isLoading = false;
          });
          _showTopToast(data['msg'] ?? '获取桌台列表失败', backgroundColor: Colors.red);
        }
      } else {
        setState(() {
          _errorMessage = '请求失败：状态码${response.statusCode}';
          _isLoading = false;
        });
        _showTopToast('请求失败：状态码${response.statusCode}', backgroundColor: Colors.red);
      }
    } on TimeoutException {
      setState(() {
        _errorMessage = '请求超时，请检查网络';
        _isLoading = false;
      });
      _showTopToast('请求超时，请检查网络', backgroundColor: Colors.red);
    } catch (e) {
      setState(() {
        _errorMessage = '加载桌台失败：${e.toString()}';
        _isLoading = false;
      });
      _showTopToast('加载桌台失败：${e.toString()}', backgroundColor: Colors.red);
    }
  }

  /// 切换区域
  void _switchQuyu(String quyu) {
    setState(() {
      _selectedQuyu = quyu;
    });
  }

  /// 获取选中区域的桌台
  List<ZhuotaiModel> _getSelectedZhuotai() {
    return _quyuZhuotaiMap[_selectedQuyu] ?? [];
  }

  /// 处理桌台点击事件（简化：根据状态显示对应操作菜单）
  void _handleZhuotaiTap(ZhuotaiModel zhuotai) {
    switch (zhuotai.status) {
      case '0': // 空闲 → 点餐/预定/清台
        _showIdleOperationDialog(zhuotai);
        break;
      case '1': // 已预定 → 点餐/取消预定/清台
        _showBookedOperationDialog(zhuotai);
        break;
      case '2': // 就餐中 → 点餐/加菜/退菜/结账/取消订单
        _showDiningOperationDialog(zhuotai);
        break;
      case '3': // 扫码点餐 → 点餐/加菜/退菜/结账/取消订单
        _showScanOrderOperationDialog(zhuotai);
        break;
      default: // 其他状态 → 提示
        _showTopToast('${zhuotai.title}桌当前状态：${_getStatusText(zhuotai.status)}，无法操作', backgroundColor: Colors.grey.shade600);
        break;
    }
  }

  /// 空闲桌台操作弹窗（中餐适配：点餐/预定/清台）
  Future<void> _showIdleOperationDialog(ZhuotaiModel zhuotai) async {
    showDialog(
      context: context,
      barrierDismissible: true, // 点击空白处关闭
      builder: (context) => AlertDialog(
        title: Center(child: Text(zhuotai.title)), // 标题居中
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: _borderRadius12),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 点餐
            _buildDialogButton(
              text: '点餐',
              color: Colors.red,
              onTap: () {
                Navigator.pop(context);
                _showKaitaiDialog(zhuotai);
              },
            ),
            const SizedBox(height: 8),
            // 预定
            _buildDialogButton(
              text: '预定',
              color: Colors.green,
              onTap: () async {
                Navigator.pop(context);
                await _updateZhuotaiStatus(zhuotai, '1');
              },
            ),
            const SizedBox(height: 8),
            // 清台
            _buildDialogButton(
              text: '清台',
              color: Colors.grey,
              onTap: () async {
                Navigator.pop(context);
                await _updateZhuotaiStatus(zhuotai, '0');
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 已预定桌台操作弹窗（中餐适配：点餐/取消预定/清台）
  Future<void> _showBookedOperationDialog(ZhuotaiModel zhuotai) async {
    showDialog(
      context: context,
      barrierDismissible: true, // 点击空白处关闭
      builder: (context) => AlertDialog(
        title: Center(child: Text(zhuotai.title)), // 标题居中
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: _borderRadius12),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 点餐
            _buildDialogButton(
              text: '点餐',
              color: Colors.red,
              onTap: () {
                Navigator.pop(context);
                _navigateToDianCanPage(zhuotai);
              },
            ),
            const SizedBox(height: 8),
            // 取消预定
            _buildDialogButton(
              text: '取消预定',
              color: Colors.orange,
              onTap: () async {
                Navigator.pop(context);
                await _updateZhuotaiStatus(zhuotai, '0');
              },
            ),
            const SizedBox(height: 8),
            // 清台
            _buildDialogButton(
              text: '清台',
              color: Colors.grey,
              onTap: () async {
                Navigator.pop(context);
                await _updateZhuotaiStatus(zhuotai, '0');
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 就餐中桌台操作弹窗（中餐适配：点餐/加菜/退菜/结账/取消订单）
  Future<void> _showDiningOperationDialog(ZhuotaiModel zhuotai) async {
    showDialog(
      context: context,
      barrierDismissible: true, // 点击空白处关闭
      builder: (context) => AlertDialog(
        title: Center(child: Text(zhuotai.title)), // 标题居中
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: _borderRadius12),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 点餐
            _buildDialogButton(
              text: '点餐',
              color: Colors.red,
              onTap: () {
                Navigator.pop(context);
                _navigateToDianCanPage(zhuotai);
              },
            ),
            const SizedBox(height: 8),
            // 加菜
            _buildDialogButton(
              text: '加菜',
              color: Colors.blue,
              onTap: () {
                Navigator.pop(context);
                _navigateToDianCanPage(zhuotai);
              },
            ),
            const SizedBox(height: 8),
            // 退菜
            _buildDialogButton(
              text: '退菜',
              color: Colors.orange,
              onTap: () {
                Navigator.pop(context);
                // 可添加退菜逻辑
                _showTopToast('退菜功能待开发', backgroundColor: Colors.orange);
              },
            ),
            const SizedBox(height: 8),
            // 结账
            _buildDialogButton(
              text: '结账',
              color: Colors.purple,
              onTap: () {
                Navigator.pop(context);
                // 可添加结账逻辑
                _showTopToast('结账功能待开发', backgroundColor: Colors.purple);
              },
            ),
            const SizedBox(height: 8),
            // 取消订单
            _buildDialogButton(
              text: '取消订单',
              color: Colors.red.shade700,
              onTap: () {
                Navigator.pop(context);
                _showCancelOrderDialog(zhuotai);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 扫码点餐桌台操作弹窗（同就餐中：中餐适配）
  Future<void> _showScanOrderOperationDialog(ZhuotaiModel zhuotai) async {
    showDialog(
      context: context,
      barrierDismissible: true, // 点击空白处关闭
      builder: (context) => AlertDialog(
        title: Center(child: Text(zhuotai.title)), // 标题居中
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: _borderRadius12),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 点餐
            _buildDialogButton(
              text: '点餐',
              color: Colors.red,
              onTap: () {
                Navigator.pop(context);
                _navigateToDianCanPage(zhuotai);
              },
            ),
            const SizedBox(height: 8),
            // 加菜
            _buildDialogButton(
              text: '加菜',
              color: Colors.blue,
              onTap: () {
                Navigator.pop(context);
                _navigateToDianCanPage(zhuotai);
              },
            ),
            const SizedBox(height: 8),
            // 退菜
            _buildDialogButton(
              text: '退菜',
              color: Colors.orange,
              onTap: () {
                Navigator.pop(context);
                // 可添加退菜逻辑
                _showTopToast('退菜功能待开发', backgroundColor: Colors.orange);
              },
            ),
            const SizedBox(height: 8),
            // 结账
            _buildDialogButton(
              text: '结账',
              color: Colors.purple,
              onTap: () {
                Navigator.pop(context);
                // 可添加结账逻辑
                _showTopToast('结账功能待开发', backgroundColor: Colors.purple);
              },
            ),
            const SizedBox(height: 8),
            // 取消订单
            _buildDialogButton(
              text: '取消订单',
              color: Colors.red.shade700,
              onTap: () {
                Navigator.pop(context);
                _showCancelOrderDialog(zhuotai);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 弹窗按钮通用样式（统一风格）
  Widget _buildDialogButton({
    required String text,
    required Color color,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 16,
            color: Colors.white,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  /// 显示取消订单确认弹窗（简化：移除取消按钮，点击空白处关闭）
  void _showCancelOrderDialog(ZhuotaiModel zhuotai) {
    showDialog(
      context: context,
      barrierDismissible: true, // 点击空白处关闭
      builder: (context) => AlertDialog(
        title: Center(child: Text('取消${zhuotai.title}桌订单')), // 标题居中
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        content: Text('确认取消${zhuotai.title}桌的订单并将桌台恢复为空闲状态？'),
        actions: [
          // 仅保留确认按钮
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () async {
                Navigator.pop(context);
                await _cancelOrder(zhuotai);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text(
                '确认取消',
                style: TextStyle(fontSize: 16, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 取消订单（桌台恢复空闲）核心方法
  Future<bool> _cancelOrder(ZhuotaiModel zhuotai) async {
    if (_currentWenxunId == null) {
      _showTopToast('未获取到商户信息，无法取消订单', backgroundColor: Colors.red);
      return false;
    }

    setState(() => _isLoading = true);
    try {
      final response = await http.post(
        Uri.parse(_cancelOrderUrl),
        headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'wenxun_id': _currentWenxunId.toString(),
          'zhuotai_id': zhuotai.id.toString(),
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['code'] == 200) {
          _showTopToast('${zhuotai.title}桌订单取消成功！');
          // 刷新桌台列表
          _fetchZhuotaiList();
          return true;
        } else {
          _showTopToast(data['msg'] ?? '取消订单失败', backgroundColor: Colors.red);
          return false;
        }
      } else {
        _showTopToast('请求失败：状态码${response.statusCode}', backgroundColor: Colors.red);
        return false;
      }
    } on TimeoutException {
      _showTopToast('取消订单请求超时，请重试', backgroundColor: Colors.red);
      return false;
    } catch (e) {
      _showTopToast('取消订单失败：${e.toString()}', backgroundColor: Colors.red);
      return false;
    } finally {
      setState(() => _isLoading = false);
    }
  }

  /// 更新桌台状态（预定→空闲/空闲→预定/清台）
  Future<void> _updateZhuotaiStatus(ZhuotaiModel zhuotai, String newStatus) async {
    setState(() => _isLoading = true);
    try {
      final response = await http.post(
        Uri.parse(_updateStatusUrl),
        headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'wenxun_id': _currentWenxunId.toString(),
          'zhuotai_id': zhuotai.id.toString(),
          'status': newStatus,
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['code'] == 200) {
          String statusText = '';
          if (newStatus == '0') {
            statusText = '空闲/清台';
          } else if (newStatus == '1') {
            statusText = '已预定';
          }
          _showTopToast('${zhuotai.title}桌已改为$statusText状态！');
          _fetchZhuotaiList(); // 刷新列表
        } else {
          _showTopToast(data['msg'] ?? '状态更新失败', backgroundColor: Colors.red);
        }
      } else {
        _showTopToast('请求失败：${response.statusCode}', backgroundColor: Colors.red);
      }
    } on TimeoutException {
      _showTopToast('请求超时，请重试', backgroundColor: Colors.red);
    } catch (e) {
      _showTopToast('操作失败：${e.toString()}', backgroundColor: Colors.red);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  /// 跳转到点餐页面
  void _navigateToDianCanPage(ZhuotaiModel zhuotai) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => DianCanPage(
          zhuotaiId: zhuotai.id,
          zhuotaiTitle: zhuotai.title,
          peopleCount: int.tryParse(zhuotai.renshu) ?? 0,
          wenxunId: _currentWenxunId!,
        ),
      ),
    );
  }

  /// 显示开台弹窗（空闲点餐时调用）
  Future<void> _showKaitaiDialog(ZhuotaiModel zhuotai) async {
    final TextEditingController _peopleController = TextEditingController(
      text: zhuotai.renshu.isNotEmpty ? zhuotai.renshu : '1',
    );

    showDialog(
      context: context,
      barrierDismissible: true, // 点击空白处关闭
      builder: (context) => AlertDialog(
        title: Center(child: Text('${zhuotai.title} 开台点餐')), // 标题居中
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: _borderRadius12),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('该桌可容纳：${zhuotai.renshu.isNotEmpty ? zhuotai.renshu + '人' : '不限人数'}'),
            const SizedBox(height: 12),
            TextField(
              controller: _peopleController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: '实际就餐人数',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              onChanged: (value) {
                if (value.isEmpty) return;
                final numeric = int.tryParse(value);
                if (numeric == null || numeric < 1) {
                  _peopleController.text = '1';
                  _peopleController.selection = const TextSelection.collapsed(offset: 1);
                }
              },
            ),
          ],
        ),
        actions: [
          // 仅保留确认开台按钮
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () async {
                final peopleCount = int.tryParse(_peopleController.text) ?? 1;
                Navigator.pop(context);
                final success = await _submitKaitai(zhuotai, peopleCount);
                if (success) {
                  _navigateToDianCanPage(zhuotai);
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text(
                '确认开台',
                style: TextStyle(fontSize: 16, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 提交开台请求
  Future<bool> _submitKaitai(ZhuotaiModel zhuotai, int peopleCount) async {
    setState(() => _isLoading = true);
    try {
      final response = await http.post(
        Uri.parse(_kaitaiApiUrl),
        headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'wenxun_id': _currentWenxunId.toString(),
          'zhuotai_id': zhuotai.id.toString(),
          'people_count': peopleCount.toString(),
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['code'] == 200) {
          _showTopToast('${zhuotai.title}桌开台成功！');
          _fetchZhuotaiList();
          return true;
        } else {
          _showTopToast(data['msg'] ?? '开台失败', backgroundColor: Colors.red);
          return false;
        }
      } else {
        _showTopToast('请求失败：${response.statusCode}', backgroundColor: Colors.red);
        return false;
      }
    } on TimeoutException {
      _showTopToast('开台请求超时', backgroundColor: Colors.red);
      return false;
    } catch (e) {
      _showTopToast('开台失败：${e.toString()}', backgroundColor: Colors.red);
      return false;
    } finally {
      setState(() => _isLoading = false);
    }
  }

  /// 获取状态文字描述
  String _getStatusText(String status) {
    switch (status) {
      case '1':
        return '已预定';
      case '2':
        return '就餐中';
      case '3':
        return '扫码点餐';
      default:
        return '空闲';
    }
  }

  /// 构建区域按钮
  Widget _buildQuyuButton(String quyu) {
    final isSelected = _selectedQuyu == quyu;

    return TextButton(
      onPressed: () => _switchQuyu(quyu),
      style: TextButton.styleFrom(
        padding: EdgeInsets.zero,
        minimumSize: const Size(0, 0),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: isSelected ? Colors.red.shade50 : Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: Container(
        height: double.infinity * 0.8,
        alignment: Alignment.center,
        child: Text(
          quyu,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: isSelected ? _selectedTextColor : _unselectedTextColor,
            overflow: TextOverflow.ellipsis,
          ),
          maxLines: 1,
        ),
      ),
    );
  }

  /// 构建桌台卡片（修复Column底部溢出问题）
  Widget _buildZhuotaiCard(ZhuotaiModel zhuotai) {
    return GestureDetector(
      onTap: () => _handleZhuotaiTap(zhuotai),
      child: Container(
        decoration: BoxDecoration(
          color: zhuotai.cardBgColor,
          borderRadius: _borderRadius12,
          border: Border.all(color: zhuotai.cardBorderColor),
          boxShadow: [
            BoxShadow(
              color: _cardShadowColor,
              blurRadius: 8,
              spreadRadius: 1,
              offset: const Offset(0, 3),
            )
          ],
        ),
        // 微调垂直内边距，减少溢出风险
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        // 核心修复：添加ClipRect裁剪溢出部分
        child: ClipRect(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center, // 改为center减少间距导致的溢出
            children: [
              Text(
                zhuotai.title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: zhuotai.cardTextColor,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 1), // 缩小间距
              Text(
                _getStatusText(zhuotai.status),
                style: TextStyle(
                  fontSize: zhuotai.status == '0' ? 14 : 13, // 微调字体大小
                  fontWeight: FontWeight.w600,
                  color: zhuotai.statusTextColor,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 1), // 缩小间距
              Text(
                '${zhuotai.renshu.isNotEmpty && zhuotai.renshu != '0' ? zhuotai.renshu : '0'}人',
                style: TextStyle(
                  fontSize: 11, // 微调字体大小
                  color: zhuotai.cardTextColor,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectedZhuotai = _getSelectedZhuotai();
    final screenHeight = MediaQuery.of(context).size.height;
    final availableHeight = screenHeight - 40;
    final screenWidth = MediaQuery.of(context).size.width;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: Padding(
        padding: const EdgeInsets.all(10.0),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: const BorderRadius.all(Radius.circular(20)),
            boxShadow: [
              BoxShadow(
                color: Colors.grey.withOpacity(0.15),
                blurRadius: 12,
                spreadRadius: 0,
                offset: const Offset(0, 4),
              )
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.max,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: 50,
                ),
                child: SizedBox(
                  height: availableHeight * 0.1,
                  child: ClipRRect(
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(20),
                      topRight: Radius.circular(20),
                    ),
                    child: Container(
                      color: _unselectedBgColor,
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      child: _isLoading
                          ? const Center(
                        child: CircularProgressIndicator(
                          color: Colors.red,
                          strokeWidth: 2,
                        ),
                      )
                          : _errorMessage != null
                          ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Text(
                            _errorMessage!,
                            style: const TextStyle(color: Colors.red, fontSize: 14),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                          : SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: _quyuList.map((quyu) {
                            final buttonWidth = screenWidth / _quyuList.length.clamp(2, 6);
                            return SizedBox(
                              width: buttonWidth,
                              child: _buildQuyuButton(quyu),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: const BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: Color(0xFFEEEEEE),
                        width: 0.8,
                      ),
                    ),
                  ),
                  child: _isLoading
                      ? const Center(
                    child: CircularProgressIndicator(
                      color: Colors.red,
                      strokeWidth: 2,
                    ),
                  )
                      : _errorMessage != null
                      ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(color: Colors.red, fontSize: 16),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                      : selectedZhuotai.isEmpty
                      ? Center(
                    child: Text(
                      '暂无桌台数据',
                      style: TextStyle(
                        fontSize: 17,
                        color: _grey500,
                      ),
                    ),
                  )
                      : Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 15),
                    child: GridView.builder(
                      shrinkWrap: true,
                      physics: const AlwaysScrollableScrollPhysics(),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: screenWidth > 600 ? 8 : 4,
                        childAspectRatio: screenWidth > 600 ? 1.1 : 1.2,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                      ),
                      itemCount: selectedZhuotai.length,
                      itemBuilder: (context, index) {
                        final zhuotai = selectedZhuotai[index];
                        return _buildZhuotaiCard(zhuotai);
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}