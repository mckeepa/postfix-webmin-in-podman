#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="postfix-webmin:local"
CONTAINER_NAME="postfix-webmin"
UNIT_NAME="postfix-webmin"
SERVICE_USER="postfix-webmin"
SOURCE_USER="$(id -un)"
SERVICE_HOME="/var/lib/postfix-webmin"
SERVICE_BUILD_DIR="$SERVICE_HOME/build-context"
MIGRATION_MARKER="$SERVICE_HOME/.legacy-volume-migration-complete"
SERVICE_UID=""
SERVICE_GROUP=""
SERVICE_RUNTIME_DIR=""
QUADLET_DIR="$SERVICE_HOME/.config/containers/systemd"
QUADLET_FILE="$QUADLET_DIR/$UNIT_NAME.container"
WEBMIN_BIND_ADDRESS="${WEBMIN_BIND_ADDRESS:-127.0.0.1}"
SMTP_BIND_ADDRESS="${SMTP_BIND_ADDRESS:-127.0.0.1}"
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

has_subid_range() {
    local file="$1"
    local username="$2"
    awk -F: -v username="$username" -v count="$SUBID_COUNT" \
        '$1 == username && $3 >= count { found = 1 } END { exit !found }' "$file"
}

subid_range_is_free() {
    local file="$1"
    local start="$2"
    local end="$3"
    [[ ! -e "$file" ]] && return 0
    awk -F: -v start="$start" -v end="$end" '
        $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {
            range_start = $2
            range_end = $2 + $3 - 1
            if (start <= range_end && end >= range_start) {
                occupied = 1
            }
        }
        END { exit occupied }
    ' "$file"
}

login_def_setting() {
    awk -v key="$1" '$1 == key { print $2; exit }' /etc/login.defs
}

configure_subordinate_ids() {
    local uid_ready=0
    local gid_ready=0
    local uid_min gid_min uid_max gid_max start end

    has_subid_range /etc/subuid "$SERVICE_USER" && uid_ready=1
    has_subid_range /etc/subgid "$SERVICE_USER" && gid_ready=1
    if (( uid_ready == 1 && gid_ready == 1 )); then
        return
    fi
    if (( uid_ready != gid_ready )); then
        printf 'The service account has only one subordinate ID range configured; fix /etc/subuid and /etc/subgid before continuing.\n' >&2
        exit 1
    fi

    uid_min="$(login_def_setting SUB_UID_MIN)"
    gid_min="$(login_def_setting SUB_GID_MIN)"
    uid_max="$(login_def_setting SUB_UID_MAX)"
    gid_max="$(login_def_setting SUB_GID_MAX)"
    uid_min="${uid_min:-100000}"
    gid_min="${gid_min:-100000}"
    uid_max="${uid_max:-600100000}"
    gid_max="${gid_max:-600100000}"

    if ! [[ "$uid_min$gid_min$uid_max$gid_max" =~ ^[0-9]+$ ]]; then
        printf 'Could not determine subordinate UID/GID allocation ranges from /etc/login.defs.\n' >&2
        exit 1
    fi

    start="$uid_min"
    (( gid_min > start )) && start="$gid_min"
    for (( ; start + SUBID_COUNT - 1 <= uid_max && start + SUBID_COUNT - 1 <= gid_max; start += SUBID_COUNT )); do
        end=$((start + SUBID_COUNT - 1))
        if subid_range_is_free /etc/subuid "$start" "$end" &&
            subid_range_is_free /etc/subgid "$start" "$end"; then
            sudo usermod --add-subuids "$start-$end" --add-subgids "$start-$end" "$SERVICE_USER"
            printf 'Configured subordinate UID/GID range %s-%s for %s.\n' "$start" "$end" "$SERVICE_USER"
            return
        fi
    done

    printf 'Could not find a free subordinate UID/GID range of %s IDs for %s.\n' "$SUBID_COUNT" "$SERVICE_USER" >&2
    exit 1
}

if (( EUID == 0 )); then
    printf 'Run this script as an administrator account, not with sudo. It creates and configures the locked %s service account.\n' "$SERVICE_USER" >&2
    exit 1
fi

