#!/usr/bin/env bash
# Deploy the built image with persistent volumes and a rootless systemd Quadlet.
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/scripts/common.sh"
require_platform

if ! as_service_user podman image exists "$IMAGE_NAME"; then
    printf 'Image %s is unavailable. Run ./build-image.sh first.\n' "$IMAGE_NAME" >&2
    exit 1
fi

WEBMIN_TLS_CONFIG=""
if [[ -n "$WEBMIN_TLS_DIR" ]]; then
    # Keep the host path unambiguous in both Quadlet and Podman volume syntax.
    if ! [[ "$WEBMIN_TLS_DIR" =~ ^/[a-zA-Z0-9_./-]+$ ]]; then
        printf 'WEBMIN_TLS_DIR must be an absolute path using only letters, digits, /, _, ., and -.\n' >&2
        exit 1
    fi
    for file in cert.pem privkey.pem; do
        if ! as_service_user test -r "$WEBMIN_TLS_DIR/$file" ||
            ! as_service_user test -s "$WEBMIN_TLS_DIR/$file"; then
            printf 'TLS file must be readable and non-empty for %s: %s/%s\n' \
                "$SERVICE_USER" "$WEBMIN_TLS_DIR" "$file" >&2
            exit 1
        fi
    done
    WEBMIN_TLS_CONFIG="Volume=$WEBMIN_TLS_DIR:/run/webmin-tls:ro,Z"$'\n'"Environment=WEBMIN_TLS_DIR=/run/webmin-tls"
elif as_service_user test -f "$QUADLET_FILE" &&
    as_service_user grep -qx 'Environment=WEBMIN_TLS_DIR=/run/webmin-tls' "$QUADLET_FILE"; then
    printf 'External TLS is already enabled. Specify WEBMIN_TLS_DIR again; refusing to remove its mount.\n' >&2
    exit 1
else
    printf 'WARNING: WEBMIN_TLS_DIR is unset. Webmin generates a unique self-signed certificate at first startup and reuses it from its persistent volume on later starts. Set WEBMIN_TLS_DIR for CA-issued TLS.\n' >&2
fi

# Render as text, not shell code, before stopping an existing deployment.
QUADLET_TEMPLATE="$PROJECT_DIR/templates/postfix-webmin.container.in"
if [[ ! -r "$QUADLET_TEMPLATE" ]]; then
    printf 'Quadlet template is missing or unreadable: %s\n' "$QUADLET_TEMPLATE" >&2
    exit 1
fi
QUADLET_CONTENT="$(cat -- "$QUADLET_TEMPLATE")"
QUADLET_CONTENT="${QUADLET_CONTENT//@IMAGE_NAME@/$IMAGE_NAME}"
QUADLET_CONTENT="${QUADLET_CONTENT//@CONTAINER_NAME@/$CONTAINER_NAME}"
QUADLET_CONTENT="${QUADLET_CONTENT//@WEBMIN_BIND_ADDRESS@/$WEBMIN_BIND_ADDRESS}"
QUADLET_CONTENT="${QUADLET_CONTENT//@SMTP_BIND_ADDRESS@/$SMTP_BIND_ADDRESS}"
QUADLET_CONTENT="${QUADLET_CONTENT//@WEBMIN_TLS_CONFIG@/$WEBMIN_TLS_CONFIG}"

# Refuse incomplete data sets so an update cannot silently seed missing mail data.
SERVICE_CONTAINER=0
SERVICE_VOLUME_COUNT=0
for volume in "${VOLUMES[@]}"; do
    if as_service_user podman volume exists "$volume"; then
        ((SERVICE_VOLUME_COUNT += 1))
    fi
done
if as_service_user podman container exists "$CONTAINER_NAME"; then
    SERVICE_CONTAINER=1
