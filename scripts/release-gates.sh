# Sourced by package-app.sh, package-dmg.sh, github-release.sh, and
# scripts/test-release-gates.sh.
# Helpers only — no packaging, notarization, or GitHub side effects.
# Provenance + remote-tag helpers are predicates; they do not call gh or notarytool.

# Production signing accepts only a Developer ID Application identity.
# Rejects empty, ad-hoc (-), Apple Development, and other certificate types.
require_developer_id_identity() {
  local identity="${1-}"
  if [[ -z "$identity" ]]; then
    print -r -- "Production release requires CODESIGN_IDENTITY to be a Developer ID Application identity. Set CODESIGN_IDENTITY or install that certificate." >&2
    return 1
  fi
  if [[ "$identity" == "-" ]]; then
    print -r -- "Production release refuses ad-hoc signing (CODESIGN_IDENTITY=-). Use a Developer ID Application identity." >&2
    return 1
  fi
  if [[ "$identity" != "Developer ID Application:"* ]]; then
    print -r -- "Production release requires a Developer ID Application identity, not: $identity" >&2
    return 1
  fi
  return 0
}

# Public uploads never replace a versioned DMG. Always fail.
should_clobber() {
  return 1
}

# Fail if a versioned DMG name is already on the GitHub release asset list.
refuse_existing_release_dmg() {
  local asset_name="$1"
  local asset_names="${2-}"
  if print -r -- "$asset_names" | grep -Fxq -- "$asset_name"; then
    print -r -- "GitHub release already has $asset_name. Bump CFBundleShortVersionString in Info.plist; do not replace the shipped DMG." >&2
    should_clobber
    return 1
  fi
  return 0
}

# Public upload requires a clean worktree unless ALLOW_DIRTY_RELEASE=1.
require_clean_release_worktree() {
  local repo="${1:-.}"
  if [[ "${ALLOW_DIRTY_RELEASE:-0}" == "1" ]]; then
    return 0
  fi
  local dirty
  dirty="$(git -C "$repo" status --porcelain)"
  if [[ -n "$dirty" ]]; then
    print -r -- "Refusing public release from a dirty git worktree. Commit or stash your changes, or set ALLOW_DIRTY_RELEASE=1." >&2
    return 1
  fi
  return 0
}