if [[ ! -t 0 && "$UPDATE_EXISTING" != 1 ]]; then
    printf 'Run a new installation from an interactive terminal.\n' >&2
    exit 1
fi

if [[ ! -r /etc/os-release ]] || ! grep -Eq '^(ID|ID_LIKE)=.*(rocky|rhel|fedora|centos)' /etc/os-release; then
    printf 'This setup script requires a DNF-based RHEL-family host.\n' >&2
    exit 1
fi

if ! command -v dnf >/dev/null 2>&1; then
    printf 'dnf is not installed; cannot install Podman on this host.\n' >&2
    exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
    printf 'sudo is required to install Podman and configure subordinate IDs.\n' >&2
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1 || ! command -v loginctl >/dev/null 2>&1; then
    printf 'systemd and loginctl are required for rootless startup at boot.\n' >&2
    exit 1
fi

if ! rpm -q podman shadow-utils-subid slirp4netns fuse-overlayfs >/dev/null 2>&1; then
    sudo dnf install -y podman shadow-utils-subid slirp4netns fuse-overlayfs
fi

if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    sudo useradd --user-group --create-home \
        --home-dir "$SERVICE_HOME" --shell /sbin/nologin "$SERVICE_USER"
else
    SERVICE_ACCOUNT="$(getent passwd "$SERVICE_USER")"
    IFS=: read -r _ _ _ _ _ ACCOUNT_HOME ACCOUNT_SHELL <<< "$SERVICE_ACCOUNT"
    if [[ "$ACCOUNT_HOME" != "$SERVICE_HOME" ||
        ( "$ACCOUNT_SHELL" != /sbin/nologin && "$ACCOUNT_SHELL" != /usr/sbin/nologin ) ]]; then
        printf 'Existing %s account must use home %s and a nologin shell; refusing to change it.\n' "$SERVICE_USER" "$SERVICE_HOME" >&2
        exit 1
    fi
fi
sudo passwd --lock "$SERVICE_USER" >/dev/null
SERVICE_UID="$(id -u "$SERVICE_USER")"
SERVICE_GROUP="$(id -gn "$SERVICE_USER")"
SERVICE_RUNTIME_DIR="/run/user/$SERVICE_UID"
if [[ "$(id -Gn "$SERVICE_USER")" != "$SERVICE_GROUP" ]]; then
    printf 'The %s service account must not have supplementary group memberships; remove them before continuing.\n' "$SERVICE_USER" >&2
    exit 1
fi
sudo chown "$SERVICE_USER:$SERVICE_GROUP" "$SERVICE_HOME"
sudo chmod 0700 "$SERVICE_HOME"

configure_subordinate_ids
sudo loginctl enable-linger "$SERVICE_USER"

USER_MANAGER_READY=0
for _ in {1..30}; do
    if as_service_user test -S "$SERVICE_RUNTIME_DIR/bus" &&
        as_service_systemctl show-environment >/dev/null 2>&1; then
        USER_MANAGER_READY=1
        break
    fi
    sleep 1
done
if (( USER_MANAGER_READY == 0 )); then
    printf 'The systemd user manager or D-Bus socket did not become available for %s.\n' "$SERVICE_USER" >&2
    printf 'Check loginctl show-user %s -p Linger and systemctl status user@%s.service.\n' \
        "$SERVICE_USER" "$SERVICE_UID" >&2
    exit 1
fi

PODMAN_ROOTLESS="$(as_service_user podman info --format '{{.Host.Security.Rootless}}')" || {
    printf 'Could not query Podman as service account %s; see the error above.\n' "$SERVICE_USER" >&2
    exit 1
}
if [[ "$PODMAN_ROOTLESS" != true ]]; then
    printf 'Podman reports rootless mode as "%s" for service account %s; refusing to continue.\n' \
        "$PODMAN_ROOTLESS" "$SERVICE_USER" >&2
    exit 1
fi

if ! as_service_user podman unshare cat /proc/self/uid_map |
    awk -v count="$SUBID_COUNT" '$1 != 0 && $3 >= count { found = 1 } END { exit !found }'; then
    printf 'Rootless Podman does not have a usable subordinate UID mapping for %s.\n' "$SERVICE_USER" >&2
    printf 'Check /etc/subuid and retry after correcting the mapping.\n' >&2
    exit 1
