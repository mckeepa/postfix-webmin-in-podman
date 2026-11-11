# Rootless Podman: Postfix with Webmin

This project runs Postfix and Webmin in a Rocky Linux container. Podman is
installed on the host with DNF, and the container is built and run rootlessly
by a dedicated, locked `postfix-webmin` service account. The example image is
pinned to the Rocky Linux 9 x86_64 image digest and Webmin 2.670-1; rebuild and
patch it through the controlled update process below.

Webmin is installed from its official DNF repository. The repository setup
script is fetched from a fixed upstream commit and DNF verifies signed RPMs.

## Intended use and security boundary

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
  every start, including for existing Webmin configuration volumes, while
  preserving other module settings.

## Why use rootless Podman instead of installing on the host?

With a direct host installation, Webmin's privileged functions run in the
host's security context. A Webmin compromise could therefore affect the host
operating system as well as Postfix. Here, Webmin and Postfix run in the
container's filesystem and user namespace; container root maps to the
unprivileged `postfix-webmin` service account, not host root or an
administrator's login account. The container is given only its Postfix/
Webmin data volumes and published ports, rather than broad host directories
or the Podman socket. This reduces the likely impact of a service compromise
and makes the runtime boundary easier to inspect.

This is **risk reduction, not a guarantee or a complete sandbox**. The
container shares the host kernel, and a compromised Webmin can still control
Postfix and access the mail/configuration data mounted into this container.
Rootless Podman also does not replace patching, HTTPS, account restrictions,
backups, or the firewall rule limiting Webmin to the management server.

## Requirements

- An x86_64 Rocky Linux, AlmaLinux, RHEL, Fedora, or other DNF-based
  RHEL-family host. The pinned base image digest is for x86_64.
- An administrator account with `sudo` access. It runs the setup script but
  does not own or run the container.
- The setup creates a locked non-login account named `postfix-webmin`, assigns
  it a free 65,536-ID subordinate UID/GID range, and enables systemd lingering
  for boot startup.

## Install

Run the script from the project directory as an administrator account with
`sudo` access (not as root and not with `sudo`):

```bash
./setup.sh
```

By default, Webmin and SMTP are bound to `127.0.0.1`. To make Webmin reachable
on the mail server's management-network interface, use that interface's
specific IP address. Keep SMTP local until the e-mail admins have configured
and tested Postfix:

```bash
WEBMIN_BIND_ADDRESS=10.20.30.15 ./setup.sh
```

If the container is already running with the default localhost binding, change
the binding and recreate it while keeping the persistent volumes:

```bash
WEBMIN_BIND_ADDRESS=10.20.30.15 UPDATE_EXISTING=1 ./setup.sh
```

The script installs `podman`, `shadow-utils-subid`, `slirp4netns`, and
`fuse-overlayfs` with DNF when needed. It creates the `postfix-webmin` service
account with home `/var/lib/postfix-webmin` (mode 0700), a locked password,
no supplementary groups, and a nologin shell; assigns it a non-overlapping
subordinate UID/GID range; and verifies its rootless Podman user namespace.
The service account owns the image store, Quadlet, and persistent volumes.
The script prompts for a bootstrap Webmin password only for a new
installation. Webmin is at
`https://<mail-server-management-IP>:10000`. Its initial certificate is
self-signed; install a trusted certificate before production use.

If upgrading an installation previously run under your login account, run
`UPDATE_EXISTING=1 ./setup.sh` from that same account. The script stops the
old container, migrates all five named volumes into the service account's
Podman storage, and retains the original volumes for rollback.
It refuses partial or conflicting volume sets instead of starting with empty
mail data. Keep the old login account's Podman volumes until the new service
has been verified and backed up. A migration marker prevents later updates
from re-importing those retained, older volumes.

### Development-run commands

The default Webmin URL is for a browser running on the mail server itself:
**https://127.0.0.1:10000**. Accept the self-signed certificate warning for
testing and sign in as `root` with the bootstrap password entered during
setup.

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

`podman ps -a` shows stopped containers and their exit status; `podman ps`
does not. If the health check fails, inspect the logs before repeatedly
restarting the container.

