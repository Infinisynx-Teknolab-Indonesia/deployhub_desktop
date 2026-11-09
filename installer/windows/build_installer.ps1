# ============================================================================
#  DeployHub — build installer Windows (Inno Setup)
#
#  Jalankan dari folder project:
#     powershell -ExecutionPolicy Bypass -File installer\windows\build_installer.ps1
#
#  Yang dilakukan:
#   1. flutter build windows --release
#   2. salin DLL Visual C++ (msvcp140, vcruntime140, vcruntime140_1) ke folder Release
#      supaya jalan di PC yang belum punya "Visual C++ Redistributable"
#   3. baca versi dari pubspec.yaml & nama .exe dari folder Release
#   4. panggil ISCC.exe (Inno Setup 6) -> installer\output\DeployHub-Setup-<versi>.exe
# ============================================================================
param(
  [string]$AppName = "DeployHub",
  [switch]$SkipBuild
)
$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "..\..")
Set-Location $root

if (-not $SkipBuild) {
  Write-Host "==> flutter build windows --release" -ForegroundColor Cyan
  flutter build windows --release
  if ($LASTEXITCODE -ne 0) { throw "flutter build windows gagal" }
}

$release = Join-Path $root "build\windows\x64\runner\Release"
if (-not (Test-Path $release)) { throw "Folder Release tidak ada: $release" }

# Nama .exe (mis. cicd.exe / deployhub.exe — tergantung nama project Flutter)
$exe = Get-ChildItem $release -Filter *.exe | Select-Object -First 1
if (-not $exe) { throw "Tidak ada .exe di $release" }
Write-Host "==> exe: $($exe.Name)"

# Versi dari pubspec.yaml (1.10.0+25 -> 1.10.0)
$verLine = Select-String -Path (Join-Path $root "pubspec.yaml") -Pattern '^version:\s*([0-9.]+)' | Select-Object -First 1
$version = if ($verLine) { $verLine.Matches[0].Groups[1].Value } else { "1.0.0" }
Write-Host "==> versi: $version"

# DLL Visual C++ runtime (app-local deployment)
foreach ($dll in @("msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll")) {
  $src = Join-Path $env:WINDIR "System32\$dll"
  if (Test-Path $src) {
    Copy-Item $src $release -Force
    Write-Host "    + $dll"
  } else {
    Write-Warning "$dll tidak ditemukan di System32 — pasang Visual C++ Redistributable x64 di PC build"
  }
}

# Cari ISCC.exe
$iscc = @(
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
  "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) {
  $cmd = Get-Command iscc -ErrorAction SilentlyContinue
  if ($cmd) { $iscc = $cmd.Source }
}
if (-not $iscc) {
  throw "Inno Setup 6 belum terpasang. Download: https://jrsoftware.org/isdl.php  (atau: winget install JRSoftware.InnoSetup)"
}

Write-Host "==> ISCC: $iscc" -ForegroundColor Cyan
& $iscc "/DAppName=$AppName" "/DAppVersion=$version" "/DAppExeName=$($exe.Name)" "/DSourceDir=$release" `
  (Join-Path $PSScriptRoot "deployhub.iss")
if ($LASTEXITCODE -ne 0) { throw "ISCC gagal" }

$out = Join-Path $root "installer\output\$AppName-Setup-$version.exe"
Write-Host ""
Write-Host "Selesai: $out" -ForegroundColor Green
