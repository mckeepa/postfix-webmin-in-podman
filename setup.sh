#!/usr/bin/env bash
# Run all installation stages; each stage can also be run independently.
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/platform-setup.sh"
"$SCRIPT_DIR/build-image.sh"
"$SCRIPT_DIR/deploy.sh"
