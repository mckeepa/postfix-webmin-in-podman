# Client deployment from DockerHub

Install the published `docker.io/mckeepa/postfix-webmin` image using rootless
Podman and systemd. No local image build or Docker Engine is needed.

## Requirements

- An x86_64 DNF-based RHEL-family server (Rocky Linux, AlmaLinux, RHEL, or
  Fedora) with systemd and Quadlet-capable Podman.
- An administrator account with `sudo`, Git, and an interactive terminal.
- Network access to DockerHub and the host's package repositories.

Run every command below as your **normal administrator account**, not as root
and not with `sudo ./script.sh`. The scripts request sudo access when needed.
Run script commands from the cloned project directory.

## 1. Download the scripts

```bash
git clone https://github.com/mckeepa/postfix-webmin-in-podman.git
cd postfix-webmin-in-podman
```

Use the scripts supplied for your approved image release.

## 2. Install and start

Run this from an interactive terminal:

```bash
./platform-setup.sh && ./client-deploy.sh
```

Platform setup installs host packages and prepares the locked service account.
Client deployment pulls the published image, gives it the local name used by
deployment, and starts the service. Enter and confirm a unique Webmin root
password when prompted. It never builds an image.

The default image is `docker.io/mckeepa/postfix-webmin:latest`. If your
maintainer supplied a release tag, pass it as an argument:

```bash
./client-deploy.sh docker.io/mckeepa/postfix-webmin:release-1
```

Replace `release-1` with the supplied tag. For production, prefer an approved
release tag or immutable digest rather than a moving `latest` tag. A full
`docker.io/mckeepa/postfix-webmin@sha256:...` reference is also accepted; use
the complete digest supplied by your maintainer.

For a **private** DockerHub repository, run platform setup and log in before
client deployment:

```bash
./platform-setup.sh &&
  ./service-command.sh podman login docker.io &&
  ./client-deploy.sh
```

At the login prompts, use your authorized DockerHub username and a read-only
access token as the password. Never use the publisher's token or put a token
in a command. Login may be needed again after reboot.

Do not run `setup.sh` or `build-image.sh`: those build the image locally.

## 3. Open Webmin

By default, Webmin listens at `https://127.0.0.1:10000` on the server, and SMTP
at `127.0.0.1:2525`. Five persistent volumes retain configuration, credentials,
mail, and queue data. The service starts automatically at boot.

From your **workstation**, open an SSH tunnel (replace `ADMIN_USER` and `SERVER`):

```bash
ssh -N -L 10000:127.0.0.1:10000 ADMIN_USER@SERVER
```

Keep that terminal open and browse to **https://127.0.0.1:10000** on your
workstation. A unique self-signed certificate is generated on first startup.
Verify its identity through a trusted channel before accepting the browser
warning, or configure a trusted certificate.

Sign in as `root` with the password set during installation. Create a
restricted Webmin user for routine Postfix administration.

For direct network access, follow the [TLS](./README.md#tls-for-webmin) and
[firewall](./README.md#firewall) instructions. Keep management private until
TLS and access restrictions are configured.

## 4. Check status and logs

On the server, from the project directory:

```bash
./service-command.sh systemctl --user status --no-pager postfix-webmin.service
./service-command.sh podman ps
./service-command.sh podman healthcheck run postfix-webmin
./service-command.sh podman logs --tail 100 postfix-webmin
```

`service-command.sh` automatically runs the command as the correct service
account. No shell helper function is needed, even in a new terminal.

If startup fails, inspect the journal:

```bash
sudo journalctl -b --no-pager -n 100 _SYSTEMD_USER_UNIT=postfix-webmin.service
```

- `Cannot assign requested address`: the configured bind address is not
  assigned to this server.
- `Address already in use`: another service is using the configured port.
- A failed container may have been removed automatically; check the journal
  even if container logs are unavailable.

## 5. Back up and update

Before updating, back up all five volumes while the service is stopped:

```bash
(
set -eu
BACKUP_DIR="$HOME/postfix-webmin-backups/$(date +%Y%m%d-%H%M%S)"
install -d -m 700 "$BACKUP_DIR"
./service-command.sh systemctl --user stop postfix-webmin.service
trap './service-command.sh systemctl --user start postfix-webmin.service' EXIT
for volume in postfix-webmin-postfix-config postfix-webmin-postfix-queue \
    postfix-webmin-mail postfix-webmin-webmin-config postfix-webmin-webmin-state; do
  if ! ./service-command.sh podman volume export "$volume" > "$BACKUP_DIR/$volume.tar"; then
    printf 'Backup failed for %s. Do not update; inspect the error.\n' "$volume" >&2
    exit 1
  fi
done
)
```

The service is restarted after export, including if an export fails. Proceed
only if all five exports and the service restart succeeded. Store backups encrypted and
off-host. Separately back up any externally mounted TLS directory. See the
[restore instructions](./README.md#backups); never remove the named volumes
as part of an update.

Retain the current image for rollback, then pull and deploy the new image:

```bash
./service-command.sh podman tag localhost/postfix-webmin:local localhost/postfix-webmin:rollback-1 &&
  UPDATE_EXISTING=1 ./client-deploy.sh
```

Use an unused rollback tag for each update. To deploy an approved release
instead of `latest`, append its full image reference to `client-deploy.sh`.
Updates briefly interrupt service but preserve all five volumes and the
stored password.

The commands above use the default localhost bindings and stored self-signed
certificate. On **every** deployment, supply any custom `WEBMIN_BIND_ADDRESS`,
`SMTP_BIND_ADDRESS`, and `WEBMIN_TLS_DIR` values again. For example, if external
TLS is already configured at the following path:

```bash
WEBMIN_TLS_DIR=/var/lib/postfix-webmin/tls \
  UPDATE_EXISTING=1 ./client-deploy.sh
```

To roll back without pulling another image:

```bash
./service-command.sh podman tag localhost/postfix-webmin:rollback-1 localhost/postfix-webmin:local &&
  UPDATE_EXISTING=1 ./deploy.sh
```

Include the same custom bindings and TLS settings when rolling back. Image
rollback does not undo changes to volume data; restore compatible backups
if needed.

## Before production mail use

The default configuration is not an Internet-ready mail server. Review the
[security notes](./README.md#security-notes), configure mail domains, relay
restrictions, DNS, SMTP TLS, SPF/DKIM/DMARC, logging, monitoring, rate limits,
and backups, and test externally. Public SMTP requires deliberate host/network
TCP/25 forwarding to TCP/2525. Do not expose an unrestricted mail relay.
