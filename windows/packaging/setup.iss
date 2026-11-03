#define AppName "稳讯收银"
#define AppPublisher "Chengdu Wenxun Technology Co., Ltd."
#ifndef AppVersion
#define AppVersion "1.0.0"
#endif

[Setup]
AppId={{B4E3A2C1-9D8F-4A6E-8F5B-2C7D1E9A0F33}}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\WenXun
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=..\..\build\installer
OutputBaseFilename=WenXun-{#AppVersion}-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\WenXun.exe
PrivilegesRequiredOverridesAllowed=dialog
; 在线更新支持（v3.3.79）：升级时自动关闭运行中的旧版，避免文件占用导致覆盖失败
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\WenXun.exe"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\WenXun.exe"; Tasks: desktopicon

[Run]
; 不要加 skipifsilent：/VERYSILENT 静默升级时 postinstall 默认执行 → 装完自动启动新版本
Filename: "{app}\WenXun.exe"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall
