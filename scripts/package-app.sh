#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/release/AudiobookBinder"
DIST_DIR="$ROOT/dist"
APP="$DIST_DIR/AudiobookBinder.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

if [[ ! -x "$BIN" ]]; then
  echo "Missing release binary. Run: swift build -c release" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
cp "$BIN" "$MACOS/AudiobookBinder"
chmod +x "$MACOS/AudiobookBinder"
cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
fi

/usr/bin/codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP"
