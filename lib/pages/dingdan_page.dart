import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import '../models/login_model.dart'; // 复用用户信息管理

// 订单模型（移除状态相关字段，简化goods_list解析）
class OrderModel {
  final int id;
  final int wenxunId;
  final int? vipId;
  final String? phone;
  final int? renyuanId;
  final String createTime;
  final String ip;
  final double total;
  final String orderNumber;
  final String? gtOrderNo;
  final String paymentMethod;
  final int? totalCount;
  final List<dynamic>? goodsList; // 统一为List<dynamic>，兼容解析后的商品数据
  final double refundAmount;
  final String? refundTime;

  OrderModel({
    required this.id,
    required this.wenxunId,
    this.vipId,
    this.phone,
    this.renyuanId,
    required this.createTime,
    required this.ip,
    required this.total,
    required this.orderNumber,
    this.gtOrderNo,
    required this.paymentMethod,
    this.totalCount,
    this.goodsList,
    required this.refundAmount,
    this.refundTime,
  });

  // 从JSON解析（移除状态相关字段）
  factory OrderModel.fromJson(Map<String, dynamic> json) {
    // 解析goods_list：兼容JSON字符串、List、null
    dynamic rawGoodsList = json['goods_list'];
    List<dynamic>? parsedGoodsList;

    if (rawGoodsList == null) {
      parsedGoodsList = null;
    } else if (rawGoodsList is String) {
      // 如果是JSON字符串，先解码再判断是否为List
      try {
        final decodedData = jsonDecode(rawGoodsList);
        parsedGoodsList = decodedData is List ? decodedData : null;
      } catch (e) {
        // 解析失败则设为null
        parsedGoodsList = null;
      }
    } else if (rawGoodsList is List) {
      // 已经是List，直接使用
      parsedGoodsList = rawGoodsList;
    } else {
      // 其他类型（如Map），设为null
      parsedGoodsList = null;
    }

    return OrderModel(
      id: json['id'] ?? 0,
      wenxunId: json['wenxun_id'] ?? 0,
      vipId: json['vip_id'],
      phone: json['phone'],
      renyuanId: json['renyuan_id'],
      createTime: json['create_time'] ?? '',
      ip: json['ip'] ?? '',
      total: double.tryParse(json['total'].toString()) ?? 0.0,
      orderNumber: json['order_number'] ?? '',
      gtOrderNo: json['gt_order_no'],
      paymentMethod: json['payment_method'] ?? '其他支付',
      totalCount: json['total_count'],
      goodsList: parsedGoodsList, // 使用解析后的商品列表
      refundAmount: double.tryParse(json['refund_amount'].toString()) ?? 0.0,
      refundTime: json['refund_time'],
    );
  }
}

/// 订单管理页面（移除状态、去支付、下单设备显示）
class DingDanPage extends StatefulWidget {
  const DingDanPage({super.key});

  @override
  State<DingDanPage> createState() => _DingDanPageState();
}

class _DingDanPageState extends State<DingDanPage> {
  final UserInfoManager _userManager = UserInfoManager();
  final String _orderApiUrl = 'https://shop.wx-zf.com/shouyin/order/shujua';
  final String _printOrderApi = 'https://shop.wx-zf.com/api/order/dayin'; // 订单打印接口
  final String _getPrinterApi = 'https://shop.wx-zf.com/api/printer/huoqu'; // 获取当前商户打印机接口
  int? _currentWenxunId; // 当前登录商户ID
  List<OrderModel> _allOrders = []; // 存储所有订单
  List<OrderModel> _filteredOrders = []; // 筛选后的订单
  bool _isLoading = true;
  String? _errorMessage;
  final TextEditingController _searchController = TextEditingController(); // 订单号搜索控制器
  String? _currentPrinterSn; // 当前商户绑定的打印机SN

  @override
  void initState() {
    super.initState();
    _fetchOrderAndPrinterData(); // 同时获取订单和打印机信息
    // 搜索框监听
    _searchController.addListener(() {
      _filterOrders();
    });
  }

  // 同时获取订单和当前商户绑定的打印机SN
  Future<void> _fetchOrderAndPrinterData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // 1. 获取商户ID
      String? wenxunIdStr = await _userManager.getWenxunId();
      if (wenxunIdStr == null || wenxunIdStr.isEmpty) {
        throw Exception('未获取到商户信息，请重新登录');
      }
      _currentWenxunId = int.tryParse(wenxunIdStr);
      if (_currentWenxunId == null) {
        throw Exception('商户ID格式错误，请重新登录');
      }

      // 2. 并行请求：订单列表 + 打印机信息
      final orderFuture = _fetchOrderList();
      final printerFuture = _fetchCurrentPrinterSn();
      await Future.wait([orderFuture, printerFuture]);

