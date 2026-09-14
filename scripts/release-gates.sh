# Sourced by package-dmg.sh, github-release.sh, and scripts/test-release-gates.sh.
# Helpers only — no packaging, notarization, or GitHub side effects.

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
    print -r -- "GitHub release tag commit $tag_commit does not match HEAD $head. Refusing to attach a DMG to a tag that points elsewhere." >&2
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
