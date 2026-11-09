#!/usr/bin/env bash
# ============================================================================
#  DeployHub — installer macOS (.dmg)
#  Inno Setup hanya untuk Windows; di Mac installer-nya berupa file .dmg
#  (buka -> seret DeployHub ke folder Applications).
#
#  Jalankan dari folder project di MacBook:
#     bash installer/macos/build_dmg.sh
#
#  Opsional (supaya tidak muncul peringatan "developer tidak dikenal"):
#     export SIGN_ID="Developer ID Application: Nama Kamu (TEAMID)"
#     export NOTARY_PROFILE="deployhub-notary"   # dibuat sekali dengan:
#       xcrun notarytool store-credentials deployhub-notary --apple-id EMAIL --team-id TEAMID
# ============================================================================
set -euo pipefail
APP_NAME="${APP_NAME:-DeployHub}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# PATH untuk Flutter / Homebrew kalau dijalankan dari Finder / non-login shell
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/development/flutter/bin:$HOME/flutter/bin:$PATH"

VERSION="$(grep -E '^version:' pubspec.yaml | head -1 | sed -E 's/version:[[:space:]]*([0-9.]+).*/\1/')"
echo "==> versi: $VERSION"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  echo "==> flutter build macos --release"
  flutter build macos --release
fi

APP="$(ls -d build/macos/Build/Products/Release/*.app | head -1)"
[[ -d "$APP" ]] || { echo "✖ .app tidak ditemukan"; exit 1; }
echo "==> app: $APP"

# Nama .app di Applications = APP_NAME
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

if [[ -n "${SIGN_ID:-}" ]]; then
  echo "==> codesign"
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_ID" "$STAGE/$APP_NAME.app"
fi

mkdir -p installer/output
DMG="installer/output/$APP_NAME-$VERSION.dmg"
rm -f "$DMG"

if command -v create-dmg >/dev/null 2>&1; then
  # Tampilan rapi (brew install create-dmg)
  rm "$STAGE/Applications"
  create-dmg --volname "$APP_NAME $VERSION" --window-size 560 340 --icon-size 110 \
    --icon "$APP_NAME.app" 140 160 --app-drop-link 420 160 --no-internet-enable \
    "$DMG" "$STAGE/"
else
  hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
fi
rm -rf "$STAGE"

if [[ -n "${SIGN_ID:-}" ]]; then
  codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> notarize (beberapa menit)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi

echo ""
echo "✔ Selesai: $ROOT/$DMG"
echo "  Belum ditandatangani? Di Mac lain: klik kanan DeployHub.app -> Open (sekali saja)."
