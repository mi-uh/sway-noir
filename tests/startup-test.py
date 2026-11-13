#!/usr/bin/env python3
"""Exercise the startup exec's shell boundary without starting a desktop."""

import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent


class StartupCommand(unittest.TestCase):
    def test_profile_path_and_command_arguments_survive_shell_expansion(self):
        lines = (ROOT / "sway/config.d/99-startup.conf").read_text().splitlines()
        commands = [line.removeprefix("exec ") for line in lines if line.startswith("exec ")]
        self.assertEqual(len(commands), 1)

        with tempfile.TemporaryDirectory(
            prefix="sway-noir-startup-",
            dir="/tmp/opencode" if os.access("/tmp/opencode", os.W_OK) else None,
        ) as temporary:
            directory = Path(temporary)
            for name in ("config", "config with spaces", "config $literal; [test]"):
                with self.subTest(path=name):
                    profile = directory / name / "sway-noir"
                    session = profile / "session"
                    session.mkdir(parents=True)
                    entrypoint = session / "start-session"
                    entrypoint.write_text(
                        '#!/usr/bin/bash\nset -eu\nprintf "%s\\0" "$@" > "$STARTUP_LOG"\n'
                    )
                    entrypoint.chmod(0o755)
                    log = directory / "arguments"
                    gammastep = [
                        str(session / "optional-command"), "night-color", "gammastep",
                        "-c", str(profile / "gammastep/config.ini"),
                    ]
                    values = {
                        "lock_command": "lock-screen --ready",
                        "audio_settings_command": "audio-settings --option",
                        "polkit_agent_command": "polkit-agent --option",
                        "gammastep_command": shlex.join(gammastep),
                    }
                    command = commands[0]
                    # Sway substitutes its configured command variables before
                    # /bin/sh expands the exported SWAY_NOIR_DIR environment.
                    for key, value in values.items():
                        command = command.replace("$" + key, value)
                    result = subprocess.run(
                        ["/bin/sh", "-c", command], capture_output=True, text=True,
                        env={**os.environ, "SWAY_NOIR_DIR": str(profile), "STARTUP_LOG": str(log)},
                        timeout=10,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    arguments = log.read_bytes().decode().split("\0")[:-1]
                    self.assertEqual(arguments, [
                        values["lock_command"], values["audio_settings_command"],
                        values["polkit_agent_command"], *gammastep,
                    ])
                    log.unlink()


if __name__ == "__main__":
    unittest.main()
