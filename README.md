# Rootless Podman: Postfix with Webmin

This project runs Postfix and Webmin in a Rocky Linux container. Podman is
installed on the host with DNF, and the container is built and run rootlessly
by a dedicated, locked `postfix-webmin` service account. The image is
pinned to the Rocky Linux 9 x86_64 image digest and Webmin 2.670-1; rebuild and
patch it through the controlled update process below.

Webmin is installed from its official DNF repository. The repository setup
script is fetched from a fixed upstream commit and DNF verifies signed RPMs.

Follow these stages in order:

1. [Initial platform setup](#1-initial-platform-setup)
2. [Build the container image](#2-build-the-container-image)
3. [Install and deploy the image](#3-install-and-deploy-the-image)
4. [Management, maintenance, and troubleshooting](#4-management-maintenance-and-troubleshooting)

For a fresh installation with localhost-only access, `./setup.sh` runs all three
installation stages in order. Alternatively, run each stage separately below.
Always run the host scripts as an administrator with `sudo` access, **not as
root and not with `sudo ./script.sh`**.

### Intended use and security boundary

- Webmin is for Postfix administration only. The package includes other
  modules, so create a dedicated Webmin user and grant it access only to
  **Servers → Postfix Mail Server**. Do not use the bootstrap `root` login for
  routine work; restrict or disable it after confirming the dedicated account.
- Webmin and Postfix run as root **inside** the container. Rootless Podman
  maps container root to the unprivileged `postfix-webmin` host account, not to
  an administrator's login account or host root. The service account has a
  nologin shell and no sudo privileges. Rootless Podman is not complete
  isolation.
  The container can access its mounted Postfix and mail data, and a compromise
  can disrupt or take over this mail service.
- MFA is expected to be enforced by the management server. The mail server
  must still require HTTPS and firewall Webmin so only the management server's
  fixed IP can connect.
- The default published addresses are localhost-only. Do not expose Webmin
  broadly or treat the sample Postfix configuration as ready for Internet mail.
- The setup installs a rootless Quadlet unit and enables lingering for the
  service account, so systemd starts the container after boot.

Webmin's Postfix module uses `/usr/sbin/postfix start`, `stop`, and `reload`.
There is no systemd inside the container; only the host's rootless container
service uses systemd. The entrypoint enforces these three module commands on
every start while preserving other module settings.

### Project files

- [Containerfile](./Containerfile): builds Rocky Linux with Postfix and the Webmin DNF package,
  and saves initial configuration for empty volumes.
- [platform-setup.sh](./platform-setup.sh): installs host dependencies and
  provisions the locked service account and rootless boot prerequisites.
- [build-image.sh](./build-image.sh): builds the image without changing the
  running service.
- [deploy.sh](./deploy.sh): deploys the built image with persistent storage,
  initial credentials, and a boot-starting systemd Quadlet.
- [configure-firewall.sh](./configure-firewall.sh): optional, explicit Webmin
  firewall access for all sources or an IPv4 address/CIDR range.
- [templates/postfix-webmin.container.in](./templates/postfix-webmin.container.in):
  Quadlet configuration template used by deployment (systemd INI format, not YAML).
- [setup.sh](./setup.sh): runs the platform, build, and deployment scripts in order;
  stops if any stage fails.
- [scripts/common.sh](./scripts/common.sh): shared settings and service-account
  checks, sourced by the host scripts; do not run it directly.
- [container-entrypoint.sh](./container-entrypoint.sh): seeds empty volumes, configures Webmin's Postfix
  control commands, starts Postfix, and runs Webmin in the foreground.

## 1. Initial platform setup

### Requirements

- An x86_64 Rocky Linux, AlmaLinux, RHEL, Fedora, or other DNF-based
  RHEL-family host. The pinned base image digest is for x86_64.
- An administrator account with `sudo` access. It runs the setup script but
  does not own or run the container.
- Git to clone this repository.
- The setup creates a locked non-login account named `postfix-webmin`, assigns
  it a free 65,536-ID subordinate UID/GID range, and enables systemd lingering
  for boot startup.

### Prepare the host

Clone the repository, then run platform setup as an administrator with `sudo`
access (not as root and not with `sudo`):

```bash
git clone https://github.com/mckeepa/postfix-webmin-in-podman.git
cd postfix-webmin-in-podman
./platform-setup.sh
```

This installs `podman`, `shadow-utils-subid`, `slirp4netns`, and `fuse-overlayfs`
with DNF when needed. It creates the `postfix-webmin` service account with home
`/var/lib/postfix-webmin` (mode 0700), a locked password, no supplementary groups,
and a nologin shell. It assigns non-overlapping subordinate UID/GID ranges,
enables systemd lingering, and verifies rootless Podman.

The service account owns the image store, Quadlet, and persistent volumes.
This stage **does not build an image or start a container**. It can be rerun
to check or provision the host prerequisites.

## 2. Build the container image

After platform setup, run from the project directory:

```bash
./build-image.sh
```

This copies the Containerfile and entrypoint into a service-account-owned build
directory and builds **`localhost/postfix-webmin:local`** in that account's
rootless Podman store. Podman builds the Docker-compatible image from the
Containerfile; Docker is not required.

The build installs Postfix and the pinned Webmin RPM from its official DNF
repository. It saves initial configuration for empty data volumes.
Postfix listens on all **container** interfaces so Podman's published SMTP port
can reach it. Host exposure is still controlled separately by `SMTP_BIND_ADDRESS`
and the firewall; the host binding defaults to localhost only.
**Building does not stop or replace the running container.**

To select an approved Webmin RPM version-release, set `WEBMIN_VERSION` on this
stage, for example `WEBMIN_VERSION=2.670-1 ./build-image.sh`. Review the
patching guidance before changing pinned versions.

## 3. Install and deploy the image

Deploy the image built in stage 2:

```bash
./deploy.sh
```

On a new installation, this prompts for the Webmin `root` password, creates
the five named data volumes, writes the Quadlet, starts the service, and
waits for Webmin HTTPS. It requires the platform and image to exist; it
**does not install host packages or rebuild the image**.

### Choose the bind addresses

By default, Webmin and SMTP are bound to `127.0.0.1`. To make Webmin reachable
on the mail server's management-network interface, use that interface's
specific IP address. Keep SMTP local until the e-mail admins have configured
and tested Postfix.

> [!IMPORTANT]
> **Replace `10.20.30.15` with the mail server's own management-network IPv4
> address. It is an example, not an address supplied by this project.**
> Use an address assigned to the server running this container, **not your
> workstation's IP or the separate management server's IP**.

On the **mail server**, list its interface addresses:

```bash
ip -br -4 address
```

Choose the address on the interface used for administration, without the
`/prefix` suffix. For example, if that interface shows `10.50.1.20/24`,
use **`WEBMIN_BIND_ADDRESS=10.50.1.20`**. Arrange a static address or DHCP
reservation with your network administrator so it stays consistent.

For a fresh deployment, substitute your address in this example:

```bash
WEBMIN_BIND_ADDRESS=10.20.30.15 ./deploy.sh
```

For an existing installation, **replace the example address here too**.
This changes the binding and recreates the container while keeping its
persistent volumes:

```bash
WEBMIN_BIND_ADDRESS=10.20.30.15 UPDATE_EXISTING=1 ./deploy.sh
```

The deployment prompts for a bootstrap Webmin password only for a new
installation; updates retain the existing password. Webmin is at
`https://<mail-server-management-IP>:10000`. Its initial certificate is
self-signed; install a trusted certificate before production use.

Deployment operates only on the `postfix-webmin` service account's Podman storage.
It refuses incomplete volume sets rather than replacing missing mail data with
empty volumes.

### Stage options

| Environment variable | Default | Stage | Purpose |
| --- | --- | --- | --- |
| `WEBMIN_BIND_ADDRESS` | `127.0.0.1` | Deploy | Host address for Webmin TCP/10000. |
| `SMTP_BIND_ADDRESS` | `127.0.0.1` | Deploy | Host address for SMTP TCP/2525, forwarded to container TCP/25. |
| `WEBMIN_TLS_DIR` | unset | Deploy | Absolute host directory containing Webmin's PEM certificate and private key; mounted read-only. |
| `WEBMIN_VERSION` | `2.670-1` | Build | Exact Webmin RPM version-release to install. |
| `UPDATE_EXISTING` | `0` | Deploy | Set to `1` to replace an installation while preserving its volumes. |

Specify the intended bind addresses on **every deployment**; omitted values use
the defaults, including during updates. These variables also work with the
all-in-one `setup.sh` wrapper and are passed to its stages.

### Use a trusted certificate for Webmin

**Certificates are supplied at deployment, not baked into the image. Renewal
does not require an image rebuild.** Without `WEBMIN_TLS_DIR`, a new installation
uses Webmin's built-in self-signed certificate.
Deployment prints a warning when no external certificate directory is supplied.
Existing installations retain their stored Webmin certificate in this mode.

Obtain a certificate from a public CA or your organization's internal CA.
Its **Subject Alternative Name must include the DNS name used to access Webmin**,
for example `webmin.example.com`. Clients must trust the issuing CA; uploading
a certificate alone does not establish trust.

Prepare a **dedicated directory** containing:

- `cert.pem`: the server certificate in PEM format.
- `privkey.pem`: the matching **unencrypted** PEM private key, readable only
  by the service account and host administrators.
- `chain.pem`: intermediate CA certificates in PEM format, in issuer order.
  Omit this file only if no intermediate CA is needed.

> [!IMPORTANT]
> **Replace `/path/to/issued/` below with the location of your CA-issued files.**
> Copy files into the dedicated directory; do not bind-mount or relabel the
> entire `/etc/letsencrypt` directory. Do not commit keys to Git or put PEM
> contents into environment variables.

```bash
sudo install -d -o postfix-webmin -g postfix-webmin -m 0700 /var/lib/postfix-webmin/tls
sudo install -o postfix-webmin -g postfix-webmin -m 0600 \
  /path/to/issued/cert.pem /var/lib/postfix-webmin/tls/cert.pem
sudo install -o postfix-webmin -g postfix-webmin -m 0600 \
  /path/to/issued/privkey.pem /var/lib/postfix-webmin/tls/privkey.pem
sudo install -o postfix-webmin -g postfix-webmin -m 0600 \
  /path/to/issued/chain.pem /var/lib/postfix-webmin/tls/chain.pem
```

Skip the last command if no intermediate is needed. The TLS directory path must
be absolute and use only letters, digits, `/`, `_`, `.`, and `-`.
Keep backups of this directory separately: it is **not part of the five named
volume backups**.

For a fresh deployment with localhost binding:

```bash
WEBMIN_TLS_DIR=/var/lib/postfix-webmin/tls ./deploy.sh
```

For an existing deployment:

```bash
WEBMIN_TLS_DIR=/var/lib/postfix-webmin/tls UPDATE_EXISTING=1 ./deploy.sh
```

Set `WEBMIN_BIND_ADDRESS` and `SMTP_BIND_ADDRESS` as well if using non-default
bindings. **Specify `WEBMIN_TLS_DIR` on every deployment once enabled.**
Deployment refuses to remove an existing TLS mount when the variable is omitted.
The directory is mounted as `/run/webmin-tls:ro,Z`; the entrypoint validates the
certificate expiry, key match, and PEM files before starting Webmin. Unusable
certificates fail startup rather than silently reverting to HTTP or self-signed
TLS. This configures **Webmin HTTPS only**, not Postfix SMTP TLS.

Verify from a client using the certificate's DNS name and **without `-k`**:

```bash
curl --fail --show-error https://webmin.example.com:10000/
```

**Replace `webmin.example.com` with your certificate's DNS name** and ensure DNS
resolves to the bound management address. For a localhost-only test, add
`--resolve webmin.example.com:10000:127.0.0.1`. For an internal CA, install the
CA in your client's trust store or use `--cacert /path/to/root-ca.pem`.
The deployment readiness probe uses `-k` and is **not a certificate-trust test**.

### Startup after reboot

Deployment substitutes `@IMAGE_NAME@`, `@CONTAINER_NAME@`,
`@WEBMIN_BIND_ADDRESS@`, `@SMTP_BIND_ADDRESS@`, and `@WEBMIN_TLS_CONFIG@` in
[the Quadlet template](./templates/postfix-webmin.container.in) and writes
`/var/lib/postfix-webmin/.config/containers/systemd/postfix-webmin.container`
with `[Install] WantedBy=default.target`. The template is treated as text, not
executed as a shell script. Platform setup enables lingering for
the service account so its user manager starts at boot without a login.

```bash
loginctl show-user postfix-webmin -p Linger
```

Confirm `Linger=yes`. After deployment, test an approved reboot and verify
the service using the status commands in section 4.

## 4. Management, maintenance, and troubleshooting

### Service management

The default Webmin URL is for a browser running on the mail server itself:
**https://127.0.0.1:10000**. Accept the self-signed certificate warning for
initial setup and sign in as `root` with the bootstrap password.

Run these commands from an administrator account with `sudo` access. They
operate on the dedicated service account's separate rootless Podman store:

```bash
SERVICE_USER=postfix-webmin
SERVICE_HOME=/var/lib/postfix-webmin
SERVICE_UID=$(id -u "$SERVICE_USER")

podman_service() {
  sudo -u "$SERVICE_USER" env --chdir="$SERVICE_HOME" \
    HOME="$SERVICE_HOME" \
    XDG_RUNTIME_DIR="/run/user/$SERVICE_UID" \
    podman "$@"
}

systemctl_service() {
  sudo -u "$SERVICE_USER" env --chdir="$SERVICE_HOME" \
    HOME="$SERVICE_HOME" \
    XDG_RUNTIME_DIR="/run/user/$SERVICE_UID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$SERVICE_UID/bus" \
    systemctl --user "$@"
}

# Show running containers (an empty result means none are running).
podman_service ps

# Also show stopped containers and their exit status.
podman_service ps -a

# Check whether Postfix and Webmin pass the configured health check.
podman_service healthcheck run postfix-webmin

# Inspect service output if startup or health checks fail.
podman_service logs --tail 100 postfix-webmin

# Probe Webmin's HTTPS endpoint from the mail server.
curl -kfsS -o /dev/null -w 'HTTP %{http_code}\n' https://127.0.0.1:10000/

# Inspect the rootless systemd service and its logs.
systemctl_service status postfix-webmin.service
sudo -u "$SERVICE_USER" env --chdir="$SERVICE_HOME" \
  HOME="$SERVICE_HOME" \
  XDG_RUNTIME_DIR="/run/user/$SERVICE_UID" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$SERVICE_UID/bus" \
  journalctl --user -u postfix-webmin.service -b

# Stop and start the service.
systemctl_service stop postfix-webmin.service
systemctl_service start postfix-webmin.service
```

### Reset the Webmin password

The bootstrap username is `root`. Use the Webmin password set during setup,
not the host sudo password. Container updates preserve credentials;
passwords cannot be recovered in plaintext.

If forgotten, run this from an administrator terminal. It stops the service,
updates the existing Webmin configuration in a temporary maintenance
container, then starts the service. This briefly interrupts mail service.
The password tool runs offline because it stops Webmin before saving credentials.

The command prompts without echoing the new password and discovers the
service account's UID rather than assuming a particular value:

**If using mounted certificates, set `WEBMIN_TLS_DIR` to the same host directory
in this terminal first.** The maintenance container needs that mount too.

```bash
(
set -euo pipefail
SERVICE_HOME=/var/lib/postfix-webmin
SERVICE_UID=$(id -u postfix-webmin)
service_cmd() {
  sudo -u postfix-webmin env --chdir="$SERVICE_HOME" \
    HOME="$SERVICE_HOME" XDG_RUNTIME_DIR="/run/user/$SERVICE_UID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$SERVICE_UID/bus" \
    "$@"
}
sudo -v
read -r -s -p 'New Webmin root password: ' PASSWORD
printf '\n'
read -r -s -p 'Confirm password: ' CONFIRM
printf '\n'
if [[ -z "$PASSWORD" || "$PASSWORD" != "$CONFIRM" ]]; then
  printf 'Passwords must be non-empty and match.\n' >&2
  exit 1
fi
TLS_MOUNTS=()
if [[ -n "${WEBMIN_TLS_DIR:-}" ]]; then
  TLS_MOUNTS=(-v "$WEBMIN_TLS_DIR:/run/webmin-tls:ro,Z")
fi
service_cmd systemctl --user stop postfix-webmin.service
printf '%s\n' "$PASSWORD" |
  service_cmd podman run --rm -i --network none "${TLS_MOUNTS[@]}" \
    -v postfix-webmin-webmin-config:/etc/webmin:Z \
    -v postfix-webmin-webmin-state:/var/webmin:Z \
    --entrypoint /bin/sh localhost/postfix-webmin:local -c \
    'IFS= read -r password && exec /usr/libexec/webmin/changepass.pl /etc/webmin root "$password"'
unset PASSWORD CONFIRM
service_cmd systemctl --user start postfix-webmin.service
)
```

Sign in as `root` with the new password. Do not share the password or put it
literally into a shell command. For routine administration, use a separate
Webmin account limited to the Postfix module.
If the maintenance command fails, the service stays stopped so that the
error can be investigated. Restart it using the service-account start
command above once the issue is resolved.

### Renew the Webmin TLS certificate

Use the service-account helpers from **Service management**:

1. Obtain the renewed certificate and matching key from your CA.
2. Run `systemctl_service stop postfix-webmin.service`.
3. Use the `sudo install` commands above to replace `cert.pem`, `privkey.pem`,
   and, if applicable, `chain.pem` in the **same directory**. Retain the protected
   ownership and permissions. Replace the files inside the mounted directory,
   not the directory itself; remove an obsolete `chain.pem` if no longer needed.
4. Run `systemctl_service start postfix-webmin.service`.
5. Verify HTTPS using the certificate DNS name without `-k`, as above, and check
   service logs if startup fails.

**No build or deployment command is needed for renewal.** The mount and
container environment persist in the Quadlet across restarts and reboots.
Stopping and starting briefly interrupts both Webmin and Postfix. A CA renewal
hook can automate the file installation and restart; it must report failures
and retain a known-good certificate/key pair for rollback.

### Diagnostics

Plain `podman ps` lists only your login account's containers, not the service
account's containers. Use the `podman_service` and `systemctl_service`
helpers above. If Webmin is unreachable, check:

```bash
systemctl_service status postfix-webmin.service
podman_service ps -a
podman_service logs --tail 100 postfix-webmin
sudo journalctl -b _UID="$(id -u postfix-webmin)" --no-pager -n 100
```

Systemd restarts a failed container after ten seconds. Repeated exit/restart
messages indicate a failure, not a healthy service; capture the application
error before restarting or rebuilding. Quadlet may remove failed containers,
so `podman logs` may no longer be available after an exit.

On SELinux-enforcing hosts, all five volumes use `:Z` for private container
labels. Stop the service before mounting its volumes in a maintenance container,
and use `:Z` there too. Relabeling an active service's volumes can deny it access.
Do not disable SELinux or use `chmod 777`.

### Network access

Installation and deployment **do not open the host firewall**. Remote access
requires both a non-localhost Webmin binding and a firewall rule for TCP/10000.
Deployment checks HTTPS inside the container, not browser connectivity.

Run the optional firewall script as an administrator with `sudo` access,
**not with `sudo ./configure-firewall.sh`**. Firewalld must already be installed
and running. Find the zone for the mail server's management interface:

```bash
sudo firewall-cmd --get-active-zones
```

Choose **one** option. Replace `public` with your zone and the example source
with the **client's** IP or network, not the mail server's bind address:

```bash
# One IPv4 address (recommended for the management server)
./configure-firewall.sh --zone public --source 192.0.2.10

# An IPv4 network in CIDR notation
./configure-firewall.sh --zone public --source 192.0.2.0/24

# All sources (approved test environments only)
./configure-firewall.sh --zone public --source all
```

> [!WARNING]
> `all` allows every reachable source, IPv4 and IPv6, to TCP/10000 in that zone.
> For production, restrict access to the management server. IP/CIDR restrictions
> support IPv4 only.

The script changes **runtime and permanent** rules without reloading firewalld:

- Replaces the zone's direct `10000/tcp` opening and simple IPv4 source-address
  rich accept rules for that port, including manually added rules. Switching
  from `all` to IP/CIDR removes the broad port opening.
- Leaves SMTP, bindings, other zones, services, and custom rules unchanged.
  Review these separately: they may independently allow broader access.
- Stops and reports command failures; applied changes are not rolled back.

Check both configurations, then test `https://<mail-server-management-IP>:10000/`
from allowed and, when restricting access, disallowed clients:

```bash
sudo firewall-cmd --zone=public --list-all
sudo firewall-cmd --permanent --zone=public --list-all
```

After the e-mail admins approve public SMTP, bind it to the intended server
address and replace the container while retaining the volumes:

> [!WARNING]
> **Replace both example addresses below.** `10.20.30.15` means the **mail
> server's management-interface IP**; `192.0.2.25` means its **SMTP-facing host
> IP**. Each bind address must be assigned to this host.
> The firewall script's `--source` address above is different: it is the
> **source IP of the separate server allowed to administer Webmin**.

```bash
WEBMIN_BIND_ADDRESS=10.20.30.15 \
SMTP_BIND_ADDRESS=192.0.2.25 \
UPDATE_EXISTING=1 ./deploy.sh
```

The host firewall or an approved low-port listener must forward public TCP/25
to the container's host TCP/2525. Do not open TCP/2525 to the public Internet
unless that is explicitly intended.

Create a dedicated Webmin user limited to the Postfix module, test it, and
then restrict or disable the bootstrap `root` login. The firewall rule and
the management server's MFA are complementary controls.

### Durable data and backups

The setup uses these named volumes, all in the dedicated service account's
rootless Podman storage:

- `postfix-webmin-postfix-config` — `/etc/postfix`
- `postfix-webmin-postfix-queue` — `/var/spool/postfix`
- `postfix-webmin-mail` — `/var/mail`
- `postfix-webmin-webmin-config` — `/etc/webmin`
- `postfix-webmin-webmin-state` — `/var/webmin`

The entrypoint seeds new, empty volumes from the image defaults. Container
recreation and image updates preserve these volumes. **Do not remove them**
when replacing the container. They remain on this host under
`/var/lib/postfix-webmin`; they are not a backup or a second copy.

Before production, e-mail/platform admins must establish encrypted,
off-host backups for all five volumes, set retention, monitor free space, and
perform a restore drill. The following command exports every volume while the
container is stopped and restarts it afterward. Run it from an administrator
account with `sudo` access:

```bash
set -euo pipefail
SERVICE_USER=postfix-webmin
SERVICE_HOME=/var/lib/postfix-webmin
SERVICE_UID=$(id -u "$SERVICE_USER")
podman_service() {
  sudo -u "$SERVICE_USER" env --chdir="$SERVICE_HOME" \
    HOME="$SERVICE_HOME" XDG_RUNTIME_DIR="/run/user/$SERVICE_UID" podman "$@"
}
systemctl_service() {
  sudo -u "$SERVICE_USER" env --chdir="$SERVICE_HOME" \
    HOME="$SERVICE_HOME" XDG_RUNTIME_DIR="/run/user/$SERVICE_UID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$SERVICE_UID/bus" \
    systemctl --user "$@"
}
BACKUP_DIR="$HOME/postfix-webmin-backups/$(date +%Y%m%d-%H%M%S)"
install -d -m 700 "$BACKUP_DIR"
systemctl_service stop postfix-webmin.service
trap 'systemctl_service start postfix-webmin.service >/dev/null' EXIT
for volume in \
  postfix-webmin-postfix-config \
  postfix-webmin-postfix-queue \
  postfix-webmin-mail \
  postfix-webmin-webmin-config \
  postfix-webmin-webmin-state
do
  podman_service volume export "$volume" | tee "$BACKUP_DIR/$volume.tar" >/dev/null
done
systemctl_service start postfix-webmin.service
trap - EXIT
printf 'Backups saved in %s\n' "$BACKUP_DIR"
```

Protect these archives as sensitive data; store encrypted copies off-host.
Before production, test restoring all five archives into fresh named volumes
and starting a separate instance on an isolated test host. Do not import over
or remove the production volumes during a restore test. First provision the
service account and empty volumes on the isolated host by running `./setup.sh`.
Then stop that service and replace its empty volumes with the saved archives:

```bash
set -euo pipefail
read -r -p 'Backup directory: ' BACKUP_DIR
SERVICE_USER=postfix-webmin
SERVICE_HOME=/var/lib/postfix-webmin
SERVICE_UID=$(id -u "$SERVICE_USER")
podman_service() {
  sudo -u "$SERVICE_USER" env --chdir="$SERVICE_HOME" \
    HOME="$SERVICE_HOME" XDG_RUNTIME_DIR="/run/user/$SERVICE_UID" podman "$@"
}
systemctl_service() {
  sudo -u "$SERVICE_USER" env --chdir="$SERVICE_HOME" \
    HOME="$SERVICE_HOME" XDG_RUNTIME_DIR="/run/user/$SERVICE_UID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$SERVICE_UID/bus" \
    systemctl --user "$@"
}
systemctl_service stop postfix-webmin.service
if podman_service container exists postfix-webmin; then
  podman_service rm --force postfix-webmin
fi
for volume in \
  postfix-webmin-postfix-config \
  postfix-webmin-postfix-queue \
  postfix-webmin-mail \
  postfix-webmin-webmin-config \
  postfix-webmin-webmin-state
do
  test -s "$BACKUP_DIR/$volume.tar"
  podman_service volume rm "$volume"
  podman_service volume create "$volume"
  cat "$BACKUP_DIR/$volume.tar" | podman_service volume import "$volume" -
done
systemctl_service start postfix-webmin.service
```

The restored Webmin configuration and mail data remain in the service
account's volumes.

### Rebuild and update

After backing up, build first and deploy only when the build succeeds:

```bash
./build-image.sh &&
UPDATE_EXISTING=1 ./deploy.sh
```

These commands use localhost bindings. **If using other bind addresses, set
`WEBMIN_BIND_ADDRESS` and `SMTP_BIND_ADDRESS` on the deployment command.**
If using mounted certificates, also set **`WEBMIN_TLS_DIR`**.
To deploy an image already built, run only `UPDATE_EXISTING=1 ./deploy.sh`.
To rerun all three stages, use `UPDATE_EXISTING=1 ./setup.sh`.

Deployment replaces only the named container and reuses the volumes. It does
not roll back configuration changes or restore data. Keep a known-good image
reference and backup so a failed update can be recovered.

### Production mail checklist

Do not expose SMTP to the Internet until the e-mail admins complete and record
these steps:

1. **Confirm the mail identity and network.** Decide the mail domains, fully
   qualified mail hostname, static public IPv4/IPv6 addresses, accepted
   recipients, outbound route, and whether this server provides inbound mail,
   authenticated submission, or both. Do not publish AAAA records unless
   IPv6 routing and firewall policy are working.
2. **Configure forward and reverse DNS.** Publish A/AAAA records for the mail
   hostname, MX records pointing to it, and provider-managed PTR/reverse-DNS
   records that resolve back to the same hostname. Verify the records from
   outside the hosting network.
3. **Configure Postfix's identity and relay policy.** Set the intended
   `myhostname`, `mydomain`, `mydestination`, `mynetworks`, and destination
   restrictions. Accept mail only for explicitly hosted domains. Permit relay
   only for trusted networks or authenticated clients; never use a broad
   network range as trusted. Test from an external network that unauthenticated
   clients cannot relay to third-party domains.
4. **Configure client submission, if required.** Use the submission service
   (normally TCP/587) with authentication and TLS required before accepting
   credentials. Do not expose an unauthenticated submission relay. Document
   account provisioning, password rotation, and abuse/rate limits.
5. **Configure TLS.** Install a valid certificate for the mail hostname, set
   renewal and reload procedures, and alert before expiry. Verify inbound SMTP
   STARTTLS and authenticated submission TLS externally. Do not treat
   encryption between servers as guaranteed merely because STARTTLS is
   offered.
6. **Publish sender-authentication DNS.** Publish an SPF policy authorizing
   only approved outbound senders. Generate and protect DKIM signing keys,
   publish the selector records, enable signing for outbound mail, and verify
   signatures on received test messages. Publish DMARC initially with
   reporting, review reports, then move deliberately toward `quarantine` or
   `reject` once all legitimate senders are covered. Plan DKIM key rotation
   and protect private keys in backups.
7. **Set abuse and content controls.** Define recipient validation, connection
   and message rate limits, queue-age limits, and spam/virus filtering
   requirements. Establish who responds to a compromised account, outbound
   spam, or a growing deferred queue.
8. **Configure the host network.** Permit inbound TCP/25 only as needed for
   MX delivery and outbound TCP/25 only if direct delivery is approved by the
   hosting provider. If using authenticated submission, expose only the
   required submission port. Webmin TCP/10000 remains restricted to the
   management server. Rootless Podman publishes SMTP on host TCP/2525 by
   default; configure and test a host-side TCP/25-to-2525 forward or another
   approved low-port listener. Verify that Postfix sees the actual client IP
   through the chosen forwarding path.
9. **Test before cutover.** Test inbound delivery, outbound delivery, TLS,
   SPF, DKIM, DMARC alignment, invalid recipients, authenticated submission,
   queue retries, and external open-relay rejection. Inspect full message
   headers and Postfix logs. Document DNS TTLs, cutover, rollback, and
   escalation contacts.
10. **Operate the service.** Monitor queue depth and age, disk/volume usage,
    delivery failures, rejected relay attempts, TLS expiry, DNS/authentication
    records, and backup success. Review DMARC reports and update sender
    records when legitimate sending systems change.

### Pinning, patching, and operations

- The Rocky base image is pinned by digest, Webmin is pinned to an exact RPM
  version, and the Webmin repository setup script is pinned to an upstream
  commit. Rocky RPM dependencies are still resolved from the live Rocky
  repositories during build; a fully reproducible build would also require
  controlled repository snapshots and dependency version locks.
- Track Rocky and Webmin security advisories. In a staging environment, update
  the Rocky digest and `WEBMIN_VERSION` build argument deliberately, rebuild,
  scan/test the image and Postfix/Webmin behavior, then back up and deploy.
  Set `WEBMIN_VERSION` to the approved exact version-release, update the base
  image digest in the Containerfile, and run:

  ```bash
  ./build-image.sh &&
  UPDATE_EXISTING=1 ./deploy.sh
  ```

- Container recreation preserves the existing configuration volumes. Review
  release notes and compare the new image's default Postfix/Webmin
  configuration with the persisted configuration; apply required migrations
  explicitly before cutover.
- Retain the prior image in an internal registry or an image archive, plus
  volume backups, for rollback. Review image changes before deployment; do not
  make `latest` or unreviewed automatic upgrades the production update policy.
- The setup installs a rootless Quadlet unit and enables lingering for
  `postfix-webmin`. Verify `loginctl show-user postfix-webmin -p Linger`
  reports `Linger=yes`. Use the `systemctl_service` helper from the
  Service management section to check service status. Test reboot recovery and
  confirm the container runs under the locked service account.
- The container has a health check, but health status alone does not restart
  or alert on a failure. Add monitoring and alerting for health, queue depth,
  disk space, backup/restore, and certificate expiry.
- Postfix normally logs through syslog; this image does not run a syslog
  daemon. Before production, configure and test a logging path that captures
  Postfix events, retains them appropriately, and forwards security-relevant
  logs to the organization's monitoring system.
- Keep Podman's default SELinux/seccomp confinement. Do not use privileged
  mode, mount the host's Podman socket, or bind-mount broad host paths. Before
  adding capability drops or a read-only root filesystem, test Postfix and
  Webmin's service-control paths in staging; they need carefully chosen
  writable paths and privileges.

### Script validation

With Python 3 available, run the isolated stage tests from the project directory:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
```

These tests mock host and Podman commands; they do not change running services,
accounts, volumes, or firewall rules. They check stage boundaries, prerequisites,
initial password setup, firewall mode changes and failures, and the all-in-one
wrapper. A real deployment, firewall access check, and reboot test are still
required on the target server.

The optional SMTP integration test requires an image in the **invoking account's**
Podman store, separate from the service account's deployment:

```bash
podman build --tag localhost/postfix-webmin:test . &&
POSTFIX_WEBMIN_TEST_IMAGE=localhost/postfix-webmin:test \
  PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
```

It starts a disposable container on a random localhost port, checks the SMTP
greeting, and removes that container afterward. Without the image variable,
this integration test is skipped.
