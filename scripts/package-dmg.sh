#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/release-gates.sh"

ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP="$ROOT/dist/AudiobookBinder.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")"
STAGE="$ROOT/dist/dmg-stage"
VOL="Audiobook Binder"
DMG="$ROOT/dist/AudiobookBinder-${VERSION}.dmg"
IDENTITY="${CODESIGN_IDENTITY:-}"
PRODUCTION="${PRODUCTION:-0}"
# Capture once. Origin + provenance must not re-read HEAD after packaging.
PACKAGED_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"

if [[ ! -d "$APP" ]]; then
  echo "Missing $APP. Run: make app" >&2
  exit 1
fi

if [[ "$PRODUCTION" == "1" ]]; then
  require_clean_build_origin "$ROOT" "$PACKAGED_COMMIT"
  require_packaged_app_origin "$ROOT" "$PACKAGED_COMMIT" "$VERSION"
  if [[ -z "$IDENTITY" ]]; then
    if security find-identity -v -p codesigning 2>/dev/null | grep -q 'Developer ID Application'; then
      IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
    fi
  fi
  require_developer_id_identity "$IDENTITY"
  require_notary_credentials
elif [[ -z "$IDENTITY" ]]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q 'Developer ID Application'; then
    IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
  elif security find-identity -v -p codesigning 2>/dev/null | grep -q 'Apple Development'; then
    IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')"
    echo "Note: signing with Apple Development ($IDENTITY)."
    echo "Other Macs will still see a Gatekeeper warning until you use a Developer ID Application certificate and notarize."
  else
    IDENTITY="-"
    echo "Note: ad-hoc signing. Other Macs will see a Gatekeeper warning."
  fi
fi

echo "Signing $APP with $IDENTITY"
if [[ "$PRODUCTION" == "1" ]]; then
  /usr/bin/codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
elif [[ "$IDENTITY" == "-" ]]; then
  /usr/bin/codesign --force --deep --sign - "$APP"
else
  /usr/bin/codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"
fi
/usr/bin/codesign --verify --verbose=2 "$APP"
if [[ "$PRODUCTION" == "1" ]]; then
  # Re-sign changed the executable; refresh receipt hash (keep PACKAGED_COMMIT).
  write_packaged_app_receipt "$ROOT" "$PACKAGED_COMMIT"
fi

rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Audiobook Binder.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create \
  -volname "$VOL" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG"

rm -rf "$STAGE"

if [[ "$PRODUCTION" == "1" ]]; then
  echo "Signing $DMG with $IDENTITY"
  /usr/bin/codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  /usr/bin/codesign --verify --verbose=2 "$DMG"

  echo "Notarizing $DMG"
  if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
  else
    xcrun notarytool submit "$DMG" \
      --apple-id "$APPLE_ID" \
      --team-id "$APPLE_TEAM_ID" \
      --password "$NOTARY_PASSWORD" \
      --wait
  fi
  xcrun stapler staple "$DMG"
  echo "Stapled $DMG"
fi

echo "Built $DMG"
ls -lh "$DMG"

if [[ "$PRODUCTION" == "1" ]]; then
  receipt="$(packaged_app_receipt_path "$ROOT")"
  app_commit="$(provenance_json_field "$receipt" commit)"
  app_version="$(provenance_json_field "$receipt" version)"
  app_sha="$(provenance_json_field "$receipt" executable_sha256)"
  write_release_provenance "$ROOT" "$VERSION" "$PACKAGED_COMMIT" "$DMG" \
    "$app_commit" "$app_version" "$app_sha"
  echo "Wrote $(release_provenance_path "$ROOT" "$VERSION")"
fi
