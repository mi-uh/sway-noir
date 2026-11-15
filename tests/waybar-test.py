#!/usr/bin/env python3
"""Validate Waybar configuration and keep the desktop free of icon fonts."""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parent.parent
CONFIG_DIRECTORIES = (
    "fuzzel", "gammastep", "mako", "session", "sway", "swaylock",
    "systemd", "themes", "waybar", "xdg-desktop-portal",
)


def load_jsonc(text):
    # Preserve quoted strings (including URLs and escaped quotes) while removing
    # comments and trailing commas accepted by Waybar's JSONC reader.
    strings_or_comments = r'"(?:\\.|[^"\\])*"|//[^\r\n]*|/\*[\s\S]*?\*/'
    text = re.sub(
        strings_or_comments,
        lambda match: match[0] if match[0].startswith('"') else " ",
        text,
    )
    text = re.sub(
        r'"(?:\\.|[^"\\])*"|,\s*(?=[}\]])',
        lambda match: match[0] if match[0].startswith('"') else "",
        text,
    )
    return json.loads(text)


def private_use_characters(text):
    return {
        character for character in text
        if 0xE000 <= ord(character) <= 0xF8FF
        or 0xF0000 <= ord(character) <= 0xFFFFD
        or 0x100000 <= ord(character) <= 0x10FFFD
    }


class WaybarTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.configuration_texts = {}
        for directory in CONFIG_DIRECTORIES:
            for path in (REPO_ROOT / directory).rglob("*"):
                if path.is_file() and path.suffix not in {".png", ".webp"}:
                    cls.configuration_texts[path.relative_to(REPO_ROOT)] = path.read_text(
                        encoding="utf-8"
                    )
        # Parse rendered configurations, including numeric template values.
        cls.configurations = {}
        with tempfile.TemporaryDirectory(
            prefix="sway-noir-waybar-",
            dir="/tmp/opencode" if os.access("/tmp/opencode", os.W_OK) else None,
        ) as directory:
            for theme in ("rain", "praxis", "retro"):
                subprocess.run(
                    [str(REPO_ROOT / "session/theme"), "set", theme, "--no-reload"],
                    env={**os.environ, "XDG_STATE_HOME": directory}, check=True,
                    capture_output=True, text=True, timeout=10,
                )
                config = Path(directory) / "sway-noir/current/waybar/config.jsonc"
                cls.configurations[theme] = load_jsonc(config.read_text())
        cls.config = cls.configurations["rain"]

    def test_no_icon_font_references(self):
        pattern = re.compile(r"font\s*awesome|nerd\s*fonts?", re.IGNORECASE)
        for path, text in self.configuration_texts.items():
            with self.subTest(path=path):
                self.assertNotRegex(text, pattern)
        self.assertNotRegex(json.dumps(self.config, ensure_ascii=False), pattern)

    def test_no_private_use_characters(self):
        for path, text in self.configuration_texts.items():
            with self.subTest(path=path):
                self.assertFalse(private_use_characters(text))
        # JSON escape sequences must not hide private-use glyphs either.
        self.assertFalse(private_use_characters(json.dumps(self.config, ensure_ascii=False)))

    def test_right_module_order_for_all_profiles(self):
        for theme, config in self.configurations.items():
            with self.subTest(theme=theme):
                self.assertEqual(config["modules-right"], [
                    "pulseaudio", "network", "battery", "cpu", "memory", "tray", "clock",
                ])

    def test_plain_text_network_status(self):
        label = self.config["network"]["format-disconnected"]
        self.assertRegex(label, r"[A-Za-z]{2,}")
        self.assertFalse(private_use_characters(label))

    def test_font_fallback(self):
        self.assertRegex(
            self.configuration_texts[Path("waybar/style.css")],
            r'font-family:\s*"\{\{font\}\}",\s*sans-serif\s*;',
        )
        self.assertIn("font=IBM Plex Sans", self.configuration_texts[Path("themes/rain/theme.conf")])

    def test_private_use_detection_covers_all_planes(self):
        for codepoint in (0xE000, 0xF8FF, 0xF0000, 0xFFFFD, 0x100000, 0x10FFFD):
            with self.subTest(codepoint=codepoint):
                self.assertEqual(private_use_characters(chr(codepoint)), {chr(codepoint)})
        self.assertFalse(private_use_characters("IBM Plex Sans – NET down"))
        escaped = load_jsonc(r'{"icon": "\ue000"}')
        self.assertTrue(private_use_characters(escaped["icon"]))

    def test_jsonc_reader_preserves_strings(self):
        parsed = load_jsonc(r'''{
            // line comment
            "url": "https://example.org/", /* block comment */
            "text": "a \"quoted\" string,}",
            "values": [1, 2,],
        }''')
        self.assertEqual(parsed["url"], "https://example.org/")
        self.assertEqual(parsed["text"], 'a "quoted" string,}')
        self.assertEqual(parsed["values"], [1, 2])


if __name__ == "__main__":
    unittest.main()
