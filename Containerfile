FROM docker.io/library/rockylinux@sha256:d644d203142cd5b54ad2a83a203e1dee68af2229f8fe32f52a30c6e1d3c3a9e0

ARG WEBMIN_VERSION=2.670-1

RUN dnf upgrade -y && \
    dnf install -y ca-certificates curl-minimal openssl postfix && \
    curl -fsSLo /tmp/webmin-setup-repo.sh \
        https://raw.githubusercontent.com/webmin/webmin/3a2b2b8671c0669c129f5275b3dd1853106ae02b/webmin-setup-repo.sh && \
    sh /tmp/webmin-setup-repo.sh --force && \
    dnf install -y "webmin-${WEBMIN_VERSION}.noarch" && \
    dnf clean all && \
    rm -f /tmp/webmin-setup-repo.sh && \
    postconf -e 'inet_interfaces = all' && \
    mkdir -p /usr/share/postfix-webmin-defaults && \
    cp -a /etc/postfix /usr/share/postfix-webmin-defaults/postfix && \
    cp -a /var/spool/postfix /usr/share/postfix-webmin-defaults/postfix-queue && \
    mkdir -p /usr/share/postfix-webmin-defaults/mail /var/mail \
        /usr/share/postfix-webmin-defaults/webmin-state && \
    cp -aL /var/mail/. /usr/share/postfix-webmin-defaults/mail/ && \
    rm -f /etc/webmin/miniserv.pem && \
    cp -a /etc/webmin /usr/share/postfix-webmin-defaults/webmin && \
    rm -rf /var/webmin && \
    install -d -o root -g bin -m 0700 /var/webmin

EXPOSE 10000 25

COPY container-entrypoint.sh /usr/local/sbin/container-entrypoint.sh
RUN chmod 0755 /usr/local/sbin/container-entrypoint.sh

ENTRYPOINT ["/usr/local/sbin/container-entrypoint.sh"]
