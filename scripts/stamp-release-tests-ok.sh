#!/bin/zsh
# Stamp dist/.release-tests-ok with the commit captured before `make test`.
# Refuses if HEAD moved during the test run.
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/release-gates.sh"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
stamp_release_tests_ok_if_head_unchanged "$ROOT" "${1-}"
