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
PROVENANCE="$(release_provenance_path "$ROOT" "$VERSION")"
require_release_provenance "$PROVENANCE" "$DMG" "$TARGET" "$VERSION" "$ROOT"

# Always resolve the remote tag. Do not trust a stale local ${TAG}^{commit}.
remote_tag_commit=""
gh_err="$(mktemp "${TMPDIR:-/tmp}/m4b-gh-tag.XXXXXX")"
if ref_body="$(gh api "repos/:owner/:repo/git/ref/tags/${TAG}" 2>"$gh_err")"; then
  rm -f "$gh_err"
  ref_type="$(print -r -- "$ref_body" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("object") or {}).get("type") or "")')"
  ref_sha="$(print -r -- "$ref_body" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("object") or {}).get("sha") or "")')"
  peeled=""
  if [[ "$ref_type" == "tag" && -n "$ref_sha" ]]; then
    peeled="$(gh api "repos/:owner/:repo/git/tags/${ref_sha}" --jq '.object.sha // empty')"
  fi
  remote_tag_commit="$(resolve_tag_commit "$ref_type" "$ref_sha" "$peeled")"
else
  if remote_tag_is_missing_error "$(<"$gh_err")"; then
    rm -f "$gh_err"
    remote_tag_commit=""
  else
    print -r -- "Failed to resolve remote tag ${TAG}:" >&2
    cat "$gh_err" >&2
    rm -f "$gh_err"
    exit 1
  fi
fi

require_tag_authority "$TARGET" "$remote_tag_commit" ""

if gh release view "$TAG" >/dev/null 2>&1; then
  existing="$(gh release view "$TAG" --json assets --jq '.assets[].name')"
  refuse_existing_release_dmg "$ASSET" "$existing"
  echo "Release $TAG exists without $ASSET; uploading DMG."
  gh release upload "$TAG" "$DMG"
elif should_create_release_targeting_head "$remote_tag_commit"; then
  gh release create "$TAG" "$DMG" \
    --title "Audiobook Binder ${VERSION}" \
    --target "$TARGET" \
    --generate-notes
else
  # Remote tag already points at HEAD; do not pass --target (it will not move the tag).
  gh release create "$TAG" "$DMG" \
    --title "Audiobook Binder ${VERSION}" \
    --generate-notes
fi

echo "Release: $(gh release view "$TAG" --json url --jq .url)"
