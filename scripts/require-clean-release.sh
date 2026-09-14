#!/bin/zsh
# Fail-fast dirty-tree gate for `make release` (before test / icon).
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/release-gates.sh"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
require_clean_release_worktree "$ROOT"
