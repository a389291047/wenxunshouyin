class RegisterResponse {
  final int code;
  final String msg;
  final RegisterData? data;

  RegisterResponse({
    required this.code,
    required this.msg,
    this.data,
  });

  factory RegisterResponse.fromJson(Map<String, dynamic> json) {
    return RegisterResponse(
      code: json['code'] ?? 0,
      msg: json['msg'] ?? '未知错误',
      data: json['data'] != null ? RegisterData.fromJson(json['data']) : null,
    );
  }
}

class RegisterData {
  final int wenxunId;
  final int renyuanId;
  final String loginPhone;

  RegisterData({
    required this.wenxunId,
    required this.renyuanId,
    required this.loginPhone,
  });

  factory RegisterData.fromJson(Map<String, dynamic> json) {
    return RegisterData(
      wenxunId: json['wenxun_id'] ?? 0,
      renyuanId: json['renyuan_id'] ?? 0,
      loginPhone: json['login_phone'] ?? '',
    );
  }
}