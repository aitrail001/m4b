#!/bin/zsh
# Fixture for remove_legacy_site_dmgs in scripts/sync-public-release.sh.
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/sync-public-release.sh"

fail() {
  print -r -- "FAIL: $1" >&2
  exit 1
}

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/m4b-sync-glob.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

# no downloads directory → cleanup succeeds
mkdir -p "$ROOT/site"
remove_legacy_site_dmgs "$ROOT"
[[ ! -e "$ROOT/site/downloads" ]] || fail "must not create site/downloads"

# empty downloads dir → succeeds
mkdir -p "$ROOT/site/downloads"
remove_legacy_site_dmgs "$ROOT"
[[ -d "$ROOT/site/downloads" ]] || fail "empty site/downloads should remain"

# matching AudiobookBinder-1.0.0.dmg is deleted; other.dmg is not
: > "$ROOT/site/downloads/AudiobookBinder-1.0.0.dmg"
: > "$ROOT/site/downloads/other.dmg"
remove_legacy_site_dmgs "$ROOT"
[[ ! -e "$ROOT/site/downloads/AudiobookBinder-1.0.0.dmg" ]] || fail "matching dmg should be deleted"
[[ -f "$ROOT/site/downloads/other.dmg" ]] || fail "other.dmg must not be deleted"

# repeat after successful cleanup succeeds
remove_legacy_site_dmgs "$ROOT"
[[ -f "$ROOT/site/downloads/other.dmg" ]] || fail "other.dmg must remain after repeat cleanup"

print -r -- "ok: sync glob cleanup"
