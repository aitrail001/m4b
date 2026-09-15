# Fixture for production release gates in scripts/release-gates.sh.
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/release-gates.sh"

fail() {
  print -r -- "FAIL: $1" >&2
  exit 1
}

# Developer ID Application is accepted; Apple Development, ad-hoc, and empty are not.
require_developer_id_identity 'Developer ID Application: Jane Doe (ABCD1234)' \
  || fail "Developer ID Application identity must be accepted"

if require_developer_id_identity 'Apple Development: Jane Doe (ABCD1234)'; then
  fail "Apple Development identity must be rejected for production"
fi

if require_developer_id_identity '-'; then
  fail "ad-hoc identity (-) must be rejected for production"
fi

if require_developer_id_identity ''; then
  fail "empty identity must be rejected for production"
fi

if require_developer_id_identity 'Developer ID Installer: Jane Doe (ABCD1234)'; then
  fail "Developer ID Installer must be rejected for app signing"
fi

# Existing versioned DMG asset → never clobber.
if should_clobber; then
  fail "should_clobber must fail (never replace a versioned DMG)"
fi

if refuse_existing_release_dmg 'AudiobookBinder-1.2.3.dmg' $'notes.txt\nAudiobookBinder-1.2.3.dmg'; then
  fail "existing AudiobookBinder-x.y.z.dmg must refuse clobber"
fi

refuse_existing_release_dmg 'AudiobookBinder-1.2.3.dmg' $'notes.txt' \
  || fail "missing DMG asset should allow first upload"

# Dirty worktree fails; clean passes; ALLOW_DIRTY_RELEASE=1 overrides.
mkdir -p "$SCRIPT_DIR/../.build"
REPO="$(mktemp -d "$SCRIPT_DIR/../.build/m4b-release-git.XXXXXX")"
trap 'rm -rf "$REPO"' EXIT
git -C "$REPO" init -q --template=
git -C "$REPO" config user.email 'release-gate@example.com'
git -C "$REPO" config user.name 'Release Gate'
print -r -- 'ok' > "$REPO/README"
print -r -- $'.build/\ndist/' > "$REPO/.gitignore"
git -C "$REPO" add README .gitignore
git -C "$REPO" commit -qm 'init'

(
  unset ALLOW_DIRTY_RELEASE
  require_clean_release_worktree "$REPO" || fail "clean worktree must pass"
)

print -r -- 'dirty' > "$REPO/extra.txt"
if (unset ALLOW_DIRTY_RELEASE; require_clean_release_worktree "$REPO"); then
  fail "dirty worktree must fail without ALLOW_DIRTY_RELEASE=1"
fi

ALLOW_DIRTY_RELEASE=1 require_clean_release_worktree "$REPO" \
  || fail "ALLOW_DIRTY_RELEASE=1 must allow a dirty worktree"

rm -f "$REPO/extra.txt"

# Notary credentials: fail closed when missing; accept the conventional env vars.
(
  unset NOTARYTOOL_PROFILE APPLE_ID APPLE_TEAM_ID NOTARY_PASSWORD
  if require_notary_credentials; then
    fail "missing notarization credentials must fail"
  fi
)

NOTARYTOOL_PROFILE='m4b-notary' require_notary_credentials \
  || fail "NOTARYTOOL_PROFILE must satisfy notarization credentials"

(
  unset NOTARYTOOL_PROFILE
  export APPLE_ID='dev@example.com' APPLE_TEAM_ID='TEAMID' NOTARY_PASSWORD='app-specific'
  require_notary_credentials || fail "APPLE_ID trio must satisfy notarization credentials"
)

(
  unset NOTARYTOOL_PROFILE NOTARY_PASSWORD
  export APPLE_ID='dev@example.com' APPLE_TEAM_ID='TEAMID'
  if require_notary_credentials; then
    fail "partial Apple ID credentials must fail"
  fi
)

# Production DMG identity + staple: Developer ID + staple-ok; reject the rest.
require_production_dmg_identity 'Developer ID Application: Jane Doe (ABCD1234)' 1 \
  || fail "Developer ID Application + staple-ok must be accepted"

