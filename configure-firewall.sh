#!/usr/bin/env bash
# Opt-in host firewall configuration for Webmin; installation never runs this.
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/scripts/common.sh"

usage() {
    printf 'Usage: %s --zone ZONE --source all|IPv4|IPv4/CIDR\n' "$0"
}

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

ZONE=""
SOURCE=""
while (( $# > 0 )); do
    case "$1" in
        --zone|--source)
            [[ $# -ge 2 && -n "$2" ]] || fail "$(usage)"
            if [[ "$1" == --zone ]]; then
                ZONE="$2"
            else
                SOURCE="$2"
            fi
            shift 2
            ;;
        --help) usage; exit 0 ;;
        *) fail "$(usage)" ;;
    esac
done
[[ -n "$ZONE" && -n "$SOURCE" ]] || fail "$(usage)"

RULE=""
ACCESS="port=10000/tcp"
if [[ "$SOURCE" != all ]]; then
    [[ "$SOURCE" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] ||
        fail 'Source must be all, an IPv4 address, or an IPv4 CIDR range.'
    IFS=. read -r -a OCTETS <<< "${SOURCE%%/*}"
    for octet in "${OCTETS[@]}"; do
        if [[ "$octet" != 0 && "$octet" == 0* ]] || (( 10#$octet > 255 )); then
            fail "Invalid IPv4 source address: $SOURCE"
        fi
    done
    if [[ "$SOURCE" == */* ]]; then
        PREFIX="${SOURCE##*/}"
        if [[ "$PREFIX" != 0 && "$PREFIX" == 0* ]] || (( 10#$PREFIX > 32 )); then
            fail "Invalid IPv4 CIDR prefix: $SOURCE"
        fi
    fi
    RULE="rule family=\"ipv4\" source address=\"$SOURCE\" port port=\"10000\" protocol=\"tcp\" accept"
    ACCESS="rich-rule=$RULE"
else
    printf 'WARNING: Allowing Webmin TCP/10000 from all sources in zone %s (IPv4 and IPv6).\n' "$ZONE" >&2
fi

require_administrator
command -v firewall-cmd >/dev/null 2>&1 ||
    fail 'firewall-cmd is required. Install and configure firewalld before running this script.'
firewall() {
    if sudo firewall-cmd "$@"; then
        return 0
    else
        local status=$?
        printf 'firewall-cmd failed (exit %s): %s\n' "$status" "$*" >&2
        return "$status"
    fi
}
firewall --state

# Read both configurations before modifying either; do not reload unrelated rules.
declare -A RULES_BY_SCOPE
for scope in runtime permanent; do
    OPTIONS=()
    [[ "$scope" == runtime ]] || OPTIONS+=(--permanent)
    ZONES="$(firewall "${OPTIONS[@]}" --get-zones)"
    [[ " $ZONES " == *" $ZONE "* ]] ||
        fail "Zone $ZONE does not exist in the $scope configuration."
    RULES_BY_SCOPE[$scope]="$(firewall "${OPTIONS[@]}" --zone="$ZONE" --list-rich-rules)"
done

for scope in runtime permanent; do
    OPTIONS=()
    [[ "$scope" == runtime ]] || OPTIONS+=(--permanent)
    OPTIONS+=(--zone="$ZONE")
    firewall "${OPTIONS[@]}" "--add-$ACCESS"
    if [[ "$SOURCE" != all ]]; then
        # A missing port is expected; other query failures must stop the script.
        if sudo firewall-cmd "${OPTIONS[@]}" --query-port=10000/tcp; then
            firewall "${OPTIONS[@]}" --remove-port=10000/tcp
        else
            status=$?
            if (( status != 1 )); then
                printf 'Could not query Webmin port in the %s configuration (exit %s).\n' "$scope" "$status" >&2
                exit "$status"
            fi
        fi
    fi
    while IFS= read -r old_rule; do
        if [[ "$old_rule" =~ ^rule\ family=\"ipv4\"\ source\ address=\"[0-9./]+\"\ port\ port=\"10000\"\ protocol=\"tcp\"\ accept$ ]] &&
            [[ "$old_rule" != "$RULE" ]]; then
            firewall "${OPTIONS[@]}" --remove-rich-rule="$old_rule"
        fi
    done <<< "${RULES_BY_SCOPE[$scope]}"
    firewall "${OPTIONS[@]}" "--query-$ACCESS"
done

printf 'Webmin TCP/10000 configured for source %s in zone %s (runtime and permanent).\n' "$SOURCE" "$ZONE"
printf 'SMTP and container bindings were not changed. No firewall reload was performed.\n'
printf 'Review other services, custom rules, and zones: they may independently allow access.\n'
