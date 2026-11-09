; Pusula Köprü — Windows kurulum programı (Inno Setup 6). CI: ISCC /DAppVersion=0.1.0 installer\pusula_kopru.iss
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#define AppExe "pusula_kopru.exe"

[Setup]
AppId={{8C1F4E2A-6B3D-4A57-9E21-3F5D7C9A0B14}
AppName=Pusula Köprü
AppVersion={#AppVersion}
AppVerName=Pusula Köprü {#AppVersion}
AppPublisher=OA Labs
AppPublisherURL=https://oalabs.dev
AppSupportURL=https://oalabs.dev
DefaultDirName={localappdata}\Programs\Pusula Kopru
DefaultGroupName=Pusula Köprü
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=Pusula-Kopru-Kurulum
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName=Pusula Köprü
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "turkish"; MessagesFile: "compiler:Languages\Turkish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "startup"; Description: "Windows açılınca başlat (telefondan gelenleri kaçırma)"; GroupDescription: "Başlangıç:"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Pusula Köprü"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\Pusula Köprü"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon
Name: "{userstartup}\Pusula Köprü"; Filename: "{app}\{#AppExe}"; Tasks: startup

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,Pusula Köprü}"; Flags: nowait postinstall skipifsilent
Filename: "{app}\{#AppExe}"; Flags: nowait; Check: WizardSilent
