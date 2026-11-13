#!/usr/bin/env python3
"""Execute configured audio commands against a mock, never the host audio server."""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
EXPECTED = {
    "XF86AudioMute": ["set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"],
    "XF86AudioLowerVolume": ["set-volume", "@DEFAULT_AUDIO_SINK@", "5%-"],
    "XF86AudioRaiseVolume": ["set-volume", "--limit", "1.0", "@DEFAULT_AUDIO_SINK@", "5%+"],
    "XF86AudioMicMute": ["set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle"],
}


class AudioTests(unittest.TestCase):
    def test_generated_audio_commands(self):
        bindings = (ROOT / "sway/config.d/60-keybindings.conf").read_text()
        config = (ROOT / "sway/config").read_text()
        variables = dict(re.findall(r"^set (\$\w+) (.+)$", config, re.MULTILINE))
        with tempfile.TemporaryDirectory() as directory:
            mock = Path(directory) / "wpctl"
            log = Path(directory) / "arguments"
            mock.write_text('#!/usr/bin/bash\nprintf "%s\\n" "$@" > "$WPCTL_LOG"\n')
            mock.chmod(0o755)
            environment = {
                **os.environ, "PATH": directory, "WPCTL_LOG": str(log),
                "SWAY_NOIR_DIR": str(ROOT),
            }
            for key, expected in EXPECTED.items():
                with self.subTest(key=key):
                    lines = [line for line in bindings.splitlines() if f" {key} exec " in line]
                    self.assertEqual(len(lines), 1)
                    line = lines[0]
                    self.assertEqual("--locked" in line, key != "XF86AudioMicMute")
                    command = line.split(" exec ", 1)[1]
                    for name, value in variables.items():
                        command = command.replace(name, value)
                    subprocess.run(["/usr/bin/bash", "-c", command], env=environment, check=True)
                    self.assertEqual(log.read_text().splitlines(), expected)

    def test_no_pulse_cli_dependency(self):
        for path in ("sway/config.d/60-keybindings.conf", "dependencies.list", "install.sh", "README.md"):
            text = (ROOT / path).read_text()
            self.assertNotRegex(text, r"\bpactl\b|pulseaudio-utils")


if __name__ == "__main__":
    unittest.main()
