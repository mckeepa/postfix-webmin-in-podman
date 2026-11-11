#!/usr/bin/env bash
# Provision host packages, the locked service account, and rootless boot prerequisites.
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/scripts/common.sh"

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

    # Allocate a matching UID/GID range without overlapping existing accounts.
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

require_administrator
if [[ ! -r /etc/os-release ]] || ! grep -Eq '^(ID|ID_LIKE)=.*(rocky|rhel|fedora|centos)' /etc/os-release; then
    printf 'Platform setup requires a DNF-based RHEL-family host.\n' >&2
    exit 1
fi
if ! command -v dnf >/dev/null 2>&1; then
    printf 'dnf is not installed; cannot install Podman on this host.\n' >&2
    exit 1
fi
if ! command -v systemctl >/dev/null 2>&1 || ! command -v loginctl >/dev/null 2>&1; then
    printf 'systemd and loginctl are required for rootless startup at boot.\n' >&2
    exit 1
fi
if ! rpm -q podman shadow-utils-subid slirp4netns fuse-overlayfs >/dev/null 2>&1; then
    sudo dnf install -y podman shadow-utils-subid slirp4netns fuse-overlayfs
fi

# Validate an existing service identity rather than repurposing another account.
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    sudo useradd --user-group --create-home \
        --home-dir "$SERVICE_HOME" --shell /sbin/nologin "$SERVICE_USER"
fi
load_service_account
sudo passwd --lock "$SERVICE_USER" >/dev/null
sudo chown "$SERVICE_USER:$SERVICE_GROUP" "$SERVICE_HOME"
sudo chmod 0700 "$SERVICE_HOME"
configure_subordinate_ids

# Lingering keeps the user manager available without an interactive login.
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
verify_rootless_runtime
printf 'Platform ready for %s (UID %s). Next: ./build-image.sh\n' "$SERVICE_USER" "$SERVICE_UID"
