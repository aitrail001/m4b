#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")"
DMG="$ROOT/dist/AudiobookBinder-${VERSION}.dmg"
TAG="v${VERSION}"

if [[ ! -f "$DMG" ]]; then
  echo "Missing $DMG. Run: make dmg" >&2
  exit 1
fi

cd "$ROOT"
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "Release $TAG already exists; uploading DMG."
  gh release upload "$TAG" "$DMG" --clobber
else
  gh release create "$TAG" "$DMG" \
    --title "Audiobook Binder ${VERSION}" \
    --notes "$(cat <<EOF
## Audiobook Binder ${VERSION}

macOS 14+ app that turns a folder of chapter MP3s into an Apple Books \`.m4b\`.

### Install
1. Download **AudiobookBinder-${VERSION}.dmg**
2. Open the disk image and drag **Audiobook Binder** into Applications
3. Open it from Applications. If macOS says the app is from an unidentified developer, right-click the app and choose **Open**.

### In this version
- Nested library folder tree
- Live scan progress
- Chapter preview, skip chapters, already-bound \`.m4b\` folders
- Save to Music/Audiobooks or next to the book
EOF
)"
fi

echo "Release: $(gh release view "$TAG" --json url --jq .url)"
