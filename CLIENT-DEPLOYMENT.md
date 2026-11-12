# Client deployment from DockerHub

Run the prebuilt `docker.io/mckeepa/postfix-webmin` image without building it
locally. DockerHub is the image registry; this guide uses rootless Podman and
systemd, not Docker Engine, to run the service.

## Requirements

- An x86_64 Linux server running a DNF-based RHEL-family distribution such as
  Rocky Linux, AlmaLinux, RHEL, or Fedora, with systemd and Quadlet-capable Podman.
  The supplied host scripts do not support Debian or Ubuntu.
- An administrator account with `sudo`, Git, and an interactive terminal.
  Run the project scripts as that account, not as root or with `sudo ./script.sh`.
- Network access to DockerHub and the host distribution's package repositories.
- A published image tag or digest supplied by the maintainer. The examples use
  `latest`; for production, use an approved release tag or immutable digest.
  The image and corresponding deployment scripts must both be available to
  the client before following this guide.

The default configuration is a starting point, not an Internet-ready mail
server. Keep management access private until TLS and access restrictions are
configured.

## 1. Prepare the host

Obtain the deployment scripts from the project's published release or clone:

```bash
git clone https://github.com/mckeepa/postfix-webmin-in-podman.git
cd postfix-webmin-in-podman
./platform-setup.sh
```

Use the scripts supplied for the approved image release. Platform setup
installs the required host packages, creates the locked `postfix-webmin`
service account, and enables startup at boot.

Do **not** run `setup.sh` or `build-image.sh` for this workflow: those build
an image locally rather than use the DockerHub image.

## 2. Pull the published image

The following helper runs Podman in the service account's image store.
Define it in an administrator shell. Plain `podman pull` uses the invoking
account's store, which is separate from the store used by deployment.

```bash
SERVICE_USER=postfix-webmin
SERVICE_HOME=/var/lib/postfix-webmin
SERVICE_UID=$(id -u "$SERVICE_USER")
service_cmd() {
  sudo -u "$SERVICE_USER" env --chdir="$SERVICE_HOME" \
    HOME="$SERVICE_HOME" XDG_RUNTIME_DIR="/run/user/$SERVICE_UID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$SERVICE_UID/bus" "$@"
}
```

Public images normally do not require login. For a private repository, first
authenticate with an authorized DockerHub username and a
read-only access token at the password prompt:

```bash
service_cmd podman login --username DOCKERHUB_USERNAME docker.io
```

Replace `DOCKERHUB_USERNAME` with the authenticating account's username.
Never distribute the publisher's DockerHub token to clients.

Pull and give the image the local name expected by the deployment script:

```bash
PUBLISHED_IMAGE=docker.io/mckeepa/postfix-webmin:latest
service_cmd podman pull "$PUBLISHED_IMAGE" &&
  service_cmd podman tag "$PUBLISHED_IMAGE" localhost/postfix-webmin:local
```

Replace `latest` with the supplied release tag, or set `PUBLISHED_IMAGE` to
`docker.io/mckeepa/postfix-webmin@sha256:...` using the full approved digest.
If the pull fails, resolve the image name, access permissions, or network
problem before deploying. Retagging does not rebuild or modify the image.

## 3. Start the service

For the first installation, run from an interactive terminal:

```bash
./deploy.sh
```

Enter and confirm a unique Webmin root password when prompted. By default:

- Webmin: `https://127.0.0.1:10000` on the server.
- SMTP: `127.0.0.1:2525` on the server.
- A unique self-signed Webmin certificate is generated at first startup and
  retained in the persistent Webmin configuration volume.
- Five named volumes hold configuration, credentials, mail, and queue data.
- The systemd user service starts automatically at boot.

For workstation management without exposing Webmin on the network,
keep these default bindings and create an SSH tunnel from the workstation
(replace both placeholders):

```bash
ssh -N -L 10000:127.0.0.1:10000 ADMIN_USER@SERVER
```

Open `https://127.0.0.1:10000` on the workstation. The self-signed certificate
will cause a browser warning; verify its identity through a trusted channel,
or install a trusted certificate. Sign in as `root` using the password set
during deployment, then create a restricted account for routine Postfix
administration.

For direct network access, follow the
[TLS](./README.md#tls-for-webmin) and [firewall](./README.md#firewall)
instructions. Set `WEBMIN_BIND_ADDRESS` to an address actually assigned to
the server (`ip -4 addr show` lists IPv4 addresses), not an example address.
Restrict TCP/10000 to approved management sources. Keep SMTP on localhost
unless mail delivery has been explicitly configured and tested.

## 4. Verify and troubleshoot

Use the helper from step 2 in the same shell:

```bash
service_cmd systemctl --user status --no-pager postfix-webmin.service
service_cmd podman ps
service_cmd podman healthcheck run postfix-webmin
service_cmd podman logs --tail 100 postfix-webmin
```

If startup fails, read the journal as an administrator:

```bash
sudo journalctl -b --no-pager -n 100 _SYSTEMD_USER_UNIT=postfix-webmin.service
```

`Cannot assign requested address` means the configured bind address is not
available on the server. `Address already in use` means another listener
already occupies the requested address and port. A missing container after a
failed start is possible because systemd removes failed containers; use the
journal rather than relying only on container logs.

## 5. Back up and update

Before any update, follow the [backup and restore instructions](./README.md#backups)
and separately back up any externally mounted TLS directory. Do not remove
the named volumes: they contain client data and credentials.

Retain a local reference to the current image for rollback, using an unused
tag for each update, then pull the newly approved image:

```bash
service_cmd podman tag localhost/postfix-webmin:local localhost/postfix-webmin:rollback-1
PUBLISHED_IMAGE=docker.io/mckeepa/postfix-webmin:latest
service_cmd podman pull "$PUBLISHED_IMAGE" &&
  service_cmd podman tag "$PUBLISHED_IMAGE" localhost/postfix-webmin:local &&
  UPDATE_EXISTING=1 ./deploy.sh
```

This example keeps the default localhost bindings and uses the stored
self-signed certificate. On every deployment, also supply any previously
chosen `WEBMIN_BIND_ADDRESS`, `SMTP_BIND_ADDRESS`, and `WEBMIN_TLS_DIR`
values. In particular, externally mounted TLS requires `WEBMIN_TLS_DIR`
again. Updates replace the container, briefly interrupt service, and preserve
the five volumes; they do not automatically pull images at boot.

To roll back the image, retag the retained image to
`localhost/postfix-webmin:local` and redeploy with `UPDATE_EXISTING=1` and
the same deployment settings. Image rollback does not undo changes made to
volume data; restore compatible backups if needed.

## Before production mail use

Review the [security notes](./README.md#security-notes). Configure and test
mail domains, relay restrictions, DNS (MX/PTR), SMTP TLS, SPF/DKIM/DMARC,
logging, monitoring, rate limits, and backups. Public SMTP also requires a
deliberate host/network TCP/25 forwarding arrangement to the published
TCP/2525 port. Do not expose the default configuration as an unrestricted
public mail relay.
