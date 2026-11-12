#!/usr/bin/env bash
# Pull a published image into the service account's store, then deploy it.
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/scripts/common.sh"

if [[ $# -gt 1 ]]; then
    printf 'Usage: %s [PUBLISHED_IMAGE]\n' "$0" >&2
    exit 1
fi
PUBLISHED_IMAGE="${1:-docker.io/mckeepa/postfix-webmin:latest}"
require_platform

if ! as_service_user podman pull -- "$PUBLISHED_IMAGE"; then
    printf 'Could not pull %s. Check the image name, registry access, and network connection. Deployment was not started.\n' "$PUBLISHED_IMAGE" >&2
    exit 1
fi
if ! as_service_user podman tag -- "$PUBLISHED_IMAGE" "$IMAGE_NAME"; then
    printf 'Could not tag %s as %s. Deployment was not started.\n' "$PUBLISHED_IMAGE" "$IMAGE_NAME" >&2
    exit 1
fi
exec "$PROJECT_DIR/deploy.sh"
