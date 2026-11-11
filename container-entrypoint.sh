#!/bin/sh
set -eu

initialize_volume() {
    defaults="$1"
    target="$2"
    mkdir -p "$target"
    entries="$(ls -A "$target")"
    if [ -z "$entries" ]; then
        cp -a "$defaults"/. "$target"/
    fi
}

initialize_volume /usr/share/postfix-webmin-defaults/postfix /etc/postfix
initialize_volume /usr/share/postfix-webmin-defaults/postfix-queue /var/spool/postfix
initialize_volume /usr/share/postfix-webmin-defaults/mail /var/mail
initialize_volume /usr/share/postfix-webmin-defaults/webmin /etc/webmin
initialize_volume /usr/share/postfix-webmin-defaults/webmin-state /var/webmin

# Webmin's distro defaults use systemd, which does not run in this container.
sed -i '/^\(start_cmd\|stop_cmd\|reload_cmd\)=/d' /etc/webmin/postfix/config
cat >> /etc/webmin/postfix/config <<'EOF'
start_cmd=/usr/sbin/postfix start
stop_cmd=/usr/sbin/postfix stop
reload_cmd=/usr/sbin/postfix reload
EOF

/usr/sbin/postfix start
exec /usr/libexec/webmin/miniserv.pl --nofork /etc/webmin/miniserv.conf
