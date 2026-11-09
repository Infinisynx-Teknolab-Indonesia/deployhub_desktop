# Installer DeployHub

## Windows — Inno Setup 6
1. Pasang Inno Setup 6: https://jrsoftware.org/isdl.php (atau `winget install JRSoftware.InnoSetup`).
2. Dari folder project (mis. `D:\VScode-workspace\cicd`):
   ```
   powershell -ExecutionPolicy Bypass -File installer\windows\build_installer.ps1
   ```
3. Hasil: `installer\output\DeployHub-Setup-<versi>.exe`

Isi installer:
- Install tanpa admin (per pengguna) — bisa pilih "semua pengguna".
- Shortcut Start Menu + Desktop (opsional), "Jalankan saat Windows mulai" (opsional, ke tray).
- DLL Visual C++ ikut dibundel → jalan di PC baru tanpa install runtime.
- Update: jalankan installer versi baru — DeployHub yang terbuka/di tray ditutup otomatis.
- Uninstall tidak menghapus data (proyek, riwayat, pengaturan) di %APPDATA%.

Mau compile manual di Inno Setup Compiler: `flutter build windows --release`, buka
`installer\windows\deployhub.iss`, sesuaikan `AppExeName` (nama .exe di
`build\windows\x64\runner\Release\`), lalu F9.

## macOS — .dmg
Inno Setup hanya untuk Windows. Di MacBook:
```
bash installer/macos/build_dmg.sh
```
Hasil: `installer/output/DeployHub-<versi>.dmg` (buka → seret ke Applications).
Pastikan `macos/Runner/*.entitlements` dari zip sudah disalin (App Sandbox mati).
Tanda tangan + notarisasi (opsional): set `SIGN_ID` dan `NOTARY_PROFILE` — lihat komentar di script.
