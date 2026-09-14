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
git -C "$REPO" add README
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

# Provenance: matching HEAD + hash + version + test stamp passes; stale/wrong/missing fail.
PROV="$REPO"
mkdir -p "$PROV/dist"
print -r -- 'fixture-dmg-bytes' > "$PROV/dist/AudiobookBinder-1.2.3.dmg"
HEAD='abc123def'
VER='1.2.3'
write_release_tests_ok_stamp "$PROV" "$HEAD"
write_release_provenance "$PROV" "$VER" "$HEAD" "$PROV/dist/AudiobookBinder-1.2.3.dmg"
PROV_FILE="$(release_provenance_path "$PROV" "$VER")"

require_release_provenance "$PROV_FILE" "$PROV/dist/AudiobookBinder-1.2.3.dmg" "$HEAD" "$VER" "$PROV" \
  || fail "matching provenance HEAD+hash+version+stamp must pass"

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
write_release_provenance "$PROV" "$VER" "$HEAD" "$PROV/dist/AudiobookBinder-1.2.3.dmg"

print -r -- 'other-dmg-bytes' > "$PROV/dist/AudiobookBinder-1.2.3.dmg"
if require_release_provenance "$PROV_FILE" "$PROV/dist/AudiobookBinder-1.2.3.dmg" "$HEAD" "$VER" "$PROV"; then
  fail "wrong live DMG hash must fail"
fi

print -r -- 'fixture-dmg-bytes' > "$PROV/dist/AudiobookBinder-1.2.3.dmg"
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

# make release is sequential: clean, then tests, then production DMG (dry-run only).
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
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
