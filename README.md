# Postfix with Webmin in rootless Podman

Runs Postfix and Webmin in a Rocky Linux 9 container. The image is built and
run rootlessly by a dedicated, locked `postfix-webmin` service account and
managed by a systemd Quadlet that starts at boot. The base image digest,
Webmin RPM version, and Webmin repository setup script are all pinned.

## Requirements

- An x86_64 DNF-based RHEL-family host (Rocky, AlmaLinux, RHEL, Fedora) with
  systemd.
- An administrator account with `sudo` access. Run the scripts from that
  account — **never as root and never with `sudo ./script.sh`**.

## Install

To run a prebuilt DockerHub image without building locally, use the
[client deployment guide](./CLIENT-DEPLOYMENT.md). The installation below is
for building the image on the host.

```bash
git clone https://github.com/mckeepa/postfix-webmin-in-podman.git
cd postfix-webmin-in-podman
./setup.sh
```

`setup.sh` runs three stages that can also be run individually:

1. [platform-setup.sh](./platform-setup.sh) — installs Podman packages,
   creates the locked `postfix-webmin` account (home `/var/lib/postfix-webmin`,
   nologin shell), assigns subordinate UID/GID ranges, and enables lingering.
2. [build-image.sh](./build-image.sh) — builds `localhost/postfix-webmin:local`
   in the service account's rootless Podman store. Does not touch the running
   service.
3. [deploy.sh](./deploy.sh) — creates the data volumes, writes the Quadlet,
   prompts for the Webmin `root` password (new installations only), and starts
   the service.

Afterwards, Webmin is at **https://127.0.0.1:10000** (self-signed certificate
by default; sign in as `root`) and SMTP at `127.0.0.1:2525` (container port 25).
The self-signed certificate is generated uniquely in the persistent Webmin
volume on first startup; it is not embedded in the image.

### Options

| Variable | Default | Stage | Purpose |
| --- | --- | --- | --- |
| `WEBMIN_BIND_ADDRESS` | `127.0.0.1` | Deploy | Host address for Webmin TCP/10000. |
| `SMTP_BIND_ADDRESS` | `127.0.0.1` | Deploy | Host address for SMTP TCP/2525. |
| `WEBMIN_TLS_DIR` | unset | Deploy | Host directory with Webmin's PEM certificate and key, mounted read-only. |
| `WEBMIN_VERSION` | `2.670-1` | Build | Exact Webmin RPM version-release. |
| `DOCKERHUB_NAMESPACE` | unset | Push | DockerHub user or organization namespace for the default push destination. |
| `UPDATE_EXISTING` | `0` | Deploy | Set to `1` to replace an installation while preserving its volumes. |

Set the intended values on **every** deployment; omitted variables revert to
defaults. Bind addresses must be assigned to this host. Example update that
changes the Webmin binding while keeping all data and credentials:

```bash
WEBMIN_BIND_ADDRESS=10.20.30.15 UPDATE_EXISTING=1 ./deploy.sh
```

## TLS for Webmin

Obtain a CA-issued certificate whose Subject Alternative Name includes the
DNS name used to reach Webmin. Install `cert.pem`, the unencrypted
`privkey.pem`, and (if needed) `chain.pem` into a dedicated directory:

```bash
sudo install -d -o postfix-webmin -g postfix-webmin -m 0700 /var/lib/postfix-webmin/tls
sudo install -o postfix-webmin -g postfix-webmin -m 0600 \
  /path/to/issued/cert.pem /path/to/issued/privkey.pem /path/to/issued/chain.pem \
  /var/lib/postfix-webmin/tls/
```

Then deploy with `WEBMIN_TLS_DIR=/var/lib/postfix-webmin/tls` (add
`UPDATE_EXISTING=1` for an existing installation) and keep specifying it on
every later deployment. The entrypoint validates the certificate, key match,
and chain at startup; unusable certificates fail startup instead of falling
back. To renew, replace the files in the same directory and restart the
service — no rebuild or redeploy is needed. Keep separate backups of this
directory; it is not part of the volume backups.

On upgrade, an existing Webmin volume without the per-install certificate
marker is given a new self-signed certificate. This rotates the certificate
that older image builds shared; clients may need to accept the replacement
certificate again.

## Firewall

