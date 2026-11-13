#!/usr/bin/env python3
"""Exercise optional PolicyKit startup with unprivileged mock agents only."""

import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parent.parent
AGENT_BODY = '''printf 'agent\\n' >> "$CORE_LOG"
printf '%s\\n' "$@" > "$AGENT_ARGUMENTS"
printf '%s\\n' "$EUID" > "$AGENT_UID"
if [[ "${AGENT_WAIT:-0}" == 1 ]]; then
    trap 'printf stopped > "$AGENT_STOPPED"; exit 0' TERM HUP INT
    : > "$AGENT_READY"
    while true; do sleep 0.02; done
fi
'''


@unittest.skipIf(os.geteuid() == 0, "Run desktop/agent tests as a normal user")
class PolicyKitTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.profile = self.directory / "profile"
        shutil.copytree(ROOT / "session", self.profile / "session")
        self.libexec = self.directory / "libexec/lxqt-policykit-agent"
        self.libexec.parent.mkdir()
        library = self.profile / "session/dependencies.sh"
        library.write_text(library.read_text().replace("/usr/libexec/", str(self.libexec.parent) + "/"))
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        for command in ("dirname", "sleep"):
            (self.bin / command).symlink_to(shutil.which(command))
        for command in ("swayidle", "waybar", "mako"):
            self.script(self.bin / command, f"printf '{command}\\n' >> \"$CORE_LOG\"\n")
        self.script(self.bin / "lxqt-policykit-agent", AGENT_BODY)
        self.environment = {
            **os.environ, "PATH": str(self.bin), "CORE_LOG": str(self.directory / "core.log"),
            "AGENT_ARGUMENTS": str(self.directory / "agent-arguments"),
            "AGENT_UID": str(self.directory / "agent-uid"),
            "AGENT_READY": str(self.directory / "ready"),
            "AGENT_STOPPED": str(self.directory / "stopped"), "AGENT_WAIT": "0",
            "SWAY_NOIR_SESSION_ID": "1-2-3", "XDG_CONFIG_HOME": str(self.directory / "config"),
        }

    def script(self, path, body):
        path.write_text("#!/usr/bin/bash\n" + body)
        path.chmod(0o755)

    def run_desktop(self, agent="lxqt-policykit-agent", gamma=("true",)):
        return subprocess.run(
            [str(self.profile / "session/run-apps"), "lock-screen --ready", agent, *gamma],
            env=self.environment, capture_output=True, text=True, timeout=5,
        )

    def assert_core_started(self):
        lines = (self.directory / "core.log").read_text().splitlines()
        for name in ("swayidle", "waybar", "mako"):
            self.assertEqual(lines.count(name), 1)
        return lines

    def test_agent_starts_exactly_once_as_current_user(self):
        result = self.run_desktop()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.assert_core_started().count("agent"), 1)
        self.assertEqual(int((self.directory / "agent-uid").read_text()), os.geteuid())
        self.assertNotEqual(os.geteuid(), 0)

    def test_override_preserves_command_path_and_arguments(self):
        override = self.directory / "custom agent"
        self.script(override, AGENT_BODY)
        result = self.run_desktop(shlex.quote(str(override)) + " --custom 'two words'")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.assert_core_started().count("agent"), 1)
        self.assertEqual((self.directory / "agent-arguments").read_text().splitlines(), ["--custom", "two words"])

    def test_default_agent_falls_back_to_fedora_libexec(self):
        (self.bin / "lxqt-policykit-agent").unlink()
        self.script(self.libexec, AGENT_BODY)
        result = self.run_desktop()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.assert_core_started().count("agent"), 1)
        self.assertEqual(result.stderr, "")

    def test_path_agent_takes_precedence_over_libexec(self):
        self.script(self.libexec, "exit 99\n")
        result = self.run_desktop()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.assert_core_started().count("agent"), 1)
        self.assertEqual(result.stderr, "")

    def test_missing_custom_agent_is_not_replaced_by_default(self):
        self.script(self.libexec, AGENT_BODY)
        result = self.run_desktop("missing-custom-agent --flag")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("agent", self.assert_core_started())
        self.assertIn("PolicyKit authentication agent command is unavailable", result.stderr)

    def test_disabled_and_empty_agent_do_not_start(self):
        for command in ("true", ""):
            with self.subTest(command=command):
                (self.directory / "core.log").write_text("")
                result = self.run_desktop(command)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("agent", self.assert_core_started())
                self.assertFalse((self.directory / "agent-arguments").exists())
                self.assertEqual(result.stderr, "")

    def test_missing_optional_agent_and_night_color_do_not_block_core(self):
        (self.bin / "lxqt-policykit-agent").unlink()
        result = self.run_desktop(gamma=(str(ROOT / "session/optional-command"), "night-color", "gammastep"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("agent", self.assert_core_started())
        self.assertIn("PolicyKit authentication agent command is unavailable", result.stderr)
        self.assertIn("night-color requires gammastep", result.stderr)

    def test_startup_passes_overrides_to_session_specific_service(self):
        self.script(self.bin / "systemctl", "exit 0\n")
        self.script(self.bin / "dbus-update-activation-environment", "exit 0\n")
        self.script(self.bin / "systemd-run", 'printf "%s\\0" "$@" > "$RUN_LOG"\n')
        self.environment["RUN_LOG"] = str(self.directory / "run.log")
        agent = "/custom/agent --option 'value with spaces'"
        audio = "custom-audio-settings --flag"
        result = subprocess.run(
            [str(ROOT / "session/start-session"), "lock-screen --ready", audio, agent, "true"],
            env=self.environment, capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = (self.directory / "run.log").read_bytes().decode().split("\0")[:-1]
        self.assertIn("--unit=sway-noir-apps-1-2-3.service", arguments)
        self.assertIn("--property=PartOf=sway-noir-session.target", arguments)
        self.assertIn("--property=KillMode=control-group", arguments)
        self.assertIn("--expand-environment=no", arguments)
        self.assertIn(f"--setenv=SWAY_NOIR_AUDIO_SETTINGS_COMMAND={audio}", arguments)
        self.assertEqual(arguments[-3:], ["lock-screen --ready", agent, "true"])
        startup = (ROOT / "sway/config.d/99-startup.conf").read_text()
        self.assertEqual(sum(line.startswith("exec ") for line in startup.splitlines()), 1)
        self.assertNotIn("exec_always", startup)
        self.assertIn('"$polkit_agent_command"', startup)

    def test_agent_terminates_with_desktop_process_group(self):
        # Model systemd's control-group stop with an isolated test process group.
        # No host systemd service or real authentication agent is used.
        self.environment["AGENT_WAIT"] = "1"
        process = subprocess.Popen(
            [str(self.profile / "session/run-apps"), "lock-screen --ready", "lxqt-policykit-agent", "true"],
            env=self.environment, start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        try:
            deadline = time.monotonic() + 5
            while not (self.directory / "ready").exists() and time.monotonic() < deadline:
                self.assertIsNone(process.poll(), "desktop exited before starting the agent")
                time.sleep(0.01)
            self.assertTrue((self.directory / "ready").exists(), "mock agent was not ready")
            os.killpg(process.pid, signal.SIGTERM)
            process.communicate(timeout=5)
            self.assertEqual((self.directory / "stopped").read_text(), "stopped")
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()