The Quadlet unit is stored at
`/var/lib/postfix-webmin/.config/containers/systemd/postfix-webmin.container`
with `WantedBy=default.target`; the setup enables systemd lingering for the
service account. To confirm, run
`loginctl show-user postfix-webmin -p Linger` and check for `Linger=yes`.

### Reset the Webmin password

The bootstrap username is `root`. Use the Webmin password set
during the original setup, not the host sudo password. Migration preserves
the Webmin credentials; passwords cannot be recovered in plaintext.

If forgotten, run this from an administrator terminal. It stops the service,
updates the existing Webmin configuration in a temporary maintenance
container, then starts the service. This briefly interrupts mail service.
Do not run the password tool with `podman exec` in the running service:
the tool stops Webmin before saving, which terminates the container and can
interrupt the password update.

The command prompts without echoing the new password and discovers the
service account's UID rather than assuming a particular value:

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
service_cmd systemctl --user stop postfix-webmin.service
printf '%s\n' "$PASSWORD" |
  service_cmd podman run --rm -i --network none \
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

### Unexpected container exits

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

On SELinux-enforcing hosts, the Quadlet mounts all five data volumes with
`:Z`, giving them the current container's private SELinux label. Replacement
or diagnostic containers can otherwise encounter `Permission denied` when a
volume retains another container's private label, even with correct Unix
ownership. Use `:Z` on each volume in manual diagnostic runs too, and stop
the service first: relabeling a volume for another container can deny access
to the original container. Do not disable SELinux or use `chmod 777`.
To apply updated volume options to an existing installation, run
`UPDATE_EXISTING=1 ./setup.sh`; it rebuilds and recreates the container while
retaining its named volumes.

On the firewall, allow TCP/10000 **only from the management server's fixed
source IP**. Do not add a general public rule for that port. For example, adapt
this firewalld rich rule to the server's zone and management-server address:

```bash
sudo firewall-cmd --permanent --zone=<zone> \
  --add-rich-rule='rule family="ipv4" source address="<MANAGEMENT_SERVER_IP>/32" port port="10000" protocol="tcp" accept'
sudo firewall-cmd --reload
```

Remove any broader rule that also allows TCP/10000. After the e-mail admins
approve public SMTP, bind SMTP to the intended server address and replace the
container while retaining the volumes:

```bash
WEBMIN_BIND_ADDRESS=10.20.30.15 \
SMTP_BIND_ADDRESS=192.0.2.25 \
UPDATE_EXISTING=1 ./setup.sh
```

In this example, `192.0.2.25` is the mail server's public address. The host
firewall or an approved low-port listener must forward public TCP/25 to the
container's host TCP/2525. Do not open TCP/2525 to the public Internet unless
that is explicitly intended.

Create a dedicated Webmin user limited to the Postfix module, test it, and
then restrict or disable the bootstrap `root` login. The firewall rule and
the management server's MFA are complementary controls.

## Durable data and backups

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

To rebuild and replace the container after backing up, run:

```bash
UPDATE_EXISTING=1 ./setup.sh
```

This rebuilds the image, replaces only the named container, and reuses the
volumes. It does not roll back configuration changes or restore data. Keep a
known-good image reference and backup so a failed update can be recovered.

## TODO: Configure and verify mail security (e-mail admins)

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

## Pinning, patching, and operations

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
  UPDATE_EXISTING=1 ./setup.sh
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
  Development-run commands to check service status. Test reboot recovery and
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

## Should Webmin be in a separate container?

It is possible, but a second container is not automatically more secure.
Webmin's Postfix module needs to change Postfix configuration and invoke
Postfix control commands. A separate Webmin container therefore needs a
management channel to Postfix. Sharing configuration/queue volumes still lets
Webmin alter important mail data; mounting the Podman socket grants broad
container-management authority and should be avoided.

Separation can reduce process-level blast radius and let Webmin be patched
independently **only if** the control channel is narrowly scoped and does not
give Webmin broad host or container privileges. That design needs a separately
reviewed API/agent and adds operational complexity. For this deployment, keep
Webmin reachable only from the MFA-protected management server and restrict
its Webmin account to the Postfix module. Revisit separation if a safe,
least-privilege control channel is designed.