dump=$'Format=disk image\nAuthority=Developer ID Application: Jane Doe (ABCD1234)\nAuthority=Apple Root CA'
require_production_dmg_identity "$dump" 1 \
  || fail "codesign Authority=Developer ID Application dump must be accepted"

if require_production_dmg_identity 'Apple Development: Jane Doe (ABCD1234)' 1; then
  fail "Apple Development DMG identity must be rejected"
fi

if require_production_dmg_identity '-' 1; then
  fail "ad-hoc DMG identity must be rejected"
fi

adhoc_dump=$'Format=disk image\nSignature=adhoc'
if require_production_dmg_identity "$adhoc_dump" 1; then
  fail "adhoc codesign dump must be rejected"
fi

if require_production_dmg_identity 'Developer ID Application: Jane Doe (ABCD1234)' 0; then
  fail "staple-failed Developer ID DMG must be rejected"
fi

if require_production_dmg_identity '' 0; then
  fail "unsigned DMG must be rejected"
fi

if require_production_dmg_identity '' 1; then
  fail "unsigned identity must be rejected even if staple-ok is set"
fi

# Existing tag must match HEAD.
require_release_commit_matches 'abc123def' 'abc123def' \
  || fail "matching tag commit and HEAD must pass"

if require_release_commit_matches 'abc123def' '999999999'; then
  fail "mismatched tag commit and HEAD must fail"
fi

if require_release_commit_matches 'abc123def' ''; then
  fail "empty tag commit must fail"
fi

# Remote tag is authoritative. A matching local tag must not hide a remote mismatch.
if require_tag_authority 'abc123def' '999999999' 'abc123def'; then
  fail "remote tag SHA != HEAD must fail even if local tag == HEAD"
fi

# Remote tag exists (no Release object) and points elsewhere.
if require_tag_authority 'abc123def' '999999999' ''; then
  fail "remote tag exists, no Release, mismatch must fail"
fi

require_tag_authority 'abc123def' 'abc123def' 'stalelocal' \
  || fail "remote tag matching HEAD must pass even if local tag differs"

require_tag_authority 'abc123def' '' 'stalelocal' \
  || fail "missing remote tag must pass (new tag; local is not authority)"

should_create_release_targeting_head '' \
  || fail "no remote tag must allow gh release create --target HEAD"

if should_create_release_targeting_head 'abc123def'; then
  fail "existing remote tag must not use gh release create --target HEAD"
fi

remote_tag_is_missing_error $'gh: Not Found (HTTP 404)' \
  || fail "HTTP 404 must count as a missing remote tag"

if remote_tag_is_missing_error $'API rate limit exceeded'; then
  fail "non-404 gh errors must fail closed, not look like a missing tag"
fi

# resolve_tag_commit: mocked GitHub git-ref objects (no network).
got="$(resolve_tag_commit commit abc123def)"
[[ "$got" == "abc123def" ]] || fail "lightweight tag (type=commit) must yield object.sha"

got="$(resolve_tag_commit tag tagobjectsha peeledcommitsha)"
[[ "$got" == "peeledcommitsha" ]] || fail "annotated tag (type=tag) must yield peeled commit sha"

if resolve_tag_commit '' ''; then
  fail "empty type/sha must fail closed"
fi

if resolve_tag_commit commit ''; then
  fail "lightweight tag with empty sha must fail"
fi

if resolve_tag_commit tag tagobjectsha ''; then
  fail "annotated tag with empty peeled sha must fail"
fi

if resolve_tag_commit unknown abc123def; then
  fail "unknown git ref object type must fail"
fi

# Provenance: matching HEAD + hash + version + test stamp + app origin passes;
# stale/wrong/missing fail. App-origin fields are required.
PROV="$REPO"
mkdir -p "$PROV/dist"
print -r -- 'fixture-dmg-bytes' > "$PROV/dist/AudiobookBinder-1.2.3.dmg"
HEAD='abc123def'
VER='1.2.3'
APP_SHA='deadbeefcafebabe'
write_release_tests_ok_stamp "$PROV" "$HEAD"
write_release_provenance "$PROV" "$VER" "$HEAD" "$PROV/dist/AudiobookBinder-1.2.3.dmg" \
  "$HEAD" "$VER" "$APP_SHA" "false"
