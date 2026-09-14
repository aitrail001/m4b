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
    --generate-notes
fi

echo "Release: $(gh release view "$TAG" --json url --jq .url)"
