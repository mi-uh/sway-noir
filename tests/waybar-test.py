#!/usr/bin/env python3
"""Validate Waybar configuration and keep the desktop free of icon fonts."""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

from waybar_config import load_jsonc, load_waybar_config


REPO_ROOT = Path(__file__).resolve().parent.parent
CONFIG_DIRECTORIES = (
    "fuzzel", "gammastep", "mako", "session", "sway", "swaylock",
    "systemd", "themes", "waybar", "xdg-desktop-portal",
)


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
                cls.configurations[theme] = load_waybar_config(config)
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

    def test_hardware_defaults_are_shared_and_theme_overrides_only_define_appearance(self):
        for theme, config in self.configurations.items():
            with self.subTest(theme=theme):
                for module, command in (("custom/cpu", "cpu"), ("custom/gpu", "gpu")):
                    self.assertEqual(config[module]["exec"],
                                     f'"$SWAY_NOIR_DIR/session/hardware-status" {command}')
                    self.assertEqual(config[module]["interval"], 3)
                    self.assertFalse(config[module]["tooltip"])
                    for position in ("left", "center", "right"):
                        self.assertNotIn(module, config[f"modules-{position}"])
        # Copying the example must not pin GPU appearance against the theme.
        example = self.configuration_texts[Path("waybar/local.jsonc.example")]
        for key in ("format", "align", "justify"):
            self.assertNotIn(f'"{key}":', example)

    def test_theme_overrides_do_not_duplicate_shared_behavior(self):
        for filename in ("waybar/config.jsonc", "themes/praxis/waybar/config.jsonc",
                         "themes/retro/waybar/config.jsonc"):
            with self.subTest(path=filename):
                config = load_jsonc(self.configuration_texts[Path(filename)])
                self.assertEqual(config["include"], '"${SWAY_NOIR_THEME_DIR}/waybar/base.jsonc"')
                for key in ("layer", "position", "spacing", "reload_style_on_change", "sway/workspaces",
                            "modules-left", "modules-center", "modules-right", "margin-top", "margin-bottom"):
                    self.assertNotIn(key, config)
                for module, keys in {"cpu": ("interval", "tooltip"), "memory": ("interval",),
                                     "custom/cpu": ("exec", "interval", "tooltip"),
                                     "custom/gpu": ("exec", "interval", "tooltip"),
                                     "pulseaudio": ("on-click", "scroll-step"), "battery": ("states",),
                                     "clock": ("format", "tooltip-format")}.items():
                    for key in keys:
                        self.assertNotIn(key, config.get(module, {}))

    def test_include_reader_preserves_overrides_and_first_include_wins(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = root / "first.jsonc"
            second = root / "second.jsonc"
            config = root / "config.jsonc"
            first.write_text(json.dumps({"cpu": {"format": "first", "interval": 3},
                                         "modules-right": ["cpu"], "height": 30}))
            second.write_text(json.dumps({"cpu": {"format": "second", "tooltip": False},
                                          "modules-right": ["clock"], "height": 40}))
            config.write_text(json.dumps({"include": [str(first), str(second)],
                                          "cpu": {"format": "custom"}, "height": None}))
            self.assertEqual(load_waybar_config(config), {
                "cpu": {"format": "custom", "interval": 3, "tooltip": False},
                "modules-right": ["cpu"], "height": None,
            })

    def test_include_reader_preserves_quoted_directory_and_detects_cycles(self):
        with tempfile.TemporaryDirectory() as directory:
            theme_dir = Path(directory) / 'spaces $dollar "quotes" $(not-a-command)'
            bar = theme_dir / "waybar"
            bar.mkdir(parents=True)
            config = bar / "config.jsonc"
            base = bar / "base.jsonc"
            config.write_text(json.dumps({"include": '"${SWAY_NOIR_THEME_DIR}/waybar/base.jsonc"'}))
            base.write_text('{"height": 34}')
            self.assertEqual(load_waybar_config(config), {"height": 34})
            base.write_text(json.dumps({"include": '"${SWAY_NOIR_THEME_DIR}/waybar/config.jsonc"'}))
            with self.assertRaisesRegex(ValueError, "Recursive Waybar include"):
                load_waybar_config(config)

    def test_font_fallback(self):
        self.assertRegex(
            self.configuration_texts[Path("waybar/style.css")],
            r'font-family:\s*"\{\{font\}\}",\s*sans-serif\s*;',
        )
        self.assertIn("font=IBM Plex Sans", self.configuration_texts[Path("themes/rain/theme.conf")])

    def test_new_right_hand_modules_share_cpu_styling_in_every_theme(self):
        for filename in ("waybar/style.css", "themes/praxis/waybar/style.css",
                         "themes/retro/waybar/style.css"):
            with self.subTest(path=filename):
                css = self.configuration_texts[Path(filename)]
                css = re.sub(r"/\*[\s\S]*?\*/", "", css)
                rules = [(selectors.split(","), body)
                         for selectors, body in re.findall(r"([^{}]+)\{([^{}]*)\}", css)]
                # Match the module child of the EventBox, not nested labels,
                # tray icons or workspace buttons. No per-module CSS is needed.
                status_rules = [body for selectors, body in rules
                                if ".modules-right > widget > *" in
                                [selector.strip() for selector in selectors]]
                self.assertEqual(len(status_rules), 1)
                self.assertIn("padding:", status_rules[0])
                self.assertNotIn("#custom-gpu", css)
                cpu_rules = [body for selectors, body in rules
                             if "#cpu" in [selector.strip() for selector in selectors]]
                self.assertIn(status_rules[0], cpu_rules)

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
