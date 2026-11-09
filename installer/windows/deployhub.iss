; ============================================================================
;  DeployHub — installer Windows (Inno Setup 6)
;
;  Cara pakai (paling gampang): jalankan  installer\windows\build_installer.ps1
;  Script itu build Flutter release, menyalin DLL Visual C++, lalu memanggil ISCC
;  dengan versi & nama .exe yang benar.
;
;  Manual: flutter build windows --release, lalu buka file ini di Inno Setup
;  Compiler dan tekan F9 (Compile). Hasil: installer\output\DeployHub-Setup-<versi>.exe
; ============================================================================

#ifndef AppName
  #define AppName "DeployHub"
#endif
#ifndef AppVersion
  #define AppVersion "1.10.0"
#endif
#ifndef AppExeName
  ; nama .exe hasil flutter build (lihat build\windows\x64\runner\Release\)
  #define AppExeName "cicd.exe"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif
#define AppPublisher "Prakash"
#define AppURL "https://github.com/"

[Setup]
; AppId JANGAN diganti setelah rilis pertama — dipakai Windows untuk mengenali update/uninstall
AppId={{6E3B1F4A-8C2D-4D7E-9A51-3F0C2B7D9E11}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; Install tanpa admin (ke %LOCALAPPDATA%\Programs) — bisa pilih "semua pengguna" kalau mau
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\output
OutputBaseFilename={#AppName}-Setup-{#AppVersion}
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
UninstallDisplayName={#AppName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
; Tutup DeployHub yang sedang jalan (juga yang sembunyi di tray) sebelum update
CloseApplications=force
RestartApplications=no
MinVersion=10.0

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Buat shortcut di Desktop / Create a desktop shortcut"; GroupDescription: "Shortcut:"
Name: "autostart"; Description: "Jalankan {#AppName} saat Windows mulai (di system tray) / Start with Windows"; GroupDescription: "Opsi:"; Flags: unchecked

[Files]
; Seluruh isi folder Release: .exe, flutter_windows.dll, plugin *.dll, folder data\
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "{#AppName}"; \
  ValueData: """{app}\{#AppExeName}"""; Flags: uninsdeletevalue; Tasks: autostart

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Jalankan {#AppName} sekarang / Launch {#AppName}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Tutup aplikasi (termasuk yang di tray) sebelum file dihapus
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM {#AppExeName}"; Flags: runhidden; RunOnceId: "KillApp"

; Data pengguna (proyek, riwayat, log, pengaturan) di %APPDATA% sengaja TIDAK dihapus
; supaya install ulang / update tidak kehilangan pengaturan.
