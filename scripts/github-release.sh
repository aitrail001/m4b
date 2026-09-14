#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/release-gates.sh"

ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")"
DMG="$ROOT/dist/AudiobookBinder-${VERSION}.dmg"
TAG="v${VERSION}"
ASSET="${DMG:t}"

if [[ ! -f "$DMG" ]]; then
  echo "Missing $DMG. Run: make production-dmg" >&2
  exit 1
fi

cd "$ROOT"
require_clean_release_worktree "$ROOT"

dump="$(/usr/bin/codesign -dv --verbose=4 "$DMG" 2>&1)" || true
identity="$(production_dmg_authority_identity "$dump")"
staple_ok=0
if xcrun stapler validate "$DMG" >/dev/null 2>&1; then
  staple_ok=1
fi
require_production_dmg_identity "$identity" "$staple_ok"

echo "SHA-256:"
shasum -a 256 "$DMG"

TARGET="$(git rev-parse HEAD)"

if gh release view "$TAG" >/dev/null 2>&1; then
  tag_commit=""
  if tag_commit="$(git rev-parse -q --verify "${TAG}^{commit}")"; then
    :
  else
    ref_type="$(gh api "repos/:owner/:repo/git/ref/tags/${TAG}" --jq '.object.type // empty')"
    ref_sha="$(gh api "repos/:owner/:repo/git/ref/tags/${TAG}" --jq '.object.sha // empty')"
    peeled=""
    if [[ "$ref_type" == "tag" && -n "$ref_sha" ]]; then
      peeled="$(gh api "repos/:owner/:repo/git/tags/${ref_sha}" --jq '.object.sha // empty')"
    fi
    tag_commit="$(resolve_tag_commit "$ref_type" "$ref_sha" "$peeled")"
  fi
  require_release_commit_matches "$TARGET" "$tag_commit"
  existing="$(gh release view "$TAG" --json assets --jq '.assets[].name')"
  refuse_existing_release_dmg "$ASSET" "$existing"
  echo "Release $TAG exists without $ASSET; uploading DMG."
  gh release upload "$TAG" "$DMG"
else
  gh release create "$TAG" "$DMG" \
    --title "Audiobook Binder ${VERSION}" \
    --target "$TARGET" \
    --generate-notes
fi

echo "Release: $(gh release view "$TAG" --json url --jq .url)"
