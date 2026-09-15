#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/release-gates.sh"

ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="$ROOT/.build/release/AudiobookBinder"
DIST_DIR="$ROOT/dist"
APP="$DIST_DIR/AudiobookBinder.app"
RECEIPT="$(packaged_app_receipt_path "$ROOT")"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
APP_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"

if [[ ! -x "$BIN" ]]; then
  echo "Missing release binary. Run: swift build -c release" >&2
  exit 1
fi

rm -rf "$APP"
rm -f "$RECEIPT"
mkdir -p "$MACOS" "$RESOURCES"
cp "$BIN" "$MACOS/AudiobookBinder"
chmod +x "$MACOS/AudiobookBinder"
cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
fi

/usr/bin/codesign --force --deep --sign - "$APP" >/dev/null
write_packaged_app_receipt "$ROOT" "$APP_COMMIT" "$APP"
echo "Built $APP"
