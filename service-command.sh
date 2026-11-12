#!/usr/bin/env bash
# Run a management command as the locked rootless service account.
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/scripts/common.sh"

if [[ $# == 0 ]]; then
    printf 'Usage: %s COMMAND [ARGUMENT...]\n' "$0" >&2
    exit 1
fi
require_platform
as_service_user "$@"
