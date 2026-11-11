#!/usr/bin/env bash
# Shared host-side settings and checks; source this file from the stage scripts.

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_NAME="localhost/postfix-webmin:local"
CONTAINER_NAME="postfix-webmin"
UNIT_NAME="postfix-webmin"
SERVICE_USER="postfix-webmin"
SERVICE_HOME="/var/lib/postfix-webmin"
SERVICE_BUILD_DIR="$SERVICE_HOME/build-context"
SERVICE_UID=""
SERVICE_GROUP=""
SERVICE_RUNTIME_DIR=""
QUADLET_DIR="$SERVICE_HOME/.config/containers/systemd"
QUADLET_FILE="$QUADLET_DIR/$UNIT_NAME.container"
WEBMIN_BIND_ADDRESS="${WEBMIN_BIND_ADDRESS:-127.0.0.1}"
SMTP_BIND_ADDRESS="${SMTP_BIND_ADDRESS:-127.0.0.1}"
WEBMIN_TLS_DIR="${WEBMIN_TLS_DIR:-}"
WEBMIN_VERSION="${WEBMIN_VERSION:-2.670-1}"
UPDATE_EXISTING="${UPDATE_EXISTING:-0}"
SUBID_COUNT=65536
VOLUMES=(
    postfix-webmin-postfix-config
    postfix-webmin-postfix-queue
    postfix-webmin-mail
    postfix-webmin-webmin-config
    postfix-webmin-webmin-state
)

as_service_user() {
    # Keep Podman's storage, working directory, and user bus in the service account.
    sudo -u "$SERVICE_USER" env --chdir="$SERVICE_HOME" \
        HOME="$SERVICE_HOME" \
        PWD="$SERVICE_HOME" \
        XDG_RUNTIME_DIR="$SERVICE_RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$SERVICE_RUNTIME_DIR/bus" \
        "$@"
}

as_service_systemctl() {
    as_service_user systemctl --user "$@"
}

require_administrator() {
    if (( EUID == 0 )); then
        printf 'Run this script as an administrator account, not with sudo.\n' >&2
        exit 1
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        printf 'sudo is required to manage the dedicated service account.\n' >&2
        exit 1
    fi
}

load_service_account() {
    local account account_home account_shell
    if ! account="$(getent passwd "$SERVICE_USER")"; then
        printf 'Service account %s is missing. Run ./platform-setup.sh first.\n' "$SERVICE_USER" >&2
        exit 1
    fi
    IFS=: read -r _ _ _ _ _ account_home account_shell <<< "$account"
    if [[ "$account_home" != "$SERVICE_HOME" ||
        ( "$account_shell" != /sbin/nologin && "$account_shell" != /usr/sbin/nologin ) ]]; then
        printf 'Existing %s account must use home %s and a nologin shell; refusing to change it.\n' "$SERVICE_USER" "$SERVICE_HOME" >&2
        exit 1
    fi
    SERVICE_UID="$(id -u "$SERVICE_USER")"
    SERVICE_GROUP="$(id -gn "$SERVICE_USER")"
    SERVICE_RUNTIME_DIR="/run/user/$SERVICE_UID"
    if [[ "$(id -Gn "$SERVICE_USER")" != "$SERVICE_GROUP" ]]; then
        printf 'The %s service account must not have supplementary group memberships; remove them before continuing.\n' "$SERVICE_USER" >&2
        exit 1
    fi
}

verify_rootless_runtime() {
    local rootless
    rootless="$(as_service_user podman info --format '{{.Host.Security.Rootless}}')" || {
        printf 'Could not query Podman as service account %s; see the error above.\n' "$SERVICE_USER" >&2
        exit 1
    }
    if [[ "$rootless" != true ]]; then
        printf 'Podman reports rootless mode as "%s" for service account %s; refusing to continue.\n' \
            "$rootless" "$SERVICE_USER" >&2
        exit 1
    fi
    if ! as_service_user podman unshare cat /proc/self/uid_map |
        awk -v count="$SUBID_COUNT" '$1 != 0 && $3 >= count { found = 1 } END { exit !found }'; then
        printf 'Rootless Podman has no usable subordinate UID mapping for %s. Check /etc/subuid and run ./platform-setup.sh.\n' "$SERVICE_USER" >&2
        exit 1
    fi
    if ! as_service_user podman unshare cat /proc/self/gid_map |
        awk -v count="$SUBID_COUNT" '$1 != 0 && $3 >= count { found = 1 } END { exit !found }'; then
        printf 'Rootless Podman has no usable subordinate GID mapping for %s. Check /etc/subgid and run ./platform-setup.sh.\n' "$SERVICE_USER" >&2
        exit 1
    fi
}

require_platform() {
    local command
    require_administrator
    for command in podman systemctl loginctl; do
        if ! command -v "$command" >/dev/null 2>&1; then
            printf '%s is required. Run ./platform-setup.sh first.\n' "$command" >&2
            exit 1
        fi
    done
    load_service_account
    if ! as_service_user test -S "$SERVICE_RUNTIME_DIR/bus" ||
        ! as_service_systemctl show-environment >/dev/null; then
        printf 'The service account user manager is unavailable. Run ./platform-setup.sh first.\n' >&2
        exit 1
    fi
    if [[ "$(loginctl show-user "$SERVICE_USER" -p Linger --value)" != yes ]]; then
        printf 'Lingering is required for boot startup. Run ./platform-setup.sh first.\n' >&2
        exit 1
    fi
    verify_rootless_runtime
}
