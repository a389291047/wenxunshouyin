import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import '../models/register_model.dart';
import 'login_page.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _formKey = GlobalKey<FormState>();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _nameController = TextEditingController();
  bool _showPassword = false;
  bool _isLoading = false;
  String? _errorMessage;
  String? _successMessage;

  // 注册核心方法
  Future<void> _performRegister() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _successMessage = null;
    });

    try {
      final url = Uri.parse("https://shop.wx-zf.com/mac/wenxun/reg");
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Accept': 'application/json',
        },
        body: {
          'phone': _phoneController.text.trim(),
          'password': _passwordController.text.trim(),
          'name': _nameController.text.trim(),
          'model': 'mac',
        },
      ).timeout(const Duration(seconds: 15));

      final registerResponse = RegisterResponse.fromJson(jsonDecode(response.body));
      if (registerResponse.code == 200 && registerResponse.data != null) {
        setState(() {
          _successMessage = registerResponse.msg;
          Timer(const Duration(seconds: 3), () {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (context) => const LoginPage()),
            );
          });
        });
      } else {
        setState(() => _errorMessage = registerResponse.msg);
      }
    } on TimeoutException {
      setState(() => _errorMessage = '请求超时，请稍后重试');
    } on http.ClientException {
      setState(() => _errorMessage = '网络异常，请检查连接');
    } catch (e) {
      setState(() => _errorMessage = '注册失败：${e.toString()}');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // 1. 全屏背景图（和登录页一致）
          Positioned.fill(
            child: Image.asset(
              'assets/wenxunlogo.jpeg',
              fit: BoxFit.cover, // 强制全屏铺满，覆盖整个屏幕
              width: MediaQuery.of(context).size.width,
              height: MediaQuery.of(context).size.height,
              color: Colors.black.withOpacity(0.1),
              colorBlendMode: BlendMode.darken,
            ),
          ),
          // 2. 注册表单（居中+全屏适配）
          Center(
            child: Container(
              width: MediaQuery.of(context).size.width > 600 ? 600 : MediaQuery.of(context).size.width * 0.9,
              padding: const EdgeInsets.all(40),
              margin: const EdgeInsets.symmetric(horizontal: 20),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.95),
                borderRadius: BorderRadius.circular(20),
                boxShadow: const [
                  BoxShadow(color: Colors.black12, blurRadius: 10, offset: Offset(0, 5)),
                ],
              ),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min, // 自适应高度
                  children: [
                    // 标题
                    const Text(
                      '商户注册',
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: Colors.red,
                      ),
                    ),
                    const SizedBox(height: 40),

                    // 商户/店铺名称（强制中文）
                    TextFormField(
                      controller: _nameController,
                      decoration: InputDecoration(
                        labelText: '商户/店铺名称',
                        labelStyle: const TextStyle(fontSize: 18),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(width: 2),
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
                        prefixIcon: const Icon(Icons.business, size: 24, color: Colors.grey),
                        fillColor: Colors.white,
                        filled: true,
                      ),
                      style: const TextStyle(fontSize: 18),
                      validator: (value) {
                        if (value == null || value.isEmpty) return '请输入商户/店铺名称';
                        if (value.length < 2) return '名称至少2个字符';
                        if (value.length > 10) return '名称最多10个字符';
                        // 强制中文校验（只允许汉字）
                        if (!RegExp(r'^[\u4e00-\u9fa5]+$').hasMatch(value)) {
                          return '店铺名称必须是汉字';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 20),

                    // 手机号输入
                    TextFormField(
                      controller: _phoneController,
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(
                        labelText: '手机号码（登录账号）',
                        labelStyle: const TextStyle(fontSize: 18),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(width: 2),
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
                        prefixIcon: const Icon(Icons.phone_android, size: 24, color: Colors.grey),
                        fillColor: Colors.white,
                        filled: true,
                      ),
                      style: const TextStyle(fontSize: 18),
                      validator: (value) {
                        if (value == null || value.isEmpty) return '请输入手机号';
                        if (value.length != 11) return '请输入11位手机号';
                        if (!RegExp(r'^1[3-9]\d{9}$').hasMatch(value)) {
                          return '请输入有效的手机号码';
                        }
                        return null;
                      },
                      onChanged: (value) {
                        final numericValue = value.replaceAll(RegExp(r'[^0-9]'), '');
                        final limitedValue = numericValue.substring(0, numericValue.length > 11 ? 11 : numericValue.length);
                        if (_phoneController.text != limitedValue) {
                          _phoneController.text = limitedValue;
                          _phoneController.selection = TextSelection.fromPosition(
                            TextPosition(offset: limitedValue.length),
                          );
                        }
                      },
                    ),
                    const SizedBox(height: 20),

                    // 密码输入
                    TextFormField(
                      controller: _passwordController,
                      obscureText: !_showPassword,
                      decoration: InputDecoration(
                        labelText: '设置密码',
                        labelStyle: const TextStyle(fontSize: 18),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(width: 2),
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
                        prefixIcon: const Icon(Icons.lock, size: 24, color: Colors.grey),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _showPassword ? Icons.visibility : Icons.visibility_off,
                            size: 24,
                            color: Colors.grey[600],
                          ),
                          onPressed: () => setState(() => _showPassword = !_showPassword),
                        ),
                        fillColor: Colors.white,
                        filled: true,
                      ),
                      style: const TextStyle(fontSize: 18),
                      validator: (value) {
                        if (value == null || value.isEmpty) return '请输入密码';
                        if (value.length < 6 || value.length > 20) {
                          return '密码长度必须在6到20位之间';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 20),

                    // 确认密码
                    TextFormField(
                      controller: _confirmPasswordController,
                      obscureText: !_showPassword,
                      decoration: InputDecoration(
                        labelText: '确认密码',
                        labelStyle: const TextStyle(fontSize: 18),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(width: 2),
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
                        prefixIcon: const Icon(Icons.lock_outline, size: 24, color: Colors.grey),
                        fillColor: Colors.white,
                        filled: true,
                      ),
                      style: const TextStyle(fontSize: 18),
                      validator: (value) {
                        if (value == null || value.isEmpty) return '请确认密码';
                        if (value != _passwordController.text) return '两次密码输入不一致';
                        return null;
                      },
                    ),
                    const SizedBox(height: 10),

                    // 错误提示
                    if (_errorMessage != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _errorMessage!,
                          style: const TextStyle(color: Colors.red, fontSize: 16),
                        ),
                      ),

                    // 成功提示
                    if (_successMessage != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _successMessage!,
                          style: const TextStyle(color: Colors.green, fontSize: 16),
                        ),
                      ),
                    const SizedBox(height: 30),

                    // 注册按钮
                    SizedBox(
                      width: double.infinity,
                      height: 60,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          elevation: 5,
                        ),
                        onPressed: _isLoading ? null : _performRegister,
                        child: _isLoading
                            ? const CircularProgressIndicator(color: Colors.white, strokeWidth: 2)
                            : const Text(
                          '提交注册',
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // 已有账号-跳转登录
                    Align(
                      alignment: Alignment.center,
                      child: TextButton(
                        onPressed: () {
                          Navigator.pushReplacement(
                            context,
                            MaterialPageRoute(builder: (context) => const LoginPage()),
                          );
                        },
                        child: const Text(
                          '已有账号？直接去登录',
                          style: TextStyle(color: Colors.blue, fontSize: 16),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _nameController.dispose();
    super.dispose();
  }
}