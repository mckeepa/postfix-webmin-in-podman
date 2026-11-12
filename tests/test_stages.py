"""Exercise stage boundaries without modifying host accounts, services, or storage."""

import os
from pathlib import Path
import pty
import shutil
import socket
import subprocess
import tempfile
import time
import unittest
import uuid


ROOT = Path(__file__).resolve().parents[1]
MOCKS = r"""
require_administrator() { return 0; }
getent() {
    [[ "${TEST_ACCOUNT:-1}" == 1 ]] || return 2
    printf 'postfix-webmin:x:1001:1001::/var/lib/postfix-webmin:/sbin/nologin\n'
}
id() {
    case "$1" in
        -u) printf '1001\n' ;;
        -gn|-Gn) printf 'postfix-webmin\n' ;;
        *) return 0 ;;
    esac
}
sudo() { printf 'host: %s\n' "$*" >> "$TEST_LOG"; }
podman() { printf 'Unexpected caller-store access\n' >&2; return 99; }
loginctl() { printf 'yes\n'; }
sleep() { return 0; }
as_service_user() {
    printf 'service: %s\n' "$*" >> "$TEST_LOG"
    case "$1 $2" in
        'test -S'|'systemctl --user'|'install -d') return 0 ;;
        'test -r'|'test -s') [[ "${TEST_TLS_FILES:-1}" == 1 ]] ;;
        'test -f') [[ "${TEST_TLS_ENABLED:-0}" == 1 ]] ;;
        'grep -qx') [[ "${TEST_TLS_ENABLED:-0}" == 1 ]] ;;
        'tee '*) cat > "$TEST_QUADLET" ;;
        'podman info') printf 'true\n' ;;
        'podman unshare') printf '0 1001 1\n1 589824 65536\n' ;;
        'podman image') [[ "${TEST_IMAGE:-1}" == 1 ]] ;;
        'podman volume')
            if [[ "$3" == exists ]]; then
                [[ "${TEST_VOLUMES:-all}" == all ]]
            else
                [[ "$3" == create && "$4" == --ignore ]]
            fi
            ;;
        'podman container') [[ "${TEST_CONTAINER:-1}" == 1 ]] ;;
        'podman build'|'podman rm'|'podman exec') return 0 ;;
        'podman pull') return "${TEST_PULL_STATUS:-0}" ;;
        'podman tag') return "${TEST_TAG_STATUS:-0}" ;;
        'podman login') return "${TEST_LOGIN_STATUS:-0}" ;;
        'podman push') return "${TEST_PUSH_STATUS:-0}" ;;
        'podman run') cat >/dev/null ;;
        *) printf 'Unexpected service command: %s\n' "$*" >&2; return 98 ;;
    esac
}
"""


class StageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name)
        (self.project / "scripts").mkdir()
        for name in ("setup.sh", "platform-setup.sh", "build-image.sh", "deploy.sh",
                     "configure-firewall.sh", "push-image.sh", "client-deploy.sh",
                     "service-command.sh"):
            shutil.copy2(ROOT / name, self.project / name)
        shutil.copytree(ROOT / "templates", self.project / "templates")
        common = (ROOT / "scripts/common.sh").read_text()
        (self.project / "scripts/common.sh").write_text(common + "\n" + MOCKS)
        self.log = self.project / "commands.log"
        self.quadlet = self.project / "test.container"

    def run_stage(self, name, interactive=False, arguments=(), **variables):
        env = dict(os.environ, TEST_LOG=str(self.log), TEST_QUADLET=str(self.quadlet),
                   DOCKERHUB_NAMESPACE="")
        env.update(variables)
        master, slave = pty.openpty() if interactive else (None, None)
        try:
            process = subprocess.Popen(
                [str(self.project / name), *arguments],
                cwd="/",
                env=env,
                stdin=slave if interactive else subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            if interactive:
                os.write(master, b"test-only-password\ntest-only-password\n")
            stdout, stderr = process.communicate(timeout=10)
        finally:
            if interactive:
                os.close(master)
                os.close(slave)
        return process.returncode, stdout + stderr

    def commands(self):
        return self.log.read_text() if self.log.exists() else ""

    def run_firewall(self, source, zone="public", **variables):
        return self.run_stage(
            "configure-firewall.sh", arguments=("--zone", zone, "--source", source), **variables
        )

    def mock_firewall(self):
        with (self.project / "scripts/common.sh").open("a") as common:
            common.write(r"""
sudo() { "$@"; }
firewall-cmd() {
    printf 'firewall: %s\n' "$*" >> "$TEST_LOG"
    local scope=runtime option= arg file rule
    for arg in "$@"; do
        case "$arg" in
            --permanent) scope=permanent ;;
            --zone=*) ;;
            *) option="$arg" ;;
        esac
    done
    if [[ "$option" == "${TEST_FIREWALL_FAIL:-}" ]]; then return 2; fi
    file="$TEST_LOG.$scope"
    case "$option" in
        --state) printf 'running\n' ;;
        --get-zones) printf 'public internal\n' ;;
        --list-rich-rules)
            if [[ -f "$file.rules" ]]; then cat "$file.rules"; fi
            ;;
        --add-port=10000/tcp) touch "$file.port" ;;
        --remove-port=10000/tcp) rm "$file.port" ;;
        --query-port=10000/tcp) [[ -f "$file.port" ]] ;;
        --add-rich-rule=*)
            rule="${option#*=}"
            if ! grep -Fxq -- "$rule" "$file.rules" 2>/dev/null; then
                printf '%s\n' "$rule" >> "$file.rules"
            fi
            ;;
        --remove-rich-rule=*)
            rule="${option#*=}"
            grep -Fxv -- "$rule" "$file.rules" > "$file.next" || [[ $? == 1 ]] || return
            mv "$file.next" "$file.rules"
            ;;
        --query-rich-rule=*) grep -Fxq -- "${option#*=}" "$file.rules" ;;
        *) printf 'Unexpected firewall command: %s\n' "$*" >&2; return 98 ;;
    esac
}
""")

    def test_firewall_replaces_access_in_both_scopes_without_reload(self):
        self.mock_firewall()
        custom = 'rule family="ipv4" port port="2525" protocol="tcp" accept'
        old = (
            'rule family="ipv4" source address="198.51.100.1" '
            'port port="10000" protocol="tcp" accept'
        )
        for scope in ("runtime", "permanent"):
            (self.project / f"commands.log.{scope}.rules").write_text(custom + "\n" + old + "\n")
            (self.project / f"commands.log.{scope}.port").touch()
        for source in ("192.0.2.10", "192.0.2.0/24", "192.0.2.0/24",
                       "all", "all", "192.0.2.10/32", "0.0.0.0/0"):
            with self.subTest(source=source):
                status, output = self.run_firewall(source)
                self.assertEqual(status, 0, output)
                for scope in ("runtime", "permanent"):
                    rules = (self.project / f"commands.log.{scope}.rules").read_text().splitlines()
                    port = self.project / f"commands.log.{scope}.port"
                    if source == "all":
                        self.assertEqual(rules, [custom])
                        self.assertTrue(port.exists())
                        self.assertIn("WARNING: Allowing Webmin", output)
                    else:
                        expected = (
                            f'rule family="ipv4" source address="{source}" '
                            'port port="10000" protocol="tcp" accept'
                        )
                        self.assertEqual(rules, [custom, expected])
                        self.assertFalse(port.exists())
        self.assertNotIn("--reload", self.commands())
        self.assertNotIn("podman", self.commands())

    def test_firewall_rejects_invalid_input_before_commands(self):
        self.mock_firewall()
        for source in ("", "256.0.0.1", "192.0.2.01", "192.0.2.1/33",
                       "192.0.2.1/024", "192.0.2.1/08", "::1", "192.0.2.1\naccept"):
            with self.subTest(source=source):
                status, output = self.run_firewall(source)
                self.assertNotEqual(status, 0, output)
                self.assertEqual(self.commands(), "")
        for args in ((), ("--source", "all"), ("--zone",), ("--unknown",)):
            with self.subTest(args=args):
                status, output = self.run_stage("configure-firewall.sh", arguments=args)
                self.assertNotEqual(status, 0, output)
                self.assertEqual(self.commands(), "")

    def test_firewall_checks_zone_and_propagates_failures(self):
        self.mock_firewall()
        status, output = self.run_firewall("all", zone="missing")
        self.assertNotEqual(status, 0, output)
        self.assertIn("does not exist", output)
        self.assertNotIn("--add-", self.commands())
        rule = (
            'rule family="ipv4" source address="192.0.2.10" '
            'port port="10000" protocol="tcp" accept'
        )
        for option in ("--state", f"--add-rich-rule={rule}", "--query-port=10000/tcp"):
            with self.subTest(option=option):
                self.log.unlink(missing_ok=True)
                status, output = self.run_firewall("192.0.2.10", TEST_FIREWALL_FAIL=option)
                self.assertEqual(status, 2, output)
                self.assertNotIn("Webmin TCP/10000 configured", output)
                self.assertIn("exit 2", output)
                self.assertNotIn("--permanent --zone=public --add-", self.commands())

    def test_platform_only_provisions_host_prerequisites(self):
        # Model a supported host with packages and subordinate ranges already present.
        with (self.project / "scripts/common.sh").open("a") as common:
            common.write(r"""
dnf() { return 99; }
rpm() { return 0; }
grep() {
    if [[ "${@: -1}" == /etc/os-release ]]; then return 0; fi
    command grep "$@"
}
awk() {
    if [[ "$1" == -F: ]]; then return 0; fi
    command awk "$@"
}
""")
        status, output = self.run_stage("platform-setup.sh")
        self.assertEqual(status, 0, output)
        commands = self.commands()
        self.assertIn("host: passwd --lock postfix-webmin", commands)
        self.assertIn("host: loginctl enable-linger postfix-webmin", commands)
        self.assertNotIn("podman build", commands)
        self.assertNotIn("podman volume", commands)
        self.assertNotIn("systemctl --user start", commands)
        self.assertFalse(self.quadlet.exists())

    def test_build_only_builds_in_service_store(self):
        status, output = self.run_stage("build-image.sh", WEBMIN_VERSION="test-version")
        self.assertEqual(status, 0, output)
        commands = self.commands()
        self.assertIn("podman build --build-arg WEBMIN_VERSION=test-version", commands)
        self.assertNotIn("systemctl --user stop", commands)
        self.assertNotIn("podman volume", commands)
        self.assertFalse(self.quadlet.exists())

    def test_stages_require_platform_before_modifying_data(self):
        for stage in ("build-image.sh", "deploy.sh", "client-deploy.sh",
                      "service-command.sh"):
            with self.subTest(stage=stage):
                arguments = ("podman", "ps") if stage == "service-command.sh" else ()
                status, output = self.run_stage(
                    stage, arguments=arguments, TEST_ACCOUNT="0"
                )
                self.assertNotEqual(status, 0)
                self.assertIn("Run ./platform-setup.sh first", output)
                self.assertEqual(self.commands(), "")

    def test_client_pulls_and_tags_before_deploying_without_building(self):
        for arguments, image in (
            ((), "docker.io/mckeepa/postfix-webmin:latest"),
            (("docker.io/example/postfix-webmin:release-1",),
             "docker.io/example/postfix-webmin:release-1"),
            (("docker.io/example/postfix-webmin@sha256:" + "a" * 64,),
             "docker.io/example/postfix-webmin@sha256:" + "a" * 64),
        ):
            with self.subTest(arguments=arguments):
                self.log.unlink(missing_ok=True)
                status, output = self.run_stage(
                    "client-deploy.sh", arguments=arguments, UPDATE_EXISTING="1",
                    WEBMIN_BIND_ADDRESS="10.50.1.20",
                    WEBMIN_TLS_DIR="/var/lib/postfix-webmin/tls",
                )
                self.assertEqual(status, 0, output)
                commands = self.commands()
                pull = f"podman pull -- {image}"
                tag = f"podman tag -- {image} localhost/postfix-webmin:local"
                self.assertLess(commands.index(pull), commands.index(tag))
                self.assertLess(commands.index(tag), commands.index("systemctl --user stop"))
                self.assertIn("systemctl --user start", commands)
                self.assertNotIn("podman build", commands)
                self.assertNotIn("podman run", commands)
                quadlet = self.quadlet.read_text()
                self.assertIn("PublishPort=10.50.1.20:10000:10000", quadlet)
                self.assertIn("Volume=/var/lib/postfix-webmin/tls:", quadlet)

    def test_client_stops_before_deployment_on_registry_or_tag_failure(self):
        for variables, forbidden in (
            ({"TEST_PULL_STATUS": "125"}, "podman tag"),
            ({"TEST_TAG_STATUS": "125"}, "podman image exists"),
        ):
            with self.subTest(variables=variables):
                self.log.unlink(missing_ok=True)
                status, output = self.run_stage(
                    "client-deploy.sh", UPDATE_EXISTING="1", **variables
                )
                self.assertNotEqual(status, 0, output)
                self.assertIn("Deployment was not started", output)
                self.assertNotIn(forbidden, self.commands())
                self.assertNotIn("systemctl --user stop", self.commands())
                self.assertFalse(self.quadlet.exists())

    def test_client_propagates_deployment_refusal_without_replacing_service(self):
        status, output = self.run_stage("client-deploy.sh", UPDATE_EXISTING="0")
        self.assertNotEqual(status, 0, output)
        self.assertIn("set UPDATE_EXISTING=1", output)
        self.assertNotIn("systemctl --user stop", self.commands())
        self.assertFalse(self.quadlet.exists())

    def test_client_fresh_install_sets_password_without_building(self):
        status, output = self.run_stage(
            "client-deploy.sh", interactive=True, TEST_VOLUMES="none",
            TEST_CONTAINER="0", UPDATE_EXISTING="0",
        )
        self.assertEqual(status, 0, output)
        commands = self.commands()
        self.assertLess(commands.index("podman pull"), commands.index("podman run"))
        self.assertLess(commands.index("podman run"), commands.index("systemctl --user start"))
        self.assertNotIn("podman build", commands)
        self.assertNotIn("systemctl --user stop", commands)

    def test_client_and_service_command_reject_invalid_argument_counts(self):
        for stage, arguments in (
            ("client-deploy.sh", ("image", "extra")),
            ("service-command.sh", ()),
        ):
            with self.subTest(stage=stage):
                status, output = self.run_stage(stage, arguments=arguments)
                self.assertNotEqual(status, 0, output)
                self.assertIn("Usage:", output)
                self.assertEqual(self.commands(), "")

    def test_service_command_preserves_arguments_and_status(self):
        with (self.project / "scripts/common.sh").open("a") as common:
            common.write(r"""
require_platform() { return 0; }
as_service_user() {
    [[ $# == 3 && "$1" == podman && "$2" == logs &&
        "$3" == "argument with spaces" ]] || return 97
    printf 'service logs received intact argument\n' >> "$TEST_LOG"
    return "${TEST_LOGS_STATUS:-0}"
}
""")
        for expected_status in (0, 125):
            with self.subTest(expected_status=expected_status):
                status, output = self.run_stage(
                    "service-command.sh",
                    arguments=("podman", "logs", "argument with spaces"),
                    TEST_LOGS_STATUS=str(expected_status),
                )
                self.assertEqual(status, expected_status, output)
                self.assertIn("service logs received intact argument", self.commands())

    def test_service_command_routes_podman_to_service_store(self):
        status, output = self.run_stage(
            "service-command.sh",
            arguments=("podman", "image", "exists", "localhost/postfix-webmin:local"),
        )
        self.assertEqual(status, 0, output)
        self.assertIn(
            "service: podman image exists localhost/postfix-webmin:local", self.commands()
        )

    def test_push_uses_service_store_and_explicit_dockerhub_destination(self):
        destination = "docker.io/example/postfix-webmin:release-1"
        status, output = self.run_stage("push-image.sh", arguments=(destination,))
        self.assertEqual(status, 0, output)
        commands = self.commands()
        self.assertIn("podman image exists localhost/postfix-webmin:local", commands)
        self.assertLess(commands.index("podman login docker.io"), commands.index("podman push"))
        self.assertIn(
            f"podman push localhost/postfix-webmin:local docker://{destination}", commands
        )
        self.assertNotIn("podman build", commands)
        self.assertNotIn("podman volume", commands)
        self.assertNotIn("systemctl --user start", commands)
        self.assertIn("Image published:", output)

    def test_push_rejects_missing_or_ambiguous_destinations(self):
        for arguments in (
            (), ("example/postfix-webmin:latest",),
            ("docker.io/example/postfix-webmin",),
            ("other.example/example/postfix-webmin:latest",),
            ("docker.io/example/postfix-webmin:latest", "extra"),
        ):
            with self.subTest(arguments=arguments):
                status, output = self.run_stage("push-image.sh", arguments=arguments)
                self.assertNotEqual(status, 0, output)
                self.assertIn("Usage:", output)
                self.assertEqual(self.commands(), "")

    def test_push_defaults_to_configured_namespace_and_allows_explicit_override(self):
        for arguments, destination in (
            ((), "docker.io/example-org/postfix-webmin:latest"),
            (("docker.io/other/postfix-webmin:release-1",),
             "docker.io/other/postfix-webmin:release-1"),
        ):
            with self.subTest(arguments=arguments):
                self.log.unlink(missing_ok=True)
                status, output = self.run_stage(
                    "push-image.sh", arguments=arguments, DOCKERHUB_NAMESPACE="example-org"
                )
                self.assertEqual(status, 0, output)
                self.assertIn(
                    f"podman push localhost/postfix-webmin:local docker://{destination}",
                    self.commands(),
                )

    def test_push_rejects_invalid_configured_namespace_before_login(self):
        for namespace in ("Example", "example/extra", "example:5000", "example\nother"):
            with self.subTest(namespace=namespace):
                status, output = self.run_stage(
                    "push-image.sh", DOCKERHUB_NAMESPACE=namespace
                )
                self.assertNotEqual(status, 0, output)
                self.assertIn("Usage:", output)
                self.assertEqual(self.commands(), "")

    def test_push_stops_on_missing_image_or_registry_failure(self):
        destination = "docker.io/example/postfix-webmin:release-1"
        for variables, expected_status, forbidden in (
            ({"TEST_IMAGE": "0"}, 1, "podman login"),
            ({"TEST_LOGIN_STATUS": "125"}, 125, "podman push"),
            ({"TEST_PUSH_STATUS": "125"}, 125, "Image published:"),
        ):
            with self.subTest(variables=variables):
                self.log.unlink(missing_ok=True)
                status, output = self.run_stage(
                    "push-image.sh", arguments=(destination,), **variables
                )
                self.assertEqual(status, expected_status, output)
                self.assertNotIn(forbidden, self.commands() + output)
                self.assertNotIn("Image published:", output)

    def test_deploy_requires_image_before_stopping_service(self):
        status, output = self.run_stage("deploy.sh", TEST_IMAGE="0", UPDATE_EXISTING="1")
        self.assertNotEqual(status, 0)
        self.assertIn("Run ./build-image.sh first", output)
        self.assertNotIn("systemctl --user stop", self.commands())
        self.assertFalse(self.quadlet.exists())

    def test_deploy_requires_template_before_stopping_service(self):
        (self.project / "templates/postfix-webmin.container.in").unlink()
        status, output = self.run_stage("deploy.sh", UPDATE_EXISTING="1")
        self.assertNotEqual(status, 0)
        self.assertIn("Quadlet template is missing or unreadable", output)
        self.assertNotIn("systemctl --user stop", self.commands())
        self.assertFalse(self.quadlet.exists())

    def test_deploy_substitutes_template_without_shell_evaluation(self):
        template = self.project / "templates/postfix-webmin.container.in"
        literal = "# Literal $HOME and $(printf template-text)\n"
        template.write_text(template.read_text() + literal)
        status, output = self.run_stage(
            "deploy.sh", UPDATE_EXISTING="1",
            WEBMIN_BIND_ADDRESS="10.50.1.20", SMTP_BIND_ADDRESS="192.0.2.25"
        )
        self.assertEqual(status, 0, output)
        expected = template.read_text()
        for key, value in {
            "IMAGE_NAME": "localhost/postfix-webmin:local",
            "CONTAINER_NAME": "postfix-webmin",
            "WEBMIN_BIND_ADDRESS": "10.50.1.20",
            "SMTP_BIND_ADDRESS": "192.0.2.25",
            "WEBMIN_TLS_CONFIG": "",
        }.items():
            expected = expected.replace("@" + key + "@", value)
        self.assertEqual(self.quadlet.read_text(), expected)

    def test_deploy_mounts_tls_read_only_without_building(self):
        status, output = self.run_stage(
            "deploy.sh", UPDATE_EXISTING="1", WEBMIN_TLS_DIR="/var/lib/postfix-webmin/tls"
        )
        self.assertEqual(status, 0, output)
        quadlet = self.quadlet.read_text()
        self.assertIn("Volume=/var/lib/postfix-webmin/tls:/run/webmin-tls:ro,Z", quadlet)
        self.assertIn("Environment=WEBMIN_TLS_DIR=/run/webmin-tls", quadlet)
        self.assertNotIn("podman build", self.commands())
        self.assertNotIn("WARNING: WEBMIN_TLS_DIR is unset", output)

    def test_deploy_rejects_unusable_tls_before_stopping_service(self):
        for variables in (
            {"WEBMIN_TLS_DIR": "relative/path"},
            {"WEBMIN_TLS_DIR": "/tls\n[Service]"},
            {"WEBMIN_TLS_DIR": "/tls", "TEST_TLS_FILES": "0"},
            {"WEBMIN_TLS_DIR": "", "TEST_TLS_ENABLED": "1"},
        ):
            with self.subTest(variables=variables):
                status, output = self.run_stage("deploy.sh", UPDATE_EXISTING="1", **variables)
                self.assertNotEqual(status, 0, output)
                self.assertNotIn("systemctl --user stop", self.commands())
                self.assertFalse(self.quadlet.exists())

    def test_deploy_existing_image_without_build_or_password_reset(self):
        status, output = self.run_stage(
            "deploy.sh", UPDATE_EXISTING="1", WEBMIN_BIND_ADDRESS="10.50.1.20"
        )
        self.assertEqual(status, 0, output)
        commands = self.commands()
        self.assertNotIn("podman build", commands)
        self.assertNotIn("podman run", commands)
        self.assertNotIn("podman volume rm", commands)
        self.assertIn("systemctl --user stop", commands)
        self.assertIn("systemctl --user start", commands)
        quadlet = self.quadlet.read_text()
        self.assertIn("PublishPort=10.50.1.20:10000:10000", quadlet)
        self.assertIn("WantedBy=default.target", quadlet)

    def test_fresh_deploy_initializes_password_before_start(self):
        status, output = self.run_stage(
            "deploy.sh", interactive=True, TEST_VOLUMES="none", TEST_CONTAINER="0"
        )
        self.assertEqual(status, 0, output)
        self.assertIn("WARNING: WEBMIN_TLS_DIR is unset", output)
        self.assertIn("generates a unique self-signed certificate at first startup", output)
        self.assertIn("reuses it from its persistent volume on later starts", output)
        commands = self.commands()
        self.assertLess(commands.index("podman run"), commands.index("systemctl --user start"))
        self.assertNotIn("systemctl --user stop", commands)
        self.assertNotIn("podman build", commands)

    def test_wrapper_orders_stages_and_stops_on_failure(self):
        for failing in ("none", "platform-setup.sh", "build-image.sh", "deploy.sh"):
            with self.subTest(failing=failing):
                self.log.unlink(missing_ok=True)
                stages = ("platform-setup.sh", "build-image.sh", "deploy.sh")
                for stage in stages:
                    (self.project / stage).write_text(
                        '#!/usr/bin/env bash\n'
                        'printf "%s %s\\n" "$(basename "$0")" "$WEBMIN_BIND_ADDRESS" >> "$TEST_LOG"\n'
                        f'exit {7 if stage == failing else 0}\n'
                    )
                    (self.project / stage).chmod(0o755)
                status, output = self.run_stage(
                    "setup.sh", WEBMIN_BIND_ADDRESS="10.50.1.20"
                )
                self.assertEqual(status, 0 if failing == "none" else 7, output)
                expected = stages if failing == "none" else stages[:stages.index(failing) + 1]
                self.assertEqual(
                    self.commands().splitlines(),
                    [stage + " 10.50.1.20" for stage in expected],
                )


@unittest.skipUnless(os.environ.get("POSTFIX_WEBMIN_TEST_IMAGE"), "Set POSTFIX_WEBMIN_TEST_IMAGE for live SMTP testing")
class ContainerTests(unittest.TestCase):
    def test_webmin_certificate_is_generated_per_installation(self):
        image = os.environ["POSTFIX_WEBMIN_TEST_IMAGE"]
        defaults = subprocess.run(
            ["podman", "run", "--rm", "--entrypoint", "/bin/sh", image, "-c",
             "test ! -e /etc/webmin/miniserv.pem && "
             "test -z \"$(find /var/webmin /usr/share/postfix-webmin-defaults/webmin-state "
             "-type f -print -quit)\""],
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(defaults.returncode, 0, defaults.stderr)

        prefix = "postfix-webmin-cert-test-" + uuid.uuid4().hex[:8]
        names = [prefix + suffix for suffix in ("-first", "-upgrade", "-restart", "-other")]
        volumes = [prefix + suffix for suffix in ("-volume-a", "-volume-b")]

        def start(name, volume):
            subprocess.run(
                ["podman", "run", "--rm", "-d", "--network", "none", "--name", name,
                 "--volume", f"{volume}:/etc/webmin:Z", image],
                check=True, capture_output=True, text=True, timeout=30,
            )

        def fingerprint(name):
            error = "certificate marker was not created"
            for _ in range(40):
                marker = subprocess.run(
                    ["podman", "exec", name, "test", "-e",
                     "/etc/webmin/.postfix-webmin-self-signed"],
                    capture_output=True, text=True, timeout=10,
                )
                if marker.returncode == 0:
                    ready = subprocess.run(
                        ["podman", "exec", name, "curl", "-kfsS",
                         "https://127.0.0.1:10000/"],
                        capture_output=True, text=True, timeout=10,
                    )
                    if ready.returncode == 0:
                        result = subprocess.run(
                            ["podman", "exec", name, "openssl", "x509", "-in",
                             "/etc/webmin/miniserv.pem", "-noout", "-fingerprint", "-sha256"],
                            capture_output=True, text=True, timeout=10,
                        )
                        if result.returncode == 0:
                            return result.stdout.strip()
                    else:
                        error = ready.stderr
                else:
                    error = marker.stderr
                time.sleep(0.25)
            self.fail(f"Webmin did not create a ready HTTPS endpoint: {error}")

        try:
            for volume in volumes:
                subprocess.run(
                    ["podman", "volume", "create", volume],
                    check=True, capture_output=True, text=True, timeout=30,
                )

            start(names[0], volumes[0])
            original = fingerprint(names[0])
            subprocess.run(
                ["podman", "exec", names[0], "rm", "/etc/webmin/.postfix-webmin-self-signed"],
                check=True, capture_output=True, text=True, timeout=10,
            )
            subprocess.run(
                ["podman", "rm", "--force", names[0]],
                check=True, capture_output=True, text=True, timeout=30,
            )

            start(names[1], volumes[0])
            rotated = fingerprint(names[1])
            self.assertNotEqual(original, rotated)
            subprocess.run(
                ["podman", "rm", "--force", names[1]],
                check=True, capture_output=True, text=True, timeout=30,
            )

            start(names[2], volumes[0])
            self.assertEqual(fingerprint(names[2]), rotated)
            start(names[3], volumes[1])
            self.assertNotEqual(fingerprint(names[3]), rotated)
        finally:
            subprocess.run(
                ["podman", "rm", "--force", *names],
                capture_output=True, timeout=30,
            )
            subprocess.run(
                ["podman", "volume", "rm", "--force", *volumes],
                capture_output=True, timeout=30,
            )

    def test_published_smtp_port_returns_greeting(self):
        image = os.environ["POSTFIX_WEBMIN_TEST_IMAGE"]
        name = "postfix-webmin-smtp-test-" + uuid.uuid4().hex[:8]
        try:
            subprocess.run(
                ["podman", "run", "--rm", "-d", "--init", "--name", name,
                 "--publish", "127.0.0.1::25", image],
                check=True, capture_output=True, text=True, timeout=30,
            )
            mapping = subprocess.check_output(
                ["podman", "port", name, "25/tcp"], text=True
            )
            port = int(mapping.strip().rsplit(":", 1)[1])
            error = "No greeting"
            for _ in range(40):
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=1) as conn:
                        conn.settimeout(1)
                        greeting = conn.recv(4096)
                        if greeting.startswith(b"220 "):
                            conn.sendall(b"QUIT\r\n")
                            return
                        error = repr(greeting)
                except OSError as exc:
                    error = str(exc)
                time.sleep(0.25)
            self.fail("Published SMTP port did not return a 220 greeting: " + error)
        finally:
            subprocess.run(["podman", "rm", "--force", name], capture_output=True, timeout=30)


if __name__ == "__main__":
    unittest.main()
