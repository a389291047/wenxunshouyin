import 'dart:convert';

// 商品分类模型（无修改）
class GoodsCat {
  final int id;
  final String name; // 分类名称（对应数据库 title 字段）
  final int wenxunId; // 商户ID
  final String createTime;
  final String updateTime;
  final String ip;
  final String upIp;

  GoodsCat({
    required this.id,
    required this.name,
    required this.wenxunId,
    required this.createTime,
    required this.updateTime,
    required this.ip,
    required this.upIp,
  });

  factory GoodsCat.fromJson(Map<String, dynamic> json) {
    return GoodsCat(
      id: json['id'] ?? 0,
      name: json['title'] ?? '未知分类',
      wenxunId: json['wenxun_id'] ?? 0,
      createTime: json['create_time'] ?? '',
      updateTime: json['update_time'] ?? '',
      ip: json['ip'] ?? '',
      upIp: json['up_ip'] ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'wenxun_id': wenxunId,
      'create_time': createTime,
      'update_time': updateTime,
      'ip': ip,
      'up_ip': upIp,
    };
  }
}

// 商品模型（修正：简拼字段与商品条码(code)逻辑完全一致，后台已处理非空和数据格式）
class Goods {
  final int id;
  final String name;
  final String title;
  final double amount;
  final String goodsImage;
  final String code; // 商品条码（后台非空）
  final int catId; // 商品所属分类ID（兼容字符串转数字）
  final String guige;
  final String? stock;
  final int status;
  final int wenxunId; // 商户ID
  final String jianpin; // 商品简拼（后台自动生成，非空，与code处理逻辑一致）

  Goods({
    required this.id,
    required this.name,
    required this.title,
    required this.amount,
    required this.goodsImage,
    required this.code,
    required this.catId,
    required this.guige,
    this.stock,
    required this.status,
    required this.wenxunId,
    required this.jianpin, // 改为必填，与code一致（后台已保证数据存在）
  });

  factory Goods.fromJson(Map<String, dynamic> json) {
    // 金额转换：兼容字符串/数字类型
    double amount = 0.0;
    if (json['amount'] != null) {
      amount = json['amount'] is String
          ? double.tryParse(json['amount']) ?? 0.0
          : json['amount'].toDouble();
    }

    // cat_id兼容字符串（例如"65"转65）
    int catId = 0;
    if (json['cat_id'] != null) {
      if (json['cat_id'] is String) {
        catId = int.tryParse(json['cat_id']) ?? 0;
      } else {
        catId = json['cat_id'] as int;
      }
    }

    // 商户ID兼容字符串
    int wenxunId = 0;
    if (json['wenxun_id'] != null) {
      if (json['wenxun_id'] is String) {
        wenxunId = int.tryParse(json['wenxun_id']) ?? 0;
      } else {
        wenxunId = json['wenxun_id'] as int;
      }
    }

    return Goods(
      id: json['id'] ?? 0,
      name: json['name'] ?? json['title'] ?? '未知商品',
      title: json['title'] ?? json['name'] ?? '未知商品',
      amount: amount,
      goodsImage: json['goods_image'] ?? '',
      code: json['code'] ?? '', // 商品条码处理逻辑
      catId: catId,
      guige: json['guige'] ?? '无规格',
      stock: json['stock'],
      status: json['status'] ?? 1,
      wenxunId: wenxunId,
      jianpin: json['jianpin']?.toString() ?? '', // 简拼处理逻辑（与code完全一致，后台已保证非空）
    );
  }

  // 可选：添加toJson方法（若需要将商品数据转为JSON时使用）
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'title': title,
      'amount': amount,
      'goods_image': goodsImage,
      'code': code,
      'cat_id': catId,
      'guige': guige,
      'stock': stock,
      'status': status,
      'wenxun_id': wenxunId,
      'jianpin': jianpin, // 简拼字段
    };
  }
}

// 购物车商品模型（无修改）
class CartItem {
  final Goods goods;
  int quantity;

  CartItem({
    required this.goods,
    this.quantity = 1,
  });

  // 商品小计
  double get totalPrice => goods.amount * quantity;

  // 可选：添加toJson方法（若需要将购物车数据转为JSON时使用）
  Map<String, dynamic> toJson() {
    return {
      'goods': goods.toJson(),
      'quantity': quantity,
      'total_price': totalPrice,
    };
  }
}