PROV_FILE="$(release_provenance_path "$PROV" "$VER")"

require_release_provenance "$PROV_FILE" "$PROV/dist/AudiobookBinder-1.2.3.dmg" "$HEAD" "$VER" "$PROV" \
  || fail "matching provenance HEAD+hash+version+stamp must pass"

got="$(provenance_json_field "$PROV_FILE" app_commit)"
[[ "$got" == "$HEAD" ]] || fail "provenance must record app_commit from the receipt"
got="$(provenance_json_field "$PROV_FILE" app_version)"
[[ "$got" == "$VER" ]] || fail "provenance must record app_version from the receipt"
got="$(provenance_json_field "$PROV_FILE" tests_ok_source)"
[[ "$got" == "stamp" ]] || fail "stamp-backed tests_ok must record tests_ok_source=stamp"

(
  export RELEASE_TESTS_OK=1
  write_release_provenance "$PROV" "$VER" "$HEAD" "$PROV/dist/AudiobookBinder-1.2.3.dmg" \
    "$HEAD" "$VER" "$APP_SHA" "false"
)
got="$(provenance_json_field "$PROV_FILE" tests_ok_source)"
[[ "$got" == "override" ]] || fail "RELEASE_TESTS_OK=1 must record tests_ok_source=override, not stamp"
write_release_provenance "$PROV" "$VER" "$HEAD" "$PROV/dist/AudiobookBinder-1.2.3.dmg" \
  "$HEAD" "$VER" "$APP_SHA" "false"

if require_release_provenance "$PROV_FILE" "$PROV/dist/AudiobookBinder-1.2.3.dmg" "$HEAD" '9.9.9' "$PROV"; then
  fail "provenance version mismatch must fail"
fi

python3 - "$PROV_FILE" <<'PY'
import json, sys
path = sys.argv[1]
obj = json.load(open(path))
obj["commit"] = "stalecommit000"
with open(path, "w") as fh:
    json.dump(obj, fh, indent=2)
    fh.write("\n")
PY
if require_release_provenance "$PROV_FILE" "$PROV/dist/AudiobookBinder-1.2.3.dmg" "$HEAD" "$VER" "$PROV"; then
  fail "stale provenance commit must fail"
fi
write_release_provenance "$PROV" "$VER" "$HEAD" "$PROV/dist/AudiobookBinder-1.2.3.dmg" \
  "$HEAD" "$VER" "$APP_SHA" "false"

print -r -- 'other-dmg-bytes' > "$PROV/dist/AudiobookBinder-1.2.3.dmg"
if require_release_provenance "$PROV_FILE" "$PROV/dist/AudiobookBinder-1.2.3.dmg" "$HEAD" "$VER" "$PROV"; then
  fail "wrong live DMG hash must fail"
fi

print -r -- 'fixture-dmg-bytes' > "$PROV/dist/AudiobookBinder-1.2.3.dmg"

# Matching DMG hash without verified app-origin fields must fail.
python3 - "$PROV_FILE" <<'PY'
import json, sys
path = sys.argv[1]
obj = json.load(open(path))
for key in ("app_commit", "app_version", "app_sha256"):
    obj.pop(key, None)
with open(path, "w") as fh:
    json.dump(obj, fh, indent=2)
    fh.write("\n")
PY
if require_release_provenance "$PROV_FILE" "$PROV/dist/AudiobookBinder-1.2.3.dmg" "$HEAD" "$VER" "$PROV"; then
  fail "provenance without app_commit/app_version must fail"
fi
write_release_provenance "$PROV" "$VER" "$HEAD" "$PROV/dist/AudiobookBinder-1.2.3.dmg" \
  "$HEAD" "$VER" "$APP_SHA" "false"

rm -f "$(release_tests_ok_stamp_path "$PROV")"
(
  unset RELEASE_TESTS_OK
  if require_release_provenance "$PROV_FILE" "$PROV/dist/AudiobookBinder-1.2.3.dmg" "$HEAD" "$VER" "$PROV"; then
    fail "missing tests stamp must fail"
  fi
)

