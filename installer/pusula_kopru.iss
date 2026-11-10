; Pusula Köprü — Windows kurulum programı (Inno Setup 6). CI: ISCC /DAppVersion=0.1.0 installer\pusula_kopru.iss
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#define AppExe "pusula_kopru.exe"

[Setup]
; Windows dili Türkçe değilse kurulum İngilizce
ShowLanguageDialog=auto
LanguageDetectionMethod=uilanguage
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
CloseApplications=force
RestartApplications=no

[Languages]
Name: "turkish"; MessagesFile: "compiler:Languages\Turkish.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; 0.1'deki başlangıç kısayolu: artık uygulama kendisi ayarlıyor (Ayarlar → Windows açılınca başlat)
Type: files; Name: "{userstartup}\Pusula Köprü.lnk"

[Icons]
Name: "{autoprograms}\Pusula Köprü"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\Pusula Köprü"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Registry]
; Uygulama "Windows açılınca başlat" için bu değeri kendisi yazar; kaldırınca silinsin
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "PusulaKopru"; Flags: uninsdeletevalue dontcreatekey

[UninstallRun]
Filename: "{cmd}"; Parameters: "/c taskkill /im pusula_kopru.exe /f"; Flags: runhidden; RunOnceId: "KopruKapat"

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,Pusula Köprü}"; Flags: nowait postinstall skipifsilent
Filename: "{app}\{#AppExe}"; Flags: nowait; Check: WizardSilent
