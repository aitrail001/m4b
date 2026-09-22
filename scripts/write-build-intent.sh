#!/bin/zsh
# Record compile intent before the Xcode Release build (`make build`).
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/release-gates.sh"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
write_build_intent "$ROOT" "$COMMIT"
