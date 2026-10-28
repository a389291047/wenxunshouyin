@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

echo ==========================================
echo   稳讯收银 - Windows 打包
echo ==========================================
echo.

where flutter >nul 2>nul
if errorlevel 1 (
  echo [错误] 没有找到 flutter 命令。
  echo 请先安装 Flutter SDK 并加入 PATH，或用 Flutter 自带的 "Developer Command Prompt" 运行本脚本。
  pause
  exit /b 1
)

echo [1/3] 检查 Visual Studio 生成工具（Flutter Windows 必需）...
flutter doctor --verbose | findstr /i "Visual Studio" >nul
if errorlevel 1 (
  echo [提示] 未检测到 Visual Studio。请安装 "Visual Studio 2022 生成工具" 并勾选
  echo        "使用 C++ 的桌面开发" 工作负载后重试。
  pause
  exit /b 1
)

echo [2/3] 拉取依赖...
call flutter pub get
if errorlevel 1 goto :fail

echo [3/3] 编译 Release 版...
call flutter build windows --release
if errorlevel 1 goto :fail

echo.
echo 打包完成，产物目录：
echo   %cd%\build\windows\x64\runner\Release
echo 把该目录整个复制给用户即可运行（含 WenXun.exe）。
start "" "%cd%\build\windows\x64\runner\Release"
pause
exit /b 0

:fail
echo.
echo [失败] 编译未通过，请把上面的错误信息发给我。
pause
exit /b 1