if require_release_provenance "$PROV/dist/missing.provenance.json" "$PROV/dist/AudiobookBinder-1.2.3.dmg" "$HEAD" "$VER" "$PROV"; then
  fail "missing provenance file must fail"
fi

# App origin gate: fake bundle + receipt (no swift build / notarytool).
install_fixture_app() {
  local root="$1"
  local version="$2"
  local payload="${3:-fixture-exe}"
  local app
  app="$(packaged_app_path "$root")"
  mkdir -p "$app/Contents/MacOS"
  print -r -- "$payload" > "$app/Contents/MacOS/AudiobookBinder"
  rm -f "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $version" \
    "$app/Contents/Info.plist" >/dev/null
}

install_fixture_app "$PROV" "$VER"
write_packaged_app_receipt "$PROV" 'aaa'
if require_packaged_app_origin "$PROV" 'bbb' "$VER"; then
  fail "stale receipt commit must fail when HEAD is passed as another commit"
fi

install_fixture_app "$PROV" '9.9.9'
write_packaged_app_receipt "$PROV" "$HEAD"
if require_packaged_app_origin "$PROV" "$HEAD" "$VER"; then
  fail "receipt/app version 9.9.9 must fail against checkout 1.2.3"
fi

install_fixture_app "$PROV" "$VER"
rm -f "$(packaged_app_receipt_path "$PROV")"
if require_packaged_app_origin "$PROV" "$HEAD" "$VER"; then
  fail "missing app receipt must fail"
fi

install_fixture_app "$PROV" "$VER"
write_packaged_app_receipt "$PROV" "$HEAD"
print -r -- 'mutated-exe' > "$(packaged_app_path "$PROV")/Contents/MacOS/AudiobookBinder"
if require_packaged_app_origin "$PROV" "$HEAD" "$VER"; then
  fail "executable sha256 mismatch vs receipt must fail"
fi

mkdir -p "$PROV/.build/release"
print -r -- 'fixture-exe' > "$PROV/.build/release/AudiobookBinder"
chmod +x "$PROV/.build/release/AudiobookBinder"
write_build_intent "$PROV" "$HEAD"
write_build_origin "$PROV" "$HEAD"
install_fixture_app "$PROV" "$VER"
write_packaged_app_receipt "$PROV" "$HEAD"
require_packaged_app_origin "$PROV" "$HEAD" "$VER" \
  || fail "matching receipt + app plist + exe hash + HEAD + version must pass"

# Compile-time build origin: bind .build/release/AudiobookBinder bytes to the
# source commit. Fixture binaries carry a FROM-A / FROM-B sentinel (no swift build).
install_fixture_release_binary() {
  local root="$1"
  local payload="$2"
  mkdir -p "$root/.build/release"
  print -r -- "$payload" > "$root/.build/release/AudiobookBinder"
  chmod +x "$root/.build/release/AudiobookBinder"
}

release_sentinel() {
  tr -d $'\n' < "${1:-.}/.build/release/AudiobookBinder"
}

COMMIT_A='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
COMMIT_B='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
ORIGIN_FILE="$PROV/.build/release/AudiobookBinder.origin.json"
RELEASE_BIN="$PROV/.build/release/AudiobookBinder"

install_fixture_release_binary "$PROV" 'FROM-A'
rm -f "$ORIGIN_FILE"
if require_build_origin "$PROV" "$HEAD"; then
  fail "missing build origin must fail"
fi
[[ "$(release_sentinel "$PROV")" == "FROM-A" ]] \
  || fail "missing-origin check must not rewrite the leftover binary sentinel"

# Origin for A + FROM-A, required HEAD B. A freshly written packaged receipt
# for B (hash of binary A) must not make compile-origin OK.
install_fixture_release_binary "$PROV" 'FROM-A'
write_build_intent "$PROV" "$COMMIT_A"
write_build_origin "$PROV" "$COMMIT_A"
install_fixture_app "$PROV" "$VER" 'FROM-A'
write_packaged_app_receipt "$PROV" "$COMMIT_B"
if require_build_origin "$PROV" "$COMMIT_B"; then
  fail "origin commit A vs required HEAD B must fail even with a packaged receipt for B"