fi
if (( SERVICE_VOLUME_COUNT > 0 && SERVICE_VOLUME_COUNT != ${#VOLUMES[@]} )); then
    printf 'The %s account has only some of the expected named volumes. Resolve this incomplete installation before continuing.\n' "$SERVICE_USER" >&2
    exit 1
fi
if (( SERVICE_CONTAINER == 1 && SERVICE_VOLUME_COUNT != ${#VOLUMES[@]} )); then
    printf 'The existing %s container does not have all expected named volumes. Refusing to replace it.\n' "$SERVICE_USER" >&2
    exit 1
fi
if (( SERVICE_CONTAINER == 1 || SERVICE_VOLUME_COUNT > 0 )); then
    if [[ "$UPDATE_EXISTING" != 1 ]]; then
        printf 'Existing service-account container data was found. Back it up, then set UPDATE_EXISTING=1 to replace the container while preserving its volumes.\n' >&2
        exit 1
    fi
    EXISTING_SERVICE_DATA=1
else
    EXISTING_SERVICE_DATA=0
fi

if (( EXISTING_SERVICE_DATA == 0 )); then
    if [[ ! -t 0 ]]; then
        printf 'Run a new installation from an interactive terminal to set the Webmin password.\n' >&2
        exit 1
    fi
    read -r -s -p 'Set temporary Webmin root password: ' WEBMIN_PASSWORD
    printf '\n'
    read -r -s -p 'Confirm Webmin root password: ' WEBMIN_PASSWORD_CONFIRM
    printf '\n'
    if [[ -z "$WEBMIN_PASSWORD" || "$WEBMIN_PASSWORD" != "$WEBMIN_PASSWORD_CONFIRM" ]]; then
        printf 'Passwords must be non-empty and match. No container was started.\n' >&2
        unset WEBMIN_PASSWORD WEBMIN_PASSWORD_CONFIRM
        exit 1
    fi
    unset WEBMIN_PASSWORD_CONFIRM
fi

# Replace only the container; its five named volumes retain data and credentials.
if (( EXISTING_SERVICE_DATA == 1 )); then
    if as_service_systemctl is-active --quiet "$UNIT_NAME.service"; then
        as_service_systemctl stop "$UNIT_NAME.service"
    fi
    if as_service_user podman container exists "$CONTAINER_NAME"; then
        as_service_user podman rm --force "$CONTAINER_NAME"
    fi
fi
for volume in "${VOLUMES[@]}"; do
    as_service_user podman volume create --ignore "$volume" >/dev/null
done

# Private SELinux labels allow the replacement container to use the same volumes.
as_service_user install -d -m 0700 "$QUADLET_DIR"
printf '%s\n' "$QUADLET_CONTENT" | as_service_user tee "$QUADLET_FILE" >/dev/null

# Set credentials offline: Webmin's password tool stops and starts its server.
if (( EXISTING_SERVICE_DATA == 0 )); then
    printf '%s\n' "$WEBMIN_PASSWORD" |
        as_service_user podman run --rm --interactive --network none \
            --volume postfix-webmin-webmin-config:/etc/webmin:Z \
            --volume postfix-webmin-webmin-state:/var/webmin:Z \
            --entrypoint /bin/sh "$IMAGE_NAME" -c '
                set -eu
                cp -a /usr/share/postfix-webmin-defaults/webmin/. /etc/webmin/
                IFS= read -r password
                exec /usr/libexec/webmin/changepass.pl /etc/webmin root "$password"
            '
    unset WEBMIN_PASSWORD
fi

as_service_systemctl daemon-reload
if ! as_service_systemctl start "$UNIT_NAME.service"; then
    printf 'Could not start the rootless systemd service. Inspect it with the service-account journal command documented in README.md.\n' >&2
    exit 1
fi

# Confirm HTTPS readiness separately from the periodic container health check.
READY=0
for _ in {1..30}; do
    if as_service_user podman exec "$CONTAINER_NAME" \
        curl -kfsS https://127.0.0.1:10000/ >/dev/null 2>&1; then
        READY=1
        break
    fi
    sleep 1
done
if (( READY == 0 )); then
    printf 'Webmin did not become ready. Inspect the service-account container logs as documented in README.md.\n' >&2
    exit 1
fi
printf '\nContainer started rootless under the locked service account %s (UID %s).\n' "$SERVICE_USER" "$SERVICE_UID"
printf 'Webmin: https://%s:10000\n' "$WEBMIN_BIND_ADDRESS"
printf 'SMTP:   %s:2525\n' "$SMTP_BIND_ADDRESS"
printf 'Persistent Podman volumes are owned by %s under %s.\n' "$SERVICE_USER" "$SERVICE_HOME"
printf 'Rootless systemd service: %s.service (Quadlet in %s)\n' "$UNIT_NAME" "$QUADLET_DIR"
printf 'Lingering is enabled for %s; the service will start after reboot.\n' "$SERVICE_USER"
printf 'Use the service-account commands in README.md to inspect health, status, and logs.\n'
