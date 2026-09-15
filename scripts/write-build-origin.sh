#!/bin/zsh
# Record compile origin after `swift build -c release` (`make build`).
# Reads the pre-compile intent; never downgrades same-hash dirty→clean.
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/release-gates.sh"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
write_build_origin "$ROOT" "$COMMIT"