fi
if require_packaged_app_origin "$PROV" "$COMMIT_B" "$VER"; then
  : # receipt alone can look consistent; compile-origin is the authority
else
  fail "packaged receipt for B + hash(FROM-A) is internally consistent (V3-05 happy-path shape)"
fi
[[ "$(release_sentinel "$PROV")" == "FROM-A" ]] \
  || fail "commit-mismatch origin check must leave FROM-A in place"
got="$(provenance_json_field "$ORIGIN_FILE" commit)"
[[ "$got" == "$COMMIT_A" ]] || fail "origin commit must stay A after a B receipt is written"

# Origin commit matches HEAD but leftover exe bytes no longer match the origin hash.
install_fixture_release_binary "$PROV" 'FROM-A'
write_build_origin "$PROV" "$HEAD"
print -r -- 'MUTATED-FROM-A' > "$RELEASE_BIN"
chmod +x "$RELEASE_BIN"
if require_build_origin "$PROV" "$HEAD"; then
  fail "mutated leftover exe must fail build-origin hash check"
fi
[[ "$(release_sentinel "$PROV")" == "MUTATED-FROM-A" ]] \
  || fail "hash-mismatch check must not restore or relabel the mutated binary"

# Matching origin commit + matching exe hash.
install_fixture_release_binary "$PROV" 'FROM-B'
write_build_origin "$PROV" "$HEAD"
require_build_origin "$PROV" "$HEAD" \
  || fail "matching origin commit + exe hash must pass"
[[ "$(release_sentinel "$PROV")" == "FROM-B" ]] \
  || fail "matching origin must keep the FROM-B sentinel"
got="$(provenance_json_field "$ORIGIN_FILE" commit)"
[[ "$got" == "$HEAD" ]] || fail "origin must record the compile commit"
got="$(provenance_json_field "$ORIGIN_FILE" executable_sha256)"
live_sha="$(file_sha256 "$RELEASE_BIN")"
[[ "$got" == "$live_sha" ]] || fail "origin must record the live release-binary hash"

# Stale-binary packaging: leftover FROM-A compiled at A, current HEAD is B.
# The gate package-app.sh calls must fail; do not relabel the leftover binary.
install_fixture_release_binary "$PROV" 'FROM-A'
write_build_origin "$PROV" "$COMMIT_A"
if require_build_origin "$PROV" "$COMMIT_B"; then
  fail "stale-binary packaging gate must fail when origin is A and HEAD is B"
fi
[[ "$(release_sentinel "$PROV")" == "FROM-A" ]] \
  || fail "failed packaging gate must leave leftover .build binary as FROM-A"
got="$(provenance_json_field "$ORIGIN_FILE" commit)"
[[ "$got" == "$COMMIT_A" ]] || fail "failed packaging gate must not rewrite origin commit to B"

pkg_script="$SCRIPT_DIR/package-app.sh"
grep -q 'require_build_origin' "$pkg_script" \
  || fail "package-app.sh must call require_build_origin"
origin_n="$(grep -n 'require_build_origin' "$pkg_script" | head -1 | cut -d: -f1)"
bin_cp_n="$(grep -n 'cp "\$BIN"' "$pkg_script" | head -1 | cut -d: -f1)"
plist_n="$(grep -n 'cp "\$ROOT/Info.plist"' "$pkg_script" | head -1 | cut -d: -f1)"
receipt_n="$(grep -n 'write_packaged_app_receipt' "$pkg_script" | head -1 | cut -d: -f1)"
[[ -n "$origin_n" && -n "$bin_cp_n" && -n "$plist_n" && -n "$receipt_n" ]] \
  || fail "package-app.sh must require build origin and copy Info.plist / write a receipt"
if (( origin_n >= bin_cp_n || origin_n >= plist_n || origin_n >= receipt_n )); then
  fail "package-app.sh must require build origin before copying the binary, Info.plist, or writing a receipt"
fi

# Clean matching compile-origin + packaged-app origin still passes.
install_fixture_release_binary "$PROV" 'FROM-B'
write_build_intent "$PROV" "$HEAD"
write_build_origin "$PROV" "$HEAD"
require_build_origin "$PROV" "$HEAD" \
  || fail "clean compile-origin path must pass"