# Notarization credentials: NOTARYTOOL_PROFILE, or APPLE_ID + APPLE_TEAM_ID + NOTARY_PASSWORD.
require_notary_credentials() {
  if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
    return 0
  fi
  if [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
    return 0
  fi
  print -r -- "Production notarization requires NOTARYTOOL_PROFILE or APPLE_ID, APPLE_TEAM_ID, and NOTARY_PASSWORD. Refusing to skip notarization." >&2
  return 1
}

# Leaf identity from `codesign -dv --verbose=4` text (stderr dump). Ad-hoc → "-".
production_dmg_authority_identity() {
  local dump="${1-}"
  local identity
  identity="$(print -r -- "$dump" | awk -F= '/^Authority=/{print $2; exit}')"
  if [[ -n "$identity" ]]; then
    print -r -- "$identity"
    return 0
  fi
  if print -r -- "$dump" | grep -q '^Signature=adhoc$'; then
    print -r -- '-'
    return 0
  fi
  print -r -- ''
  return 0
}

# Refuse a local/ad-hoc/unsigned/unstapled DMG. $1 = identity or codesign dump; $2 = 1 if stapler validate passed.
require_production_dmg_identity() {
  local authority_text="${1-}"
  local staple_ok="${2:-0}"
  local identity="$authority_text"
  if print -r -- "$authority_text" | grep -q '^Authority=\|^Signature=adhoc$'; then
    identity="$(production_dmg_authority_identity "$authority_text")"
  fi
  if [[ "$staple_ok" != "1" ]]; then
    print -r -- "Production upload requires a stapled notarization ticket. stapler validate failed or the DMG is not notarized." >&2
    return 1
  fi
  require_developer_id_identity "$identity"
}

# Existing GitHub tag must point at the built commit (HEAD).
require_release_commit_matches() {
  local head="${1-}"
  local tag_commit="${2-}"
  if [[ -z "$head" || -z "$tag_commit" ]]; then
    print -r -- "Cannot verify release tag provenance: missing HEAD or tag commit." >&2
    return 1
  fi
  if [[ "$head" != "$tag_commit" ]]; then
    print -r -- "Tag commit $tag_commit does not match HEAD $head. Refusing to attach a DMG to a tag that points elsewhere." >&2
    return 1
  fi
  return 0
}

# Remote tag is the only authority. A matching local tag is ignored.
# $1 = HEAD, $2 = remote tag commit (empty if the remote ref is missing),
# $3 = local tag commit (never preferred).
require_tag_authority() {
  local head="${1-}"
  local remote_tag_commit="${2-}"
  local local_tag_commit="${3-}"
  if [[ -n "$remote_tag_commit" ]]; then
    require_release_commit_matches "$head" "$remote_tag_commit"
    return $?
  fi
  return 0
}

# gh release create --target HEAD only when the remote tag does not exist.
should_create_release_targeting_head() {
  local remote_tag_commit="${1-}"
  [[ -z "$remote_tag_commit" ]]
}

# True when gh api failed because the remote tag ref is absent (not an auth/network error).
remote_tag_is_missing_error() {
  local err="${1-}"
  print -r -- "$err" | grep -Eiq 'HTTP[[:space:]]*404|[[:space:]]404[[:space:]]|Not Found|Reference does not exist'
}

release_tests_ok_stamp_path() {
  print -r -- "${1:-.}/dist/.release-tests-ok"
}

write_release_tests_ok_stamp() {
  local root="${1:-.}"
  local head="${2-}"
  mkdir -p "$root/dist"
  print -r -- "$head" > "$(release_tests_ok_stamp_path "$root")"
}

release_tests_ok_recorded() {
  local root="${1:-.}"
  local head="${2-}"
  local stamp
  stamp="$(release_tests_ok_stamp_path "$root")"
  [[ -f "$stamp" ]] || return 1
  local stamped
  stamped="$(tr -d '[:space:]' < "$stamp")"
  [[ -n "$head" && "$stamped" == "$head" ]]
}

require_release_tests_ok() {
  local root="${1:-.}"
  local head="${2-}"
  if [[ "${RELEASE_TESTS_OK:-0}" == "1" ]]; then
    return 0
  fi
  if release_tests_ok_recorded "$root" "$head"; then
    return 0
  fi
  print -r -- "Refusing release: missing or stale test-ok stamp. Run: make test" >&2
  return 1
}

release_provenance_path() {
  local root="${1:-.}"
  local version="${2-}"
  print -r -- "$root/dist/AudiobookBinder-${version}.provenance.json"
}

file_sha256() {
  local file="${1-}"
  if [[ ! -f "$file" ]]; then
    print -r -- "Cannot hash missing file $file" >&2
    return 1
  fi
  shasum -a 256 "$file" | awk '{print $1}'
}

dmg_sha256() {
  file_sha256 "${1-}"
}

packaged_app_path() {
  print -r -- "${1:-.}/dist/AudiobookBinder.app"
}

packaged_app_receipt_path() {
  print -r -- "${1:-.}/dist/AudiobookBinder.app.receipt.json"
}

app_plist_version() {
  local app="${1-}"
  local plist="$app/Contents/Info.plist"
  if [[ ! -f "$plist" ]]; then
    print -r -- "Missing $plist" >&2
    return 1
  fi
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist"
}

# Written by package-app.sh after the copied Info.plist + executable are in place.
write_packaged_app_receipt() {
  local root="${1:-.}"
  local commit="${2-}"
  local app="${3:-$(packaged_app_path "$root")}"
  if [[ -z "$commit" ]]; then
    print -r -- "Cannot write app receipt: missing commit." >&2
    return 1
  fi
  local version sha dest exe
  version="$(app_plist_version "$app")" || return 1
  exe="$app/Contents/MacOS/AudiobookBinder"
  sha="$(file_sha256 "$exe")" || return 1
  dest="$(packaged_app_receipt_path "$root")"
  mkdir -p "${dest:h}"
  python3 - "$dest" "$commit" "$version" "$sha" <<'PY'
import json, sys
path, commit, version, sha = sys.argv[1:5]
with open(path, "w") as fh:
    json.dump(
        {
            "commit": commit,
            "version": version,
            "executable_sha256": sha,
        },
        fh,
        indent=2,
    )
    fh.write("\n")
PY
}

# Production packaging: receipt + app must match the commit/version captured at
# the start of PRODUCTION=1 (before Developer ID re-sign / notary).
require_packaged_app_origin() {
  local root="${1:-.}"
  local intended_commit="${2-}"
  local checkout_version="${3-}"
  local app="${4:-$(packaged_app_path "$root")}"
  local receipt="${5:-$(packaged_app_receipt_path "$root")}"

  if [[ -z "$intended_commit" || -z "$checkout_version" ]]; then
    print -r -- "Cannot verify packaged app origin: missing intended commit or checkout version." >&2
    return 1
  fi
  if [[ ! -d "$app" ]]; then
    print -r -- "Missing packaged app $app. Run: make app" >&2
    return 1
  fi
  if [[ ! -f "$receipt" ]]; then
    print -r -- "Missing packaged app receipt $receipt. Run: make app" >&2
    return 1
  fi

  local r_commit r_version r_sha app_ver live_sha exe
  r_commit="$(provenance_json_field "$receipt" commit)" || return 1
  r_version="$(provenance_json_field "$receipt" version)" || return 1
  r_sha="$(provenance_json_field "$receipt" executable_sha256)" || return 1

  if [[ -z "$r_commit" || "$r_commit" != "$intended_commit" ]]; then
    print -r -- "Packaged app receipt commit ${r_commit:-empty} does not match $intended_commit. Refusing to notarize a leftover app from another checkout." >&2
    return 1
  fi
  if [[ -z "$r_version" || "$r_version" != "$checkout_version" ]]; then
    print -r -- "Packaged app receipt version ${r_version:-empty} does not match Info.plist $checkout_version." >&2
    return 1
  fi
  app_ver="$(app_plist_version "$app")" || return 1
  if [[ "$app_ver" != "$checkout_version" ]]; then
    print -r -- "Packaged app Info.plist version $app_ver does not match checkout $checkout_version." >&2
    return 1
  fi
  exe="$app/Contents/MacOS/AudiobookBinder"
  live_sha="$(file_sha256 "$exe")" || return 1
  if [[ -z "$r_sha" || "$r_sha" != "$live_sha" ]]; then
    print -r -- "Packaged app executable SHA-256 does not match receipt. Refusing a swapped or rebuilt binary." >&2
    return 1
  fi
  return 0
}

provenance_json_field() {
  local file="${1-}"
  local key="${2-}"
  python3 - "$file" "$key" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    obj = json.load(open(path))
except Exception:
    sys.exit(1)
val = obj.get(key, "")
if isinstance(val, bool):
    print("true" if val else "false")
else:
    print("" if val is None else val)
PY
}

write_release_provenance() {
  local root="${1:-.}"
  local version="${2-}"
  local head="${3-}"
  local dmg="${4-}"
  local app_commit="${5-}"
  local app_version="${6-}"
  local app_sha256="${7-}"
  if [[ -z "$version" || -z "$head" ]]; then
    print -r -- "Cannot write provenance: missing version or commit." >&2
    return 1
  fi
  if [[ -z "$app_commit" || -z "$app_version" ]]; then
    print -r -- "Cannot write provenance: missing app origin (app_commit/app_version)." >&2
    return 1
  fi
  if [[ "$app_commit" != "$head" ]]; then
    print -r -- "Cannot write provenance: app_commit $app_commit does not match commit $head." >&2
    return 1
  fi
  if [[ "$app_version" != "$version" ]]; then
    print -r -- "Cannot write provenance: app_version $app_version does not match version $version." >&2
    return 1
  fi
  local sha
  sha="$(dmg_sha256 "$dmg")" || return 1
  local tests_ok="false"
  local tests_ok_source=""
  if [[ "${RELEASE_TESTS_OK:-0}" == "1" ]]; then
    tests_ok="true"
    tests_ok_source="override"
  elif release_tests_ok_recorded "$root" "$head"; then
    tests_ok="true"
    tests_ok_source="stamp"
  fi
  local dest
  dest="$(release_provenance_path "$root" "$version")"
  mkdir -p "${dest:h}"
  python3 - "$dest" "$head" "$version" "$sha" "$tests_ok" "$app_commit" "$app_version" "$tests_ok_source" "$app_sha256" <<'PY'
import json, sys
path, commit, version, sha, tests_ok, app_commit, app_version, tests_ok_source, app_sha256 = sys.argv[1:10]
obj = {
    "commit": commit,
    "version": version,
    "dmg_sha256": sha,
    "tests_ok": tests_ok == "true",
    "app_commit": app_commit,
    "app_version": app_version,
    "tests_ok_source": tests_ok_source,
}
if app_sha256:
    obj["app_sha256"] = app_sha256
with open(path, "w") as fh:
    json.dump(obj, fh, indent=2)
    fh.write("\n")
PY
}

# Manifest must match captured HEAD, Info.plist version, live DMG SHA-256,
# a test-ok record, and the packaged-app origin from the receipt.
require_release_provenance() {
  local provenance_file="${1-}"
  local dmg="${2-}"
  local head="${3-}"
  local version="${4-}"
  local root="${5:-.}"

  if [[ ! -f "$provenance_file" ]]; then
    print -r -- "Missing provenance record $provenance_file. Refusing to upload an unattested DMG." >&2
    return 1
  fi
  if [[ ! -f "$dmg" ]]; then
    print -r -- "Missing $dmg; cannot verify provenance." >&2
    return 1
  fi

  require_release_tests_ok "$root" "$head" || return 1

  local p_commit p_version p_sha p_tests p_app_commit p_app_version live
  p_commit="$(provenance_json_field "$provenance_file" commit)" || return 1
  p_version="$(provenance_json_field "$provenance_file" version)" || return 1
  p_sha="$(provenance_json_field "$provenance_file" dmg_sha256)" || return 1
  p_tests="$(provenance_json_field "$provenance_file" tests_ok)" || return 1
  p_app_commit="$(provenance_json_field "$provenance_file" app_commit)" || return 1
  p_app_version="$(provenance_json_field "$provenance_file" app_version)" || return 1

  if [[ "$p_commit" != "$head" ]]; then
    print -r -- "Provenance commit $p_commit does not match HEAD $head. Refusing leftover DMG from another commit." >&2
    return 1
  fi
  if [[ "$p_version" != "$version" ]]; then
    print -r -- "Provenance version $p_version does not match Info.plist $version." >&2
    return 1
  fi
  if [[ -z "$p_app_commit" || -z "$p_app_version" ]]; then
    print -r -- "Provenance is missing verified app origin (app_commit/app_version). Refusing a DMG attested only by checkout + hash." >&2
    return 1
  fi
  if [[ "$p_app_commit" != "$head" ]]; then
    print -r -- "Provenance app_commit $p_app_commit does not match HEAD $head." >&2
    return 1
  fi
  if [[ "$p_app_version" != "$version" ]]; then
    print -r -- "Provenance app_version $p_app_version does not match Info.plist $version." >&2
    return 1
  fi
  live="$(dmg_sha256 "$dmg")" || return 1
  if [[ "$p_sha" != "$live" ]]; then
    print -r -- "Provenance SHA-256 $p_sha does not match live DMG $live." >&2
    return 1
  fi
  if [[ "$p_tests" != "true" ]]; then
    print -r -- "Provenance is missing a test-ok record. Run: make test && make production-dmg" >&2
    return 1
  fi
  return 0
}

# Peel a GitHub git-ref object to a commit SHA. No network.
# $1 = object.type (commit | tag), $2 = object.sha, $3 = peeled commit sha when type is tag.
resolve_tag_commit() {
  local type="${1-}"
  local sha="${2-}"
  local peeled="${3-}"
  case "$type" in
    commit)
      if [[ -z "$sha" ]]; then
        print -r -- "Cannot resolve tag commit: lightweight tag has an empty SHA." >&2
        return 1
      fi
      print -r -- "$sha"
      return 0
      ;;
    tag)
      if [[ -z "$peeled" ]]; then
        print -r -- "Cannot resolve tag commit: annotated tag did not peel to a commit." >&2
        return 1
      fi
      print -r -- "$peeled"
      return 0
      ;;
    *)
      print -r -- "Cannot resolve tag commit: missing or unknown git ref object type (${type:-empty})." >&2
      return 1
      ;;
  esac
}
