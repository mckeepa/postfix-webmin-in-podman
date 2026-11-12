#!/usr/bin/env bash
# Publish the built image from the service account's rootless Podman store.
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/scripts/common.sh"

DESTINATION="${1:-}"
if [[ $# == 0 && -n "$DOCKERHUB_NAMESPACE" ]]; then
    DESTINATION="docker.io/$DOCKERHUB_NAMESPACE/postfix-webmin:latest"
fi
if [[ $# -gt 1 ]] ||
    ! [[ "$DESTINATION" =~ ^docker\.io/[a-z0-9][a-z0-9_-]*/[a-z0-9]+([._-]+[a-z0-9]+)*:[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ ]]; then
    printf 'Usage: %s [docker.io/NAMESPACE/REPOSITORY:TAG]\nSet DOCKERHUB_NAMESPACE to push postfix-webmin:latest without an argument.\n' "$0" >&2
    exit 1
fi
require_platform

if ! as_service_user podman image exists "$IMAGE_NAME"; then
    printf 'Image %s is unavailable. Run ./build-image.sh first.\n' "$IMAGE_NAME" >&2
    exit 1
fi

printf 'Log in to DockerHub; use a DockerHub access token with push permission as the password.\n'
as_service_user podman login docker.io
as_service_user podman push "$IMAGE_NAME" "docker://$DESTINATION"
printf 'Image published: %s. The running service and its volumes were not changed.\n' "$DESTINATION"