install_fixture_app "$PROV" "$VER" 'FROM-B'
write_packaged_app_receipt "$PROV" "$HEAD"
require_packaged_app_origin "$PROV" "$HEAD" "$VER" \
  || fail "matching compile-origin + packaged-app origin must pass"
[[ "$(release_sentinel "$PROV")" == "FROM-B" ]] \
  || fail "clean compile+package path must keep the FROM-B sentinel"

# R5-04: dirty compile origin is ok for local packaging, not for production.
# Fixture matrix (sentinel exe + JSON, no codesign/notary):
#   clean_matching     → require_build_origin + production checks pass
#   dirty_matching     → require_build_origin may pass; production fails
#   old_commit         → rejected (covered above)
#   changed_executable → rejected (covered above)
#   missing_origin     → rejected (covered above)
rm -f "$ORIGIN_FILE" "$(build_intent_path "$PROV")"
install_fixture_release_binary "$PROV" 'FROM-CLEAN'
write_build_intent "$PROV" "$HEAD"
write_build_origin "$PROV" "$HEAD"
got="$(provenance_json_field "$ORIGIN_FILE" dirty)"
[[ "$got" == "false" ]] || fail "clean_matching origin must record dirty=false"
require_build_origin "$PROV" "$HEAD" \
  || fail "clean_matching require_build_origin must pass"
require_clean_build_origin "$PROV" "$HEAD" \
  || fail "clean_matching production origin check must pass"
install_fixture_app "$PROV" "$VER" 'FROM-CLEAN'
write_packaged_app_receipt "$PROV" "$HEAD"
got="$(provenance_json_field "$(packaged_app_receipt_path "$PROV")" dirty)"
[[ "$got" == "false" ]] || fail "clean_matching receipt must copy dirty=false"
require_packaged_app_origin "$PROV" "$HEAD" "$VER" \
  || fail "clean_matching packaged-app origin must pass"
write_release_tests_ok_stamp "$PROV" "$HEAD"
print -r -- 'fixture-dmg-bytes' > "$PROV/dist/AudiobookBinder-1.2.3.dmg"
write_release_provenance "$PROV" "$VER" "$HEAD" "$PROV/dist/AudiobookBinder-1.2.3.dmg" \
  "$HEAD" "$VER" "$APP_SHA" "false"
PROV_FILE="$(release_provenance_path "$PROV" "$VER")"
got="$(provenance_json_field "$PROV_FILE" dirty)"
[[ "$got" == "false" ]] || fail "clean_matching provenance must record dirty=false"
require_release_provenance "$PROV_FILE" "$PROV/dist/AudiobookBinder-1.2.3.dmg" "$HEAD" "$VER" "$PROV" \
  || fail "clean_matching release provenance must pass"

install_fixture_release_binary "$PROV" 'FROM-DIRTY'
print -r -- 'dirty-compile' > "$PROV/dirty-compile.txt"
write_build_intent "$PROV" "$HEAD"
write_build_origin "$PROV" "$HEAD"
got="$(provenance_json_field "$ORIGIN_FILE" dirty)"
[[ "$got" == "true" ]] || fail "dirty_matching origin must record dirty=true"
require_build_origin "$PROV" "$HEAD" \
  || fail "dirty_matching require_build_origin may still pass for local packaging"
if require_clean_build_origin "$PROV" "$HEAD"; then
  fail "dirty_matching production origin check must fail"
fi
install_fixture_app "$PROV" "$VER" 'FROM-DIRTY'
write_packaged_app_receipt "$PROV" "$HEAD"
got="$(provenance_json_field "$(packaged_app_receipt_path "$PROV")" dirty)"
[[ "$got" == "true" ]] || fail "dirty_matching receipt must copy dirty=true from origin"
if require_packaged_app_origin "$PROV" "$HEAD" "$VER"; then
  fail "dirty_matching packaged-app origin must fail production"
fi
write_release_provenance "$PROV" "$VER" "$HEAD" "$PROV/dist/AudiobookBinder-1.2.3.dmg" \
  "$HEAD" "$VER" "$APP_SHA"