fi

if ! as_service_user podman unshare cat /proc/self/gid_map |
    awk -v count="$SUBID_COUNT" '$1 != 0 && $3 >= count { found = 1 } END { exit !found }'; then
    printf 'Rootless Podman does not have a usable subordinate GID mapping for %s.\n' "$SERVICE_USER" >&2
    printf 'Check /etc/subgid and retry after correcting the mapping.\n' >&2
    exit 1
fi

LEGACY_CONTAINER=0
LEGACY_VOLUME_COUNT=0
for volume in "${VOLUMES[@]}"; do
    if podman volume exists "$volume"; then
        ((LEGACY_VOLUME_COUNT += 1))
    fi
done
if podman container exists "$CONTAINER_NAME"; then
    LEGACY_CONTAINER=1
fi

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

if (( LEGACY_CONTAINER == 1 || LEGACY_VOLUME_COUNT > 0 )); then
    if as_service_user test -f "$MIGRATION_MARKER"; then
        if (( SERVICE_VOLUME_COUNT != ${#VOLUMES[@]} )); then
            printf 'A previous migration marker exists but the service account does not have all five migrated volumes. Restore or repair them before continuing.\n' >&2
            exit 1
        fi
        if (( LEGACY_CONTAINER == 1 )) &&
            [[ "$(podman inspect --format '{{.State.Running}}' "$CONTAINER_NAME")" == true ]]; then
            printf 'The original container under %s is running alongside the service-account data. Stop it before updating.\n' "$SOURCE_USER" >&2
            exit 1
        fi
        MIGRATE_LEGACY=0
    else
        if (( LEGACY_VOLUME_COUNT != ${#VOLUMES[@]} )); then
            printf 'The invoking account has a partial set of existing mail volumes. Back up and resolve those volumes before migration; no data was changed.\n' >&2
            exit 1
        fi
        if (( SERVICE_VOLUME_COUNT > 0 || SERVICE_CONTAINER == 1 )); then
            printf 'Both the invoking account and %s have Podman data. Refusing to merge or overwrite either installation.\n' "$SERVICE_USER" >&2
            exit 1
        fi
        if [[ "$UPDATE_EXISTING" != 1 ]]; then
            printf 'Existing Postfix/Webmin data was found under the invoking account. Rerun with UPDATE_EXISTING=1 to migrate its five named volumes to %s.\n' "$SERVICE_USER" >&2
            exit 1
        fi
        MIGRATE_LEGACY=1
    fi
else
    MIGRATE_LEGACY=0
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

sudo install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0750 "$SERVICE_BUILD_DIR"
sudo install -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0644 \
    "$SCRIPT_DIR/Containerfile" "$SERVICE_BUILD_DIR/Containerfile"
sudo install -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0644 \
    "$SCRIPT_DIR/container-entrypoint.sh" "$SERVICE_BUILD_DIR/container-entrypoint.sh"
as_service_user podman build --build-arg "WEBMIN_VERSION=$WEBMIN_VERSION" \
    --tag "$IMAGE_NAME" "$SERVICE_BUILD_DIR"

if (( EXISTING_SERVICE_DATA == 0 && MIGRATE_LEGACY == 0 )); then
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

if (( EXISTING_SERVICE_DATA == 1 )); then
    if as_service_systemctl is-active --quiet "$UNIT_NAME.service"; then
        as_service_systemctl stop "$UNIT_NAME.service"
    fi
    if as_service_user podman container exists "$CONTAINER_NAME"; then
        as_service_user podman rm --force "$CONTAINER_NAME"
    fi
fi

if (( MIGRATE_LEGACY == 1 )); then
    LEGACY_QUADLET="$HOME/.config/containers/systemd/$UNIT_NAME.container"
    LEGACY_SERVICE_WAS_ACTIVE=0
    LEGACY_CONTAINER_WAS_RUNNING=0
    if systemctl --user is-active --quiet "$UNIT_NAME.service"; then
        LEGACY_SERVICE_WAS_ACTIVE=1
        systemctl --user stop "$UNIT_NAME.service"
    fi
    if podman container exists "$CONTAINER_NAME"; then
        if [[ "$(podman inspect --format '{{.State.Running}}' "$CONTAINER_NAME")" == true ]]; then
            LEGACY_CONTAINER_WAS_RUNNING=1
            podman stop --time 30 "$CONTAINER_NAME" >/dev/null
        fi
    fi

    MIGRATION_IN_PROGRESS=1
    MIGRATION_CREATED_VOLUMES=()
    cleanup_failed_migration() {
        local status=$?
        trap - EXIT
        if (( MIGRATION_IN_PROGRESS == 1 )); then
            as_service_user rm -f "$MIGRATION_MARKER" >/dev/null 2>&1 || true
            for volume in "${MIGRATION_CREATED_VOLUMES[@]}"; do
                if ! as_service_user podman volume rm --force "$volume" >/dev/null; then
                    printf 'Could not remove incomplete migrated volume %s; the original volumes remain intact.\n' "$volume" >&2
                fi
            done
            if (( LEGACY_SERVICE_WAS_ACTIVE == 1 )); then
                systemctl --user start "$UNIT_NAME.service" >/dev/null ||
                    printf 'Could not restart the original user service; start it manually after reviewing the migration error.\n' >&2
            elif (( LEGACY_CONTAINER_WAS_RUNNING == 1 )) &&
                podman container exists "$CONTAINER_NAME"; then
                podman start "$CONTAINER_NAME" >/dev/null ||
                    printf 'Could not restart the original container; start it manually after reviewing the migration error.\n' >&2
            fi
        fi
        exit "$status"
    }
    trap cleanup_failed_migration EXIT

    for volume in "${VOLUMES[@]}"; do
        as_service_user podman volume create "$volume" >/dev/null
        MIGRATION_CREATED_VOLUMES+=("$volume")
        podman volume export "$volume" |
            as_service_user podman volume import "$volume" -
    done
    printf '%s\n' "$SOURCE_USER" | as_service_user tee "$MIGRATION_MARKER" >/dev/null
    if [[ -f "$LEGACY_QUADLET" ]]; then
        mv -- "$LEGACY_QUADLET" \
            "$LEGACY_QUADLET.migrated.$(date +%Y%m%d-%H%M%S)"
        if systemctl --user show-environment >/dev/null 2>&1; then
            systemctl --user daemon-reload
        fi
    fi
    MIGRATION_IN_PROGRESS=0
    trap - EXIT
    printf 'Migrated the five named volumes from the invoking account; its original volumes are retained for rollback.\n'
else
    for volume in "${VOLUMES[@]}"; do
        as_service_user podman volume create --ignore "$volume" >/dev/null
    done
fi

as_service_user install -d -m 0700 "$QUADLET_DIR"
as_service_user tee "$QUADLET_FILE" >/dev/null <<EOF
[Unit]
Description=Postfix and Webmin rootless container

[Container]
Image=localhost/$IMAGE_NAME
ContainerName=$CONTAINER_NAME
RunInit=true
PublishPort=${WEBMIN_BIND_ADDRESS}:10000:10000
PublishPort=${SMTP_BIND_ADDRESS}:2525:25
HealthCmd=/usr/sbin/postfix status && curl -kfsS https://127.0.0.1:10000/ >/dev/null
HealthInterval=30s
HealthTimeout=5s
HealthRetries=3
Volume=postfix-webmin-postfix-config:/etc/postfix:Z
Volume=postfix-webmin-postfix-queue:/var/spool/postfix:Z
Volume=postfix-webmin-mail:/var/mail:Z
Volume=postfix-webmin-webmin-config:/etc/webmin:Z
Volume=postfix-webmin-webmin-state:/var/webmin:Z

[Service]
Restart=on-failure
RestartSec=10
TimeoutStartSec=300

[Install]
WantedBy=default.target
EOF

if (( EXISTING_SERVICE_DATA == 0 && MIGRATE_LEGACY == 0 )); then
    printf '%s\n' "$WEBMIN_PASSWORD" |
        as_service_user podman run --rm --interactive --network none \
            --volume postfix-webmin-webmin-config:/etc/webmin:Z \
            --volume postfix-webmin-webmin-state:/var/webmin:Z \
            --entrypoint /bin/sh "localhost/$IMAGE_NAME" -c '
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