      _filterOrders();
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  // 获取订单列表
  Future<void> _fetchOrderList() async {
    final response = await http.post(
      Uri.parse(_orderApiUrl),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {'wenxun_id': _currentWenxunId.toString()},
    ).timeout(const Duration(seconds: 10));

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      if (data['code'] == 200) {
        final List<dynamic> orderJsonList = data['dingdan'] ?? [];
        _allOrders = orderJsonList
            .map((json) => OrderModel.fromJson(json))
            .where((order) => order.wenxunId == _currentWenxunId)
            .toList();
      } else {
        throw Exception(data['msg'] ?? '获取订单列表失败');
      }
    } else {
      throw Exception('请求订单列表失败，状态码：${response.statusCode}');
    }
  }

  // 获取当前商户绑定的打印机SN
  Future<void> _fetchCurrentPrinterSn() async {
    final response = await http.post(
      Uri.parse(_getPrinterApi),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {'wenxun_id': _currentWenxunId.toString()},
    ).timeout(const Duration(seconds: 10));

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      if (data['code'] == 200) {
        setState(() {
          _currentPrinterSn = data['data']['machine_code']; // 从打印机接口获取SN
        });
      } else {
        setState(() {
          _currentPrinterSn = null;
        });
      }
    } else {
      setState(() {
        _currentPrinterSn = null;
      });
    }
  }

  // 本地筛选订单（仅保留订单号搜索）
  void _filterOrders() {
    List<OrderModel> filtered = _allOrders;
    // 仅保留订单号搜索
    final keyword = _searchController.text.trim();
    if (keyword.isNotEmpty) {
      filtered = filtered
          .where((order) => order.orderNumber.contains(keyword))
          .toList();
    }
    setState(() {
      _filteredOrders = filtered;
    });
  }

  // 订单云打印接口请求（优化goods_list的序列化）
  Future<void> _printOrder(OrderModel order) async {
    try {
      // 1. 校验商户ID和打印机SN
      if (_currentWenxunId == null) {
        throw Exception('未获取到商户信息，无法打印');
      }
      if (_currentPrinterSn == null || _currentPrinterSn!.isEmpty) {
        throw Exception('当前商户未绑定云打印机，请先在设置中绑定');
      }

      // 2. 构造订单打印参数（优化goods_list：处理null为空数组）
      final orderData = {
        'wenxun_id': _currentWenxunId.toString(),
        'machine_code': _currentPrinterSn!,
        'order_number': order.orderNumber,
        'total': order.total.toStringAsFixed(2),
        'create_time': order.createTime,
        'payment_method': order.paymentMethod,
        // 核心优化：goods_list为null时序列化为空数组，避免后端解析错误
        'goods_list': json.encode(order.goodsList ?? []),
      };

      // 3. 调用打印接口
      final response = await http.post(
        Uri.parse(_printOrderApi),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: orderData,
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['code'] == 200) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(data['msg'] ?? '打印任务已发送'),
                backgroundColor: Colors.green,
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        } else {
          throw Exception(data['msg'] ?? '打印请求失败');
        }
      } else {
        throw Exception('打印接口请求失败，状态码：${response.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('打印失败：$e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  // 格式化商品列表（简要版，用于订单列表项显示）
  String _formatGoodsListBrief(List<dynamic>? goodsList) {
    if (goodsList == null || goodsList.isEmpty) {
      return '无商品数据';
    }
    List<String> goodsTexts = [];
    for (var item in goodsList) {
      // 兼容不同的商品字段名（name/goods_name，quantity/count）
      String name = item['name'] ?? item['goods_name'] ?? '未知商品';
      int quantity = item['quantity'] ?? item['count'] ?? 1;
      goodsTexts.add('$name × $quantity');
    }
    // 最多显示3个商品，超出则省略
    if (goodsTexts.length > 3) {
      return '${goodsTexts.sublist(0, 3).join('，')}...（共${goodsTexts.length}件商品）';
    }
    return goodsTexts.join('，');
  }

  // 格式化商品列表（详细版，用于订单详情弹窗）
  String _formatGoodsListDetail(List<dynamic>? goodsList) {
    if (goodsList == null || goodsList.isEmpty) {
      return '无商品数据';
    }
    String result = '';
    for (var item in goodsList) {
      // 兼容不同的商品字段名，增强容错
      String name = item['name'] ?? item['goods_name'] ?? '未知商品';
      int quantity = item['quantity'] ?? item['count'] ?? 1;
      double price = double.tryParse((item['price'] ?? item['goods_price'] ?? 0).toString()) ?? 0.0;
      double subtotal = price * quantity; // 商品小计
      result += '• $name × $quantity  单价：¥${price.toStringAsFixed(2)}  小计：¥${subtotal.toStringAsFixed(2)}\n';
    }
    return result;
  }

  // 构建订单列表项（移除状态、去支付、下单设备显示）
  Widget _buildOrderItem(OrderModel order) {
    // 下单时间截取
    String displayTime = order.createTime.length >= 16 ? order.createTime.substring(0, 16) : order.createTime;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [BoxShadow(color: Colors.grey.withOpacity(0.1), blurRadius: 4, offset: const Offset(0, 2))],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 订单头部（仅保留编号）
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '订单编号：${order.orderNumber}',
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // 订单信息（移除下单设备显示）
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '订单金额：¥${order.total.toStringAsFixed(2)}',
                        style: const TextStyle(fontSize: 15, color: Color(0xFF333333)),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '支付方式：${order.paymentMethod}',
                        style: const TextStyle(fontSize: 15, color: Color(0xFF666666)),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '下单时间：$displayTime',
                        style: const TextStyle(fontSize: 15, color: Color(0xFF666666)),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '会员手机号：${order.phone ?? '无'}',
                        style: const TextStyle(fontSize: 15, color: Color(0xFF333333)),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '商品数量：${order.totalCount ?? 0}件',
                        style: const TextStyle(fontSize: 15, color: Color(0xFF666666)),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '退款金额：¥${order.refundAmount.toStringAsFixed(2)}',
                        style: const TextStyle(fontSize: 15, color: Color(0xFF666666)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            // 商品列表简要显示
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '商品列表：',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Color(0xFF333333)),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _formatGoodsListBrief(order.goodsList),
                    style: const TextStyle(fontSize: 13, color: Color(0xFF666666)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // 操作按钮（移除去支付按钮）
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // 云打印按钮
                ElevatedButton(
                  onPressed: () => _printOrder(order),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2196F3),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  ),
                  child: const Text('云打印', style: TextStyle(fontSize: 14)),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () => _showDetailDialog(order),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFF5F5F5),
                    foregroundColor: const Color(0xFF666666),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  ),
                  child: const Text('查看详情', style: TextStyle(fontSize: 14)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // 订单详情弹窗（移除状态、下单设备显示）
  void _showDetailDialog(OrderModel order) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(
          '订单详情',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildDetailRow('订单编号', order.orderNumber),
                _buildDetailRow('订单金额', '¥${order.total.toStringAsFixed(2)}'),
                _buildDetailRow('支付方式', order.paymentMethod),
                _buildDetailRow('退款金额', '¥${order.refundAmount.toStringAsFixed(2)}'),
                _buildDetailRow('会员手机号', order.phone ?? '无'),
                _buildDetailRow('商品数量', '${order.totalCount ?? 0}件'),
                _buildDetailRow('下单时间', order.createTime),
                const SizedBox(height: 10),
                const Text('商品列表（详细）：', style: TextStyle(fontWeight: FontWeight.w600)),
                // 使用详细版商品列表格式化
                Text(_formatGoodsListDetail(order.goodsList)),
              ],
            ),
          ),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF666666),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            ),
            child: const Text('关闭', style: TextStyle(fontSize: 16)),
          ),
        ],
      ),
    );
  }

  // 构建详情行
  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              '$label：',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 15, color: Color(0xFF333333)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左侧功能区（移除状态筛选，仅保留刷新按钮）
          Expanded(
            flex: 1,
            child: Container(
              margin: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(color: Colors.grey.withOpacity(0.1), blurRadius: 6, offset: const Offset(0, 3)),
                ],
              ),
              child: Column(
                children: [
                  const SizedBox(height: 30),
                  // 仅保留刷新按钮
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 15),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2196F3),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 18),
                          elevation: 2,
                        ),
                        onPressed: _fetchOrderAndPrinterData,
                        child: const Text('刷新订单列表', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w500)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 右侧订单列表区
          Expanded(
            flex: 9,
            child: Container(
              margin: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(color: Colors.grey.withOpacity(0.1), blurRadius: 6, offset: const Offset(0, 3)),
                ],
              ),
              child: Column(
                children: [
                  // 搜索框
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: '输入订单号搜索',
                        hintStyle: const TextStyle(color: Color(0xFF999999)),
                        prefixIcon: const Icon(Icons.search, color: Color(0xFF666666)),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: Color(0xFFEEEEEE)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: Color(0xFFFF4444)),
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
                      ),
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                  const Divider(height: 1, color: Color(0xFFEEEEEE)),
                  // 订单列表
                  Expanded(
                    child: _isLoading
                        ? const Center(
                      child: CircularProgressIndicator(
                        color: Color(0xFFFF4444),
                        strokeWidth: 3,
                      ),
                    )
                        : _errorMessage != null
                        ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(
                          _errorMessage!,
                          style: const TextStyle(color: Color(0xFFFF4444), fontSize: 18, height: 1.5),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                        : _filteredOrders.isEmpty
                        ? const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.inbox, size: 80, color: Color(0xFFCCCCCC)),
                          SizedBox(height: 20),
                          Text(
                            '暂无订单数据',
                            style: TextStyle(fontSize: 18, color: Color(0xFF666666)),
                          ),
                        ],
                      ),
                    )
                        : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      itemCount: _filteredOrders.length,
                      itemBuilder: (context, index) => _buildOrderItem(_filteredOrders[index]),
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