got="$(provenance_json_field "$PROV_FILE" dirty)"
[[ "$got" == "true" ]] || fail "dirty_matching provenance must record dirty=true"
if require_release_provenance "$PROV_FILE" "$PROV/dist/AudiobookBinder-1.2.3.dmg" "$HEAD" "$VER" "$PROV"; then
  fail "dirty_matching release provenance must fail production"
fi

# Restore the tree to clean HEAD without changing exe bytes, then rewrite origin.
rm -f "$PROV/dirty-compile.txt"
write_build_intent "$PROV" "$HEAD"
write_build_origin "$PROV" "$HEAD"
got="$(provenance_json_field "$ORIGIN_FILE" dirty)"
[[ "$got" == "true" ]] || fail "rewrite origin after clean restore must keep dirty=true for the same exe"
require_build_origin "$PROV" "$HEAD" \
  || fail "rewritten dirty-origin binary must still pass require_build_origin"
if require_clean_build_origin "$PROV" "$HEAD"; then
  fail "rewritten dirty-origin binary must still fail production"
fi
[[ "$(release_sentinel "$PROV")" == "FROM-DIRTY" ]] \
  || fail "origin rewrite must not change leftover exe bytes"

# Receipt without a dirty field is not a clean production receipt.
install_fixture_release_binary "$PROV" 'FROM-CLEAN'
rm -f "$ORIGIN_FILE" "$(build_intent_path "$PROV")"
write_build_intent "$PROV" "$HEAD"
write_build_origin "$PROV" "$HEAD"
install_fixture_app "$PROV" "$VER" 'FROM-CLEAN'
write_packaged_app_receipt "$PROV" "$HEAD"
python3 - "$(packaged_app_receipt_path "$PROV")" <<'PY'
import json, sys
path = sys.argv[1]
obj = json.load(open(path))
obj.pop("dirty", None)
with open(path, "w") as fh:
    json.dump(obj, fh, indent=2)
    fh.write("\n")
PY
if require_packaged_app_origin "$PROV" "$HEAD" "$VER"; then
  fail "receipt without dirty field must fail production"
fi
write_release_provenance "$PROV" "$VER" "$HEAD" "$PROV/dist/AudiobookBinder-1.2.3.dmg" \
  "$HEAD" "$VER" "$APP_SHA" "false"
python3 - "$PROV_FILE" <<'PY'
import json, sys
path = sys.argv[1]
obj = json.load(open(path))
obj.pop("dirty", None)
with open(path, "w") as fh:
    json.dump(obj, fh, indent=2)
    fh.write("\n")
PY
if require_release_provenance "$PROV_FILE" "$PROV/dist/AudiobookBinder-1.2.3.dmg" "$HEAD" "$VER" "$PROV"; then
  fail "provenance without dirty field must fail production"
fi

# make release is sequential: clean, then tests, then production DMG (dry-run only).
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_PLAN="$(make -C "$REPO_ROOT" -n build)"
print -r -- "$BUILD_PLAN" | grep -q 'swift build -c release' \
  || fail "make -n build must run swift build -c release"
print -r -- "$BUILD_PLAN" | grep -q 'write-build-intent\|write_build_intent' \
  || fail "make -n build must write compile intent before swift build"
print -r -- "$BUILD_PLAN" | grep -q 'write-build-origin\|write_build_origin' \
  || fail "make -n build must write compile origin after swift build"
intent_n="$(print -r -- "$BUILD_PLAN" | grep -n 'write-build-intent\|write_build_intent' | head -1 | cut -d: -f1)"
swift_n="$(print -r -- "$BUILD_PLAN" | grep -n 'swift build -c release' | head -1 | cut -d: -f1)"
origin_write_n="$(print -r -- "$BUILD_PLAN" | grep -n 'write-build-origin\|write_build_origin' | head -1 | cut -d: -f1)"
[[ -n "$intent_n" && -n "$swift_n" && -n "$origin_write_n" ]] \
  || fail "make -n build must list intent, swift build, and the origin writer"
if (( intent_n >= swift_n )); then
  fail "make -n build must write compile intent before swift build"
