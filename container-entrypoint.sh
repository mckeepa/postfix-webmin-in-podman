#!/bin/sh
# Seed persistent storage, configure Postfix control, and run the mail services.
set -eu

initialize_volume() {
    defaults="$1"
    target="$2"
    mkdir -p "$target"
    # An unreadable volume must fail startup, not be treated as empty.
    entries="$(ls -A "$target")"
    if [ -z "$entries" ]; then
        cp -a "$defaults"/. "$target"/
    fi
}

# Seed only empty volumes; preserve administrator settings and queued mail.
initialize_volume /usr/share/postfix-webmin-defaults/postfix /etc/postfix
initialize_volume /usr/share/postfix-webmin-defaults/postfix-queue /var/spool/postfix
initialize_volume /usr/share/postfix-webmin-defaults/mail /var/mail
initialize_volume /usr/share/postfix-webmin-defaults/webmin /etc/webmin
initialize_volume /usr/share/postfix-webmin-defaults/webmin-state /var/webmin

# Use direct Postfix control because systemd runs only on the host.
sed -i '/^\(start_cmd\|stop_cmd\|reload_cmd\)=/d' /etc/webmin/postfix/config
cat >> /etc/webmin/postfix/config <<'EOF'
start_cmd=/usr/sbin/postfix start
stop_cmd=/usr/sbin/postfix stop
reload_cmd=/usr/sbin/postfix reload
EOF

generate_self_signed_certificate() (
    temp_dir="$(mktemp -d)"
    temp_pem="$(mktemp /etc/webmin/.miniserv.pem.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"; rm -f -- "$temp_pem"' EXIT
    openssl req -x509 -newkey rsa:3072 -nodes -days 3650 \
        -keyout "$temp_dir/key.pem" -out "$temp_dir/cert.pem" \
        -subj '/CN=postfix-webmin'
    cat "$temp_dir/key.pem" "$temp_dir/cert.pem" > "$temp_pem"
    chmod 0600 "$temp_pem"
    mv -f -- "$temp_pem" /etc/webmin/miniserv.pem
    : > /etc/webmin/.postfix-webmin-self-signed
    chmod 0600 /etc/webmin/.postfix-webmin-self-signed
)

if [ -n "${WEBMIN_TLS_DIR:-}" ]; then
    for file in cert.pem privkey.pem; do
        if [ ! -r "$WEBMIN_TLS_DIR/$file" ] || [ ! -s "$WEBMIN_TLS_DIR/$file" ]; then
            printf 'Webmin TLS file is missing, empty, or unreadable: %s/%s\n' "$WEBMIN_TLS_DIR" "$file" >&2
            exit 1
        fi
    done
    openssl x509 -in "$WEBMIN_TLS_DIR/cert.pem" -noout -checkend 0
    cert_public_key="$(openssl x509 -in "$WEBMIN_TLS_DIR/cert.pem" -pubkey -noout)"
    key_public_key="$(openssl pkey -in "$WEBMIN_TLS_DIR/privkey.pem" -passin pass: -pubout)"
    if [ "$cert_public_key" != "$key_public_key" ]; then
        printf 'Webmin TLS certificate and private key do not match.\n' >&2
        exit 1
    fi
    extra_cas=none
    if [ -e "$WEBMIN_TLS_DIR/chain.pem" ]; then
        if [ ! -r "$WEBMIN_TLS_DIR/chain.pem" ] || [ ! -s "$WEBMIN_TLS_DIR/chain.pem" ]; then
            printf 'Webmin TLS chain.pem must be readable and non-empty.\n' >&2
            exit 1
        fi
        openssl crl2pkcs7 -nocrl -certfile "$WEBMIN_TLS_DIR/chain.pem" -out /dev/null
        extra_cas="$WEBMIN_TLS_DIR/chain.pem"
    fi
    # Keep certificate material outside the persisted Webmin configuration.
    sed -i '/^\(ssl\|keyfile\|certfile\|extracas\)=/d' /etc/webmin/miniserv.conf
    printf 'ssl=1\nkeyfile=%s/privkey.pem\ncertfile=%s/cert.pem\nextracas=%s\n' \
        "$WEBMIN_TLS_DIR" "$WEBMIN_TLS_DIR" "$extra_cas" >> /etc/webmin/miniserv.conf
elif grep -Eq '^(keyfile|certfile)=/run/webmin-tls/' /etc/webmin/miniserv.conf; then
    printf 'Webmin uses mounted TLS certificates; start with WEBMIN_TLS_DIR and its certificate mount.\n' >&2
    exit 1
fi

if { [ -e /etc/webmin/miniserv.pem ] && [ ! -e /etc/webmin/.postfix-webmin-self-signed ]; } ||
    { [ -z "${WEBMIN_TLS_DIR:-}" ] && [ ! -s /etc/webmin/miniserv.pem ]; }; then
    generate_self_signed_certificate
fi

/usr/sbin/postfix start
# Webmin stays in the foreground so its exit terminates the container.
exec /usr/libexec/webmin/miniserv.pl --nofork /etc/webmin/miniserv.conf
