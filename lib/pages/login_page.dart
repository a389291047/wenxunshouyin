import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import '../models/login_model.dart';
import 'home_page.dart';
import 'register_page.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _showPassword = false;
  bool _isLoading = false;
  String? _errorMessage;

  // 输入框焦点管理+当前激活的控制器
  late FocusNode _phoneFocusNode;
  late FocusNode _passwordFocusNode;
  TextEditingController? _currentController;

  @override
  void initState() {
    super.initState();
    // 初始化焦点节点
    _phoneFocusNode = FocusNode()..addListener(() {
      if (_phoneFocusNode.hasFocus) {
        setState(() => _currentController = _phoneController);
      }
    });
    _passwordFocusNode = FocusNode()..addListener(() {
      if (_passwordFocusNode.hasFocus) {
        setState(() => _currentController = _passwordController);
      }
    });
    // 加载记住的账号
    _loadRememberedPhone();

    // 新增：页面加载完成后默认聚焦手机号输入框
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FocusScope.of(context).requestFocus(_phoneFocusNode);
    });
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _passwordController.dispose();
    _phoneFocusNode.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  // 读取记住的账号
  Future<void> _loadRememberedPhone() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String? rememberedPhone = prefs.getString('remembered_login_phone');
    if (rememberedPhone != null) {
      _phoneController.text = rememberedPhone;
    }
  }

  // 登录核心方法
  Future<void> _performLogin() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    if (!_formKey.currentState!.validate()) {
      setState(() => _isLoading = false);
      return;
    }

    try {
      final url = Uri.parse("https://shop.wx-zf.com/mac/login");
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Accept': 'application/json',
        },
        body: {
          'phone': _phoneController.text.trim(),
          'password': _passwordController.text.trim(),
        },
      ).timeout(const Duration(seconds: 10));

      final loginResponse = LoginResponse.fromJson(jsonDecode(response.body));
      if (loginResponse.code == 200 && loginResponse.data != null) {
        await UserInfoManager().saveUserData(loginResponse.data!);
        // 保存记住的账号
        SharedPreferences prefs = await SharedPreferences.getInstance();
        await prefs.setString('remembered_login_phone', _phoneController.text.trim());

        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => const HomePage()),
          );
        }
      } else {
        setState(() => _errorMessage = loginResponse.msg);
      }
    } on TimeoutException {
      setState(() => _errorMessage = '请求超时，请稍后重试！');
    } catch (e) {
      setState(() => _errorMessage = '登录失败：${e.toString()}');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // 客服弹窗
  void _showKefuImage(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black54,
      builder: (BuildContext context) {
        return GestureDetector(
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
                    'assets/kefu.png',
                    fit: BoxFit.contain,
                    width: MediaQuery.of(context).size.width * 0.7,
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

  // 响应式工具（input框缩小适配小屏）
  double _getFormWidth(double screenWidth) {
    if (screenWidth >= 1200) return 600;
    else if (screenWidth >= 768) return screenWidth * 0.8;
    else return screenWidth * 0.95;
  }

  double _getTitleFontSize(double screenWidth) {
    if (screenWidth >= 1200) return 32;
    else if (screenWidth >= 768) return 28;
    else return 24;
  }

  // 修正：input框缩小（适配小屏触摸）
  double _getInputHeight(double screenWidth) {
    if (screenWidth >= 1200) return 90;    // 缩小适配小屏
    else if (screenWidth >= 768) return 85; // 缩小
    else return 80;                        // 缩小
  }

  // 手机号输入限制
  void _onPhoneChanged(String value) {
    final numericValue = value.replaceAll(RegExp(r'[^0-9]'), '');
    final limitedValue = numericValue.substring(0, numericValue.length > 11 ? 11 : numericValue.length);
    if (_phoneController.text != limitedValue) {
      _phoneController.text = limitedValue;
      _phoneController.selection = TextSelection.fromPosition(
        TextPosition(offset: limitedValue.length),
      );
    }
  }

  // 数字键盘按键事件
  void _onKeyPressed(String key) {
    if (_currentController == null) return;

    switch (key) {
      case '下班':
        SystemNavigator.pop();
        break;
      case '×':
        if (_currentController!.text.isNotEmpty) {
          _currentController!.text = _currentController!.text.substring(0, _currentController!.text.length - 1);
          _currentController!.selection = TextSelection.fromPosition(
            TextPosition(offset: _currentController!.text.length),
          );
          if (_currentController == _phoneController) _onPhoneChanged(_currentController!.text);
        }
        break;
      default:
        String newText = _currentController!.text + key;
        if (_currentController == _phoneController && newText.length > 11) return;

        _currentController!.text = newText;
        if (_currentController == _phoneController) _onPhoneChanged(newText);

        _currentController!.selection = TextSelection.fromPosition(
          TextPosition(offset: _currentController!.text.length),
        );
        break;
    }
  }

  // 美化数字键盘（适配小屏+往左靠）
  Widget _buildNumberKeyboard() {
    final screenSize = MediaQuery.of(context).size;
    final screenWidth = screenSize.width;
    final screenHeight = screenSize.height;

    final keys = [
      '1', '2', '3',
      '4', '5', '6',
      '7', '8', '9',
      '0', '下班', '×'
    ];

    return Container(
      // 减少间距让右侧往左靠
      padding: EdgeInsets.symmetric(
        horizontal: screenWidth * 0.01,
        vertical: screenHeight * 0.04,
      ),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          childAspectRatio: 2,
          mainAxisSpacing: 12, // 紧凑化适配小屏
          crossAxisSpacing: 12,
        ),
        itemCount: keys.length,
        itemBuilder: (context, index) {
          final key = keys[index];
          return InkWell(
            onTap: () => _onKeyPressed(key),
            borderRadius: BorderRadius.circular(12), // 柔和圆角
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.grey.withOpacity(0.15),
                    blurRadius: 6, // 淡阴影适配小屏
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Center(
                child: () {
                  if (key == '×') {
                    return const Icon(Icons.backspace, color: Colors.red, size: 26);
                  } else if (key == '下班') {
                    return const Icon(Icons.power_settings_new, color: Colors.red, size: 26);
                  } else {
                    return Text(
                      key,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    );
                  }
                }(),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final screenWidth = screenSize.width;
    final screenHeight = screenSize.height;

    final formWidth = _getFormWidth(screenWidth);
    final titleFontSize = _getTitleFontSize(screenWidth);
    final inputHeight = _getInputHeight(screenWidth);
    final logoRadius = screenWidth >= 768 ? 12.0 : 10.0;

    // 非空Color
    final bgColor = Color.fromRGBO(255, 255, 255, 0.95);
    final shadowColor = Color.fromRGBO(0, 0, 0, 0.12);
    final bgOverlayColor = Color.fromRGBO(0, 0, 0, 0.1);
    final grey300 = Colors.grey[300]!;
    final grey500 = Colors.grey[500]!;
    final grey600 = Colors.grey[600]!;
    final orange50 = Colors.orange[50]!;
    final orange700 = Colors.orange[700]!;
    final blue50 = Colors.blue[50]!;
    final blue700 = Colors.blue[700]!;
    final grey400 = Colors.grey[400]!;
    final red600 = Colors.red[600]!;
    final red200 = Colors.red[200]!;

    return Scaffold(
      body: Stack(
        children: [
          // 全屏背景
          Positioned.fill(
            child: Image.asset(
              'assets/bj.png',
              fit: BoxFit.cover,
              width: screenWidth,
              height: screenHeight,
              color: bgOverlayColor,
              colorBlendMode: BlendMode.darken,
            ),
          ),

          // 左右分栏布局（紧凑化适配小屏）
          Row(
            children: [
              // 左侧表单（美化+紧凑）
              Expanded(
                flex: 2,
                child: Center(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.symmetric(
                      horizontal: screenWidth * 0.02,
                      vertical: screenHeight * 0.04,
                    ),
                    child: Container(
                      width: formWidth,
                      // 减少内边距适配小屏
                      padding: EdgeInsets.all(screenWidth >= 768 ? 30 : 20),
                      decoration: BoxDecoration(
                        color: bgColor,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: shadowColor,
                            blurRadius: 12,
                            offset: const Offset(0, 6),
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Logo
                            Column(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(logoRadius),
                                  child: Image.asset(
                                    'assets/wenxun.png',
                                    width: screenWidth >= 768 ? 80 : 65,
                                    height: screenWidth >= 768 ? 80 : 65,
                                    fit: BoxFit.contain,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  '零售、餐饮、云打印',
                                  style: TextStyle(
                                    fontSize: screenWidth >= 768 ? 18 : 16,
                                    color: Colors.grey[700],
                                    fontWeight: FontWeight.w500,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ],
                            ),
                            SizedBox(height: screenWidth >= 768 ? 40 : 35),

                            // 手机号输入（缩小+美化）
                            SizedBox(
                              height: inputHeight,
                              child: TextFormField(
                                controller: _phoneController,
                                focusNode: _phoneFocusNode,
                                readOnly: true, // 手机号仍保留只读，用自定义键盘
                                cursorHeight: screenWidth >= 768 ? 28 : 26,
                                cursorWidth: 2.0,
                                cursorColor: Colors.red,
                                decoration: InputDecoration(
                                  labelText: '手机号码',
                                  labelStyle: TextStyle(
                                    fontSize: screenWidth >= 768 ? 20 : 18,
                                    color: grey600,
                                  ),
                                  hintStyle: TextStyle(
                                    fontSize: screenWidth >= 768 ? 18 : 16,
                                    color: Colors.grey[400],
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(15),
                                    borderSide: BorderSide(width: 1.5, color: grey300),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(15),
                                    borderSide: BorderSide(width: 1.5, color: grey300),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(15),
                                    borderSide: const BorderSide(width: 2.0, color: Colors.red),
                                  ),
                                  // 适配缩小的input高度
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 25),
                                  prefixIcon: Icon(
                                      Icons.phone_android,
                                      size: screenWidth >= 768 ? 28 : 26,
                                      color: grey500
                                  ),
                                  fillColor: Colors.white,
                                  filled: true,
                                ),
                                style: TextStyle(
                                    fontSize: screenWidth >= 768 ? 20 : 18,
                                    height: 1.2
                                ),
                                validator: (value) {
                                  if (value == null || value.isEmpty) return '请输入手机号';
                                  if (value.length != 11) return '请输入11位手机号';
                                  return null;
                                },
                                onChanged: _onPhoneChanged,
                              ),
                            ),
                            const SizedBox(height: 20),

                            // 密码输入（缩小+美化）
                            SizedBox(
                              height: inputHeight,
                              child: TextFormField(
                                controller: _passwordController,
                                focusNode: _passwordFocusNode,
                                readOnly: false, // 仅修改这一行：从true改为false，实现密码可手动输入
                                obscureText: !_showPassword,
                                cursorHeight: screenWidth >= 768 ? 28 : 26,
                                cursorWidth: 2.0,
                                cursorColor: Colors.red,
                                decoration: InputDecoration(
                                  labelText: '登录密码',
                                  labelStyle: TextStyle(
                                    fontSize: screenWidth >= 768 ? 20 : 18,
                                    color: grey600,
                                  ),
                                  hintStyle: TextStyle(
                                    fontSize: screenWidth >= 768 ? 18 : 16,
                                    color: Colors.grey[400],
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(15),
                                    borderSide: BorderSide(width: 1.5, color: grey300),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(15),
                                    borderSide: BorderSide(width: 1.5, color: grey300),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(15),
                                    borderSide: const BorderSide(width: 2.0, color: Colors.red),
                                  ),
                                  // 适配缩小的input高度
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 25),
                                  prefixIcon: Icon(
                                      Icons.lock,
                                      size: screenWidth >= 768 ? 28 : 26,
                                      color: grey500
                                  ),
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      _showPassword ? Icons.visibility : Icons.visibility_off,
                                      size: screenWidth >= 768 ? 28 : 26,
                                      color: grey600,
                                    ),
                                    padding: const EdgeInsets.only(right: 15),
                                    onPressed: () => setState(() => _showPassword = !_showPassword),
                                  ),
                                  fillColor: Colors.white,
                                  filled: true,
                                ),
                                style: TextStyle(
                                    fontSize: screenWidth >= 768 ? 20 : 18,
                                    height: 1.2
                                ),
                                validator: (value) {
                                  if (value == null || value.isEmpty) return '请输入密码';
                                  if (value.length < 6) return '密码至少6位';
                                  return null;
                                },
                              ),
                            ),
                            const SizedBox(height: 12),

                            // 错误提示
                            if (_errorMessage != null)
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  _errorMessage!,
                                  style: const TextStyle(color: Colors.red, fontSize: 16, height: 1.2),
                                ),
                              ),
                            const SizedBox(height: 18),

                            // 客服+注册（“立即注册”改为“注册”）
                            SizedBox(
                              width: double.infinity,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  TextButton(
                                    onPressed: () => _showKefuImage(context),
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                      minimumSize: const Size(80, 40),
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      backgroundColor: orange50,
                                    ),
                                    child: Text(
                                      '客服',
                                      style: TextStyle(
                                        color: orange700,
                                        fontSize: screenWidth >= 768 ? 16 : 14,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(builder: (context) => const RegisterPage()),
                                      );
                                    },
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                      minimumSize: const Size(80, 40),
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      backgroundColor: blue50,
                                    ),
                                    child: Text(
                                      '注册', // 改为“注册”
                                      style: TextStyle(
                                        color: blue700,
                                        fontSize: screenWidth >= 768 ? 16 : 14,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(height: screenWidth >= 768 ? 25 : 20),

                            // 登录按钮
                            SizedBox(
                              width: double.infinity,
                              height: screenWidth >= 768 ? 65 : 60,
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _isLoading ? grey400 : red600,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(15),
                                  ),
                                  elevation: 6,
                                  shadowColor: red200,
                                  padding: EdgeInsets.zero,
                                ),
                                onPressed: _isLoading ? null : _performLogin,
                                child: _isLoading
                                    ? const CircularProgressIndicator(color: Colors.white, strokeWidth: 3)
                                    : Text(
                                  '登录',
                                  style: TextStyle(
                                    fontSize: screenWidth >= 768 ? 20 : 18,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // 右侧数字键盘
              Expanded(
                flex: 1,
                child: _buildNumberKeyboard(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}