fi
if (( swift_n >= origin_write_n )); then
  fail "make -n build must write compile origin after swift build"
fi

APP_PLAN="$(make -C "$REPO_ROOT" -n app)"
print -r -- "$APP_PLAN" | grep -q 'swift build -c release' \
  || fail "make -n app must build before packaging"
print -r -- "$APP_PLAN" | grep -q 'write-build-intent\|write_build_intent' \
  || fail "make -n app must write compile intent before swift build"
print -r -- "$APP_PLAN" | grep -q 'write-build-origin\|write_build_origin' \
  || fail "make -n app must write compile origin after swift build"
print -r -- "$APP_PLAN" | grep -q 'package-app.sh' \
  || fail "make -n app must invoke package-app.sh"
app_intent_n="$(print -r -- "$APP_PLAN" | grep -n 'write-build-intent\|write_build_intent' | head -1 | cut -d: -f1)"
app_swift_n="$(print -r -- "$APP_PLAN" | grep -n 'swift build -c release' | head -1 | cut -d: -f1)"
app_origin_n="$(print -r -- "$APP_PLAN" | grep -n 'write-build-origin\|write_build_origin' | head -1 | cut -d: -f1)"
app_pkg_n="$(print -r -- "$APP_PLAN" | grep -n 'package-app.sh' | head -1 | cut -d: -f1)"
if (( app_intent_n >= app_swift_n || app_swift_n >= app_origin_n || app_origin_n >= app_pkg_n )); then
  fail "make -n app must write intent, then swift build, then origin, then package-app.sh"
fi

dmg_script="$SCRIPT_DIR/package-dmg.sh"
grep -q 'require_packaged_app_origin' "$dmg_script" \
  || fail "package-dmg.sh must call require_packaged_app_origin"
grep -q 'require_clean_build_origin' "$dmg_script" \
  || fail "package-dmg.sh PRODUCTION path must refuse a dirty compile origin"
dmg_origin_n="$(grep -n 'require_packaged_app_origin' "$dmg_script" | head -1 | cut -d: -f1)"
dmg_clean_n="$(grep -n 'require_clean_build_origin' "$dmg_script" | head -1 | cut -d: -f1)"
dmg_sign_n="$(grep -n 'Signing \$APP' "$dmg_script" | head -1 | cut -d: -f1)"
[[ -n "$dmg_origin_n" && -n "$dmg_clean_n" && -n "$dmg_sign_n" ]] \
  || fail "package-dmg.sh must gate origin/receipt before signing"
if (( dmg_origin_n >= dmg_sign_n || dmg_clean_n >= dmg_sign_n )); then
  fail "package-dmg.sh PRODUCTION must refuse dirty origin/receipt before signing"
fi
awk '/^require_packaged_app_origin\(\)/,/^}/' "$SCRIPT_DIR/release-gates.sh" \
  | grep -q dirty \
  || fail "require_packaged_app_origin must read dirty"

PLAN="$(make -C "$REPO_ROOT" -n release)"
print -r -- "$PLAN" | grep -q 'require-clean-release' \
  || fail "make -n release must fail-fast with require-clean-release"
print -r -- "$PLAN" | grep -q 'swift test' \
  || fail "make -n release must include swift test"
print -r -- "$PLAN" | grep -q 'PRODUCTION=1' \
  || fail "make -n release must package a PRODUCTION=1 DMG"
clean_n="$(print -r -- "$PLAN" | grep -n 'require-clean-release' | head -1 | cut -d: -f1)"
test_n="$(print -r -- "$PLAN" | grep -n 'swift test' | head -1 | cut -d: -f1)"
prod_n="$(print -r -- "$PLAN" | grep -n 'PRODUCTION=1' | head -1 | cut -d: -f1)"
[[ -n "$clean_n" && -n "$test_n" && -n "$prod_n" ]] \
  || fail "make -n release must list require-clean-release, swift test, and PRODUCTION=1"
if (( clean_n >= test_n || test_n >= prod_n )); then
  fail "make -n release must run require-clean-release, then swift test, then PRODUCTION=1"
fi

print -r -- "ok: release gates"
