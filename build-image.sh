#!/usr/bin/env bash
# Build the local image in the service account's rootless Podman store.
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/scripts/common.sh"
require_platform

# Copy only build inputs into a context readable by the private service account.
sudo install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0750 "$SERVICE_BUILD_DIR"
sudo install -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0644 \
    "$PROJECT_DIR/Containerfile" "$SERVICE_BUILD_DIR/Containerfile"
sudo install -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0644 \
    "$PROJECT_DIR/container-entrypoint.sh" "$SERVICE_BUILD_DIR/container-entrypoint.sh"
as_service_user podman build --build-arg "WEBMIN_VERSION=$WEBMIN_VERSION" \
    --tag "$IMAGE_NAME" "$SERVICE_BUILD_DIR"
printf 'Image built: %s. The running service was not changed. Next: ./deploy.sh\n' "$IMAGE_NAME"