Installation never opens the host firewall. For remote Webmin access, bind to
a non-localhost address (above) and allow TCP/10000 with the optional script
(requires firewalld; replace the zone and use the **client's** address):

```bash
./configure-firewall.sh --zone public --source 192.0.2.10   # one IPv4 address
./configure-firewall.sh --zone public --source 192.0.2.0/24 # IPv4 CIDR
./configure-firewall.sh --zone public --source all          # test environments only
```

It updates runtime and permanent rules for TCP/10000 only, replacing any
previous access granted for that port, and never reloads firewalld.

## Manage the service

Podman container storage is account-specific. `podman ps` lists containers
owned by the invoking account. The following helper runs management commands
as the `postfix-webmin` service account:

```bash
SERVICE_USER=postfix-webmin
SERVICE_HOME=/var/lib/postfix-webmin
SERVICE_UID=$(id -u "$SERVICE_USER")
service_cmd() {
  sudo -u "$SERVICE_USER" env --chdir="$SERVICE_HOME" \
    HOME="$SERVICE_HOME" XDG_RUNTIME_DIR="/run/user/$SERVICE_UID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$SERVICE_UID/bus" "$@"
}

service_cmd systemctl --user status postfix-webmin.service
service_cmd systemctl --user stop postfix-webmin.service
service_cmd systemctl --user start postfix-webmin.service
service_cmd journalctl --user -u postfix-webmin.service -b
service_cmd podman ps -a
service_cmd podman logs --tail 100 postfix-webmin
service_cmd podman healthcheck run postfix-webmin
```

Lingering keeps the service starting at boot; verify with
`loginctl show-user postfix-webmin -p Linger`.

### Reset the Webmin password

With the helper above (include the `WEBMIN_TLS_DIR` mount only when external
TLS is configured; this briefly stops the service):

```bash
read -r -s -p 'New Webmin root password: ' PASSWORD; printf '\n'
service_cmd systemctl --user stop postfix-webmin.service
printf '%s\n' "$PASSWORD" | service_cmd podman run --rm -i --network none \
  -v postfix-webmin-webmin-config:/etc/webmin:Z \
  -v postfix-webmin-webmin-state:/var/webmin:Z \
  --entrypoint /bin/sh localhost/postfix-webmin:local -c \
  'IFS= read -r password && exec /usr/libexec/webmin/changepass.pl /etc/webmin root "$password"'
unset PASSWORD
service_cmd systemctl --user start postfix-webmin.service
```

Use a dedicated Webmin user limited to **Servers → Postfix Mail Server** for
routine work, and restrict or disable the bootstrap `root` login.

## Backups

All persistent data lives in five named volumes in the service account's
Podman storage: `postfix-webmin-postfix-config` (`/etc/postfix`),
`postfix-webmin-postfix-queue` (`/var/spool/postfix`), `postfix-webmin-mail`
(`/var/mail`), `postfix-webmin-webmin-config` (`/etc/webmin`), and
`postfix-webmin-webmin-state` (`/var/webmin`). The entrypoint seeds empty
volumes from image defaults; container replacement preserves them. Do not
remove them.

Export all five while the service is stopped (using the helper above):

```bash
BACKUP_DIR="$HOME/postfix-webmin-backups/$(date +%Y%m%d-%H%M%S)"
install -d -m 700 "$BACKUP_DIR"
service_cmd systemctl --user stop postfix-webmin.service
for volume in postfix-webmin-postfix-config postfix-webmin-postfix-queue \
    postfix-webmin-mail postfix-webmin-webmin-config postfix-webmin-webmin-state; do
  service_cmd podman volume export "$volume" | tee "$BACKUP_DIR/$volume.tar" >/dev/null
done
service_cmd systemctl --user start postfix-webmin.service
```

To restore: stop the service, `podman rm --force postfix-webmin`, then for
each volume run `podman volume rm`, `podman volume create`, and
`podman volume import "$volume" - < "$volume.tar"` via `service_cmd`, and
start the service. Test restores on an isolated host, never over production
volumes. Store the archives encrypted and off-host.

## Update

Track Rocky and Webmin security advisories. Update the base image digest in
the [Containerfile](./Containerfile) and/or set `WEBMIN_VERSION`, then back up
and run:

```bash
./build-image.sh &&
UPDATE_EXISTING=1 ./deploy.sh
```

Include the configured `WEBMIN_BIND_ADDRESS`, `SMTP_BIND_ADDRESS`, and
`WEBMIN_TLS_DIR` values to the deploy command. Deployment replaces only the
container and keeps the volumes; retain the prior image and backups for
rollback.

## Push to DockerHub

### Log in from the CLI

This project uses Podman, so Docker CLI installation is not required.
Log in as the `postfix-webmin` service account that owns the built image.
Plain `podman login` or `docker login` as an administrator account will not
provide credentials to the push script.

1. Sign in to [DockerHub](https://hub.docker.com/) through a browser and create
   the destination repository (for example, `postfix-webmin`) under the target
   user or organization namespace. Select public or private visibility.
2. In the Docker account settings, create a personal access token with
   **Read & Write** permissions. Keep it secret; use it instead of the account
   password, especially when two-factor authentication is enabled.
3. Run this entire block from an administrator shell after platform setup.
   It defines `service_cmd` for the current shell; it is not an installed
   command. Replace `DOCKERHUB_USERNAME` with the authenticating DockerHub
   username, not an organization name:

   ```bash
   SERVICE_USER=postfix-webmin
   SERVICE_HOME=/var/lib/postfix-webmin
   SERVICE_UID=$(id -u "$SERVICE_USER")
   service_cmd() {
     sudo -u "$SERVICE_USER" env --chdir="$SERVICE_HOME" \
       HOME="$SERVICE_HOME" XDG_RUNTIME_DIR="/run/user/$SERVICE_UID" \
       DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$SERVICE_UID/bus" "$@"
   }

   service_cmd podman login --username DOCKERHUB_USERNAME docker.io
   ```

   If `sudo` prompts for a password, enter the administrator account password.
   At Podman's `Password:` prompt, paste the DockerHub access token. Input is
   hidden; do not put the token directly in a shell command.
4. Confirm the stored login:

   ```bash
   service_cmd podman login --get-login docker.io
   ```

Podman stores these credentials in the service account's runtime auth file,
not in the image. They normally need to be supplied again after a reboot.
To remove them:

```bash
service_cmd podman logout docker.io
```

### Build and publish

Set the lowercase DockerHub user or organization namespace in the shell,
then build and publish with the separate push command:

```bash
export DOCKERHUB_NAMESPACE=example-namespace
./build-image.sh
./push-image.sh
```

With no argument, the destination is
`docker.io/$DOCKERHUB_NAMESPACE/postfix-webmin:latest`. Replace `example-namespace`
with the target namespace. To retain this setting across shell sessions, add
the export to the shell startup configuration. This variable selects the
destination; it does not change the authenticated DockerHub account. That
account must have push permission for the chosen namespace.

An explicit destination overrides the configured namespace, for example:

```bash
./push-image.sh docker.io/example-namespace/postfix-webmin:release-1
```

The push command checks that the image exists, runs `podman login docker.io`
as the service account (reusing valid stored credentials when available), and
pushes the built image to the selected destination.
At the login prompt, use the DockerHub username and an access token with push
permission as the password; do not put the token in the command line.

Publishing is never part of installation or deployment. The command does not
export a running container, include its volumes, or change the running service.
Only publish a rebuilt image with the secret-removal changes described below.
Check the DockerHub repository's visibility before pushing; a public repository
makes the image available to anyone.

## Tests

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
```

The stage tests mock host and Podman commands and change nothing on the host.
The optional SMTP integration test runs against a locally built image:

```bash
podman build --tag localhost/postfix-webmin:test . &&
POSTFIX_WEBMIN_TEST_IMAGE=localhost/postfix-webmin:test \
  PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
```

## Security notes

- Webmin and Postfix run as root **inside** the container; rootless Podman
  maps that to the unprivileged service account. This is not complete
  isolation — a compromise can disrupt or take over this mail service.
- The image excludes Webmin's generated TLS private key and runtime session
  state. Treat images from older builds as containing a shared private key;
  upgrading the service rotates the stored default certificate, but cannot
  revoke copies of an older image already distributed.
- Defaults bind to localhost only. Restrict Webmin's firewall access to the
  management host and require HTTPS.
- The sample Postfix configuration is not ready for Internet mail. Before
  public SMTP exposure, configure DNS (MX/PTR), relay restrictions, TLS,
  SPF/DKIM/DMARC, rate limits, monitoring, and a host-side TCP/25→2525
  forward, and test everything externally.
- Postfix logs via syslog and this image runs no syslog daemon; set up a
  logging path before production use.
