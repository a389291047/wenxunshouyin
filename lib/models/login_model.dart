import 'package:shared_preferences/shared_preferences.dart';

/// 登录响应模型（与后端接口返回格式对齐）
class LoginResponse {
  final int code;
  final String msg;
  final LoginData? data;

  // 构造函数：明确参数含义，添加文档注释
  const LoginResponse({
    required this.code, // 接口状态码（200=成功）
    required this.msg,  // 接口提示信息
    this.data,          // 登录成功后的用户数据（失败时为null）
  });

  /// 从JSON映射到模型实例
  factory LoginResponse.fromJson(Map<String, dynamic> json) {
    return LoginResponse(
      code: json['code'] ?? 0,
      msg: json['msg'] ?? '请求失败',
      // 安全判断：避免json['data']为null时调用fromJson
      data: json['data'] != null ? LoginData.fromJson(json['data']) : null,
    );
  }
}

/// 登录成功返回的用户数据模型（匹配后端返回字段）
class LoginData {
  final String phone;       // 登录手机号
  final String name;        // 商户名称
  final String renyuan;     // 收银员名称
  final String wenxunId;    // 商户唯一标识（wenxun_id）
  final String token;       // 登录令牌（用于后续接口鉴权）
  final String cashierId;   // 收银员ID（核心新增：对应后端返回的id字段）

  // 构造函数：必填字段强制传入，可选字段设置默认值
  const LoginData({
    required this.phone,
    required this.name,
    required this.renyuan,
    required this.wenxunId,
    required this.cashierId, // 收银员ID改为必填
    this.token = '',
  });

  /// 从JSON映射到模型实例（处理后端字段可能为null的情况）
  factory LoginData.fromJson(Map<String, dynamic> json) {
    return LoginData(
      phone: json['phone']?.toString() ?? '', // 确保为字符串类型
      name: json['name']?.toString() ?? '',
      renyuan: json['renyuan']?.toString() ?? '',
      wenxunId: json['wenxun_id']?.toString() ?? '',
      cashierId: json['id']?.toString() ?? '', // 后端返回的id字段映射为收银员ID
      token: json['token']?.toString() ?? '',
    );
  }
}

/// 用户信息管理工具类（本地存储/读取/清除）
/// 功能：统一管理用户登录状态和个人信息，基于SharedPreferences
class UserInfoManager {
  /// 存储用户登录数据到本地
  Future<void> saveUserData(LoginData data) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('phone', data.phone);
    await prefs.setString('name', data.name);
    await prefs.setString('renyuan', data.renyuan);
    await prefs.setString('wenxun_id', data.wenxunId);
    await prefs.setString('token', data.token);
    await prefs.setString('cashier_id', data.cashierId); // 新增：存储收银员ID
  }

  /// 清除本地存储的用户数据（退出登录时调用）
  Future<void> clearUserInfo() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  }

  /// 判断用户是否已登录（基于wenxun_id是否存在）
  Future<bool> isLoggedIn() async {
    final prefs = await SharedPreferences.getInstance();
    final wenxunId = prefs.getString('wenxun_id');
    return wenxunId != null && wenxunId.isNotEmpty;
  }

  /// 获取商户ID（wenxun_id）
  Future<String?> getWenxunId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('wenxun_id');
  }

  /// 获取登录令牌（token）
  Future<String?> getUserToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('token');
  }

  /// 获取商户名称
  Future<String?> getUserName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('name');
  }

  /// 获取登录手机号
  Future<String?> getUserPhone() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('phone');
  }

  /// 获取收银员名称
  Future<String?> getRenyuan() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('renyuan');
  }

  /// 新增：获取收银员ID（核心修正）
  Future<String?> getCashierId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('cashier_id');
  }
}