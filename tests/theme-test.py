#!/usr/bin/env python3
"""Exercise rendering and live reload with isolated state and mock desktops."""

import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
import xml.etree.ElementTree as ET

from waybar_config import load_waybar_config


ROOT = Path(__file__).resolve().parent.parent
BUNDLED_THEMES = ("praxis", "rain", "retro")


class Themes(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(
            prefix="sway-noir-themes-",
            dir="/tmp/opencode" if os.access("/tmp/opencode", os.W_OK) else None,
        )
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.profile = self.directory / "config with spaces/sway-noir"
        for name in ("session", "sway", "swaylock", "waybar", "fuzzel", "mako", "themes"):
            shutil.copytree(ROOT / name, self.profile / name)
        self.state = self.directory / "state with spaces/sway-noir"
        self.current = self.state / "current"
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.log = self.directory / "commands"
        self.environment = {
            **os.environ,
            "HOME": str(self.directory / "home"),
            "XDG_STATE_HOME": str(self.state.parent),
            "SWAY_NOIR_DIR": str(self.profile),
            "SWAY_NOIR_THEME_DIR": str(self.current),
            "SWAY_NOIR_SESSION_ID": "1-2-3", "SWAYSOCK": "/mock/sway.sock",
            "PATH": str(self.bin) + ":" + os.environ["PATH"],
            "THEME_LOG": str(self.log),
        }
        self.script("sway", 'printf "validate %s\\n" "$*" >> "$THEME_LOG"\nexit "${FAIL_VALIDATE:-0}"\n')
        self.script("swaymsg", 'printf "swaymsg %s\\n" "$*" >> "$THEME_LOG"\nexit "${FAIL_RELOAD:-0}"\n')
        self.script("systemctl", 'printf "systemctl %s\\n" "$*" >> "$THEME_LOG"\nexit "${FAIL_UI:-0}"\n')
        self.script("fuzzel", 'menu="$THEME_LOG.menu"\nindex="${MENU_INDEX:-0}"\nstatus="${MENU_STATUS:-0}"\n'
                    'for argument; do\n'
                    '  if [[ "$argument" == "--prompt=waybar: " ]]; then\n'
                    '    menu="$THEME_LOG.position-menu"\n'
                    '    index="${POSITION_INDEX:-0}"\nstatus="${POSITION_STATUS:-0}"\n'
                    '  fi\ndone\n'
                    'cat > "$menu"\nprintf "%s\\n" "$index"\nexit "$status"\n')

    def script(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/bash\nset -eu\n" + body)
        path.chmod(0o755)

    def run_theme(self, *arguments, success=True, **environment):
        result = subprocess.run(
            [str(self.profile / "session/theme"), *arguments],
            env={**self.environment, **environment}, capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode == 0, success, result.stderr)
        return result

    def assert_complete(self):
        self.assertTrue(self.current.is_symlink())
        for path in self.current.rglob("*"):
            if path.is_file():
                self.assertNotIn("{{", path.read_text(), str(path))
        self.assertEqual(len([path for path in self.state.glob("theme.*") if path.is_dir()]), 1)

    def test_inspection_is_read_only_and_default_is_rain(self):
        self.assertEqual(self.run_theme("list").stdout.splitlines(), list(BUNDLED_THEMES))
        self.assertEqual(self.run_theme("current").stdout, "rain\n")
        self.assertEqual(self.run_theme("bar-position").stdout, "default\n")
        self.assertFalse(self.state.exists())

    def test_rain_render_preserves_palette_and_geometry(self):
        self.run_theme("init")
        self.assert_complete()
        sway = (self.current / "sway.conf").read_text()
        self.assertIn("set $accent    #9b2c3d", sway)
        self.assertIn("gaps inner 8", sway)
        self.assertIn("font pango:IBM Plex Sans 10", sway)
        self.assertIn('"$SWAY_NOIR_DIR/sway/backgrounds/cozy-cyberpunk-room.png"', sway)
        css = (self.current / "waybar/style.css").read_text()
        self.assertIn('font-family: "IBM Plex Sans", sans-serif;', css)
        self.assertIn("border-radius: 8px;", css)
        self.assertIn("background=111315f2", (self.current / "fuzzel/fuzzel.ini").read_text())
        self.assertIn("border-color=#9b2c3dff", (self.current / "mako/config").read_text())
        self.assertIn(f"image={self.profile}/swaylock/cozy-cyberpunk-room-lock.png", (self.current / "swaylock/config").read_text())
        self.assertEqual(load_waybar_config(self.current / "waybar/config.jsonc")["position"], "top")
        self.assertFalse(self.log.exists())

    def test_saved_original_theme_migrates_to_rain(self):
        self.run_theme("init")
        (self.current / "theme-id").write_text("noir\n")
        self.assertEqual(self.run_theme("current").stdout, "rain\n")
        # Inspecting the selection must not mutate saved state.
        self.assertEqual((self.current / "theme-id").read_text(), "noir\n")
        result = self.run_theme("init")
        self.assertEqual(result.stdout, "rain\n")
        self.assertEqual(result.stderr, "")
        self.assertEqual((self.current / "theme-id").read_text(), "rain\n")
        self.assertEqual(self.run_theme("list").stdout.splitlines(), list(BUNDLED_THEMES))
        self.assert_complete()

    def test_personal_theme_using_former_id_is_preserved(self):
        personal = self.profile / "themes/noir"
        personal.mkdir()
        (personal / "theme.conf").write_text("name=Personal Theme\naccent=#6688aa\n")
        self.run_theme("set", "noir", "--no-reload")
        self.assertEqual(self.run_theme("current").stdout, "noir\n")
        self.run_theme("init")
        self.assertEqual((self.current / "theme-id").read_text(), "noir\n")
        self.assertIn("set $accent    #6688aa", (self.current / "sway.conf").read_text())

    def test_live_switch_and_saved_theme_refresh(self):
        self.run_theme("init")
        self.run_theme("set", "retro")
        self.assert_complete()
        self.assertEqual(self.run_theme("current").stdout, "retro\n")
        self.assertEqual(load_waybar_config(self.current / "waybar/config.jsonc")["position"], "bottom")
        self.assertIn('output * background "$SWAY_NOIR_DIR/themes/retro/wallpaper.png" fill #080d0b',
                      (self.current / "sway.conf").read_text())
        self.assertIn(f"image={self.profile}/themes/retro/lock-screen.png",
                      (self.current / "swaylock/config").read_text())
        self.assertIn("@define-color accent #68b884", (self.current / "waybar/style.css").read_text())
        log = self.log.read_text()
        self.assertIn("validate --validate --config", log)
        self.assertIn("swaymsg -r reload", log)
        self.assertIn("systemctl --user kill --kill-whom=main --signal=USR2 sway-noir-apps-1-2-3.service", log)
        self.assertNotIn("restart", log)
        self.assertNotIn("portal", log)
        self.run_theme("init")
        self.assertEqual(self.run_theme("current").stdout, "retro\n")
        self.assert_complete()

    def test_legacy_state_without_bar_position_uses_theme_defaults(self):
        self.run_theme("set", "retro", "--no-reload")
        (self.current / "bar-position").unlink()
        original = self.current.resolve()
        self.assertEqual(self.run_theme("bar-position").stdout, "default\n")
        self.assertEqual(self.current.resolve(), original)
        self.assertFalse((self.current / "bar-position").exists())
        self.run_theme("init")
        self.assertEqual((self.current / "bar-position").read_text(), "default\n")
        self.assertEqual(load_waybar_config(self.current / "waybar/config.jsonc")["position"], "bottom")
        self.assert_complete()

    def test_fixed_bar_positions_survive_all_theme_switches_and_login(self):
        for position in ("top", "bottom"):
            self.assertEqual(self.run_theme("bar-position", position).stdout, position + "\n")
            for theme in BUNDLED_THEMES:
                with self.subTest(position=position, theme=theme):
                    self.run_theme("set", theme)
                    self.run_theme("init")
                    self.assertEqual(self.run_theme("current").stdout, theme + "\n")
                    self.assertEqual(self.run_theme("bar-position").stdout, position + "\n")
                    config = load_waybar_config(self.current / "waybar/config.jsonc")
                    self.assertEqual(config["position"], position)
                    self.assertEqual(config["margin-top"], 8 if theme == "rain" and position == "top" else 0)
                    self.assertEqual(config["margin-bottom"], 8 if theme == "rain" and position == "bottom" else 0)
                    self.assertEqual(config["margin-left"], 8 if theme == "rain" else 0)
                    self.assertEqual(config["margin-right"], 8 if theme == "rain" else 0)
                    self.assert_complete()
        log = self.log.read_text()
        self.assertIn("swaymsg -r reload", log)
        self.assertIn("--signal=USR2", log)

    def test_default_bar_position_restores_each_themes_layout(self):
        for theme in BUNDLED_THEMES:
            with self.subTest(theme=theme):
                self.run_theme("set", theme, "--no-reload")
                original = load_waybar_config(self.current / "waybar/config.jsonc")
                self.run_theme("bar-position", "bottom" if theme == "rain" else "top", "--no-reload")
                self.assertEqual(self.run_theme("bar-position", "default", "--no-reload").stdout, "default\n")
                self.assertEqual(load_waybar_config(self.current / "waybar/config.jsonc"), original)
                self.assertEqual(self.run_theme("current").stdout, theme + "\n")
                self.assert_complete()
        self.assertFalse(self.log.exists())

    def test_offline_bar_position_can_be_set_before_first_login(self):
        self.run_theme("bar-position", "bottom", "--no-reload", SWAYSOCK="", SWAY_NOIR_SESSION_ID="")
        self.assertEqual(self.run_theme("current").stdout, "rain\n")
        self.run_theme("init")
        self.assertEqual(self.run_theme("bar-position").stdout, "bottom\n")
        config = load_waybar_config(self.current / "waybar/config.jsonc")
        self.assertEqual(config["position"], "bottom")
        self.assertEqual(config["margin-bottom"], 8)
        self.assertFalse(self.log.exists())
        self.assert_complete()

    def test_personal_theme_bar_defaults_and_asymmetric_spacing(self):
        theme = self.profile / "themes/personal"
        theme.mkdir()
        (theme / "theme.conf").write_text(
            "name=Personal\nbar_position=bottom\nbar_margin_top=3\nbar_margin_bottom=12\n"
        )
        self.run_theme("set", "personal", "--no-reload")
        for position, expected in (
            ("default", ("bottom", 3, 12)), ("top", ("top", 12, 3)),
            ("bottom", ("bottom", 3, 12)), ("default", ("bottom", 3, 12)),
        ):
            with self.subTest(position=position):
                self.run_theme("bar-position", position, "--no-reload")
                self.run_theme("init")
                config = load_waybar_config(self.current / "waybar/config.jsonc")
                self.assertEqual((config["position"], config["margin-top"], config["margin-bottom"]), expected)
                self.assert_complete()

    def test_failed_position_change_preserves_theme_and_preference(self):
        self.run_theme("set", "retro", "--no-reload")
        self.run_theme("bar-position", "top", "--no-reload")
        original = self.current.resolve()
        for failure in ("FAIL_VALIDATE", "FAIL_RELOAD"):
            with self.subTest(failure=failure):
                self.run_theme("bar-position", "bottom", success=False, **{failure: "1"})
                self.assertEqual(self.current.resolve(), original)
                self.assertEqual(self.run_theme("current").stdout, "retro\n")
                self.assertEqual(self.run_theme("bar-position").stdout, "top\n")
                self.assert_complete()
        self.assertNotIn("systemctl", self.log.read_text())

    def test_failed_theme_change_preserves_fixed_position(self):
        self.run_theme("bar-position", "bottom", "--no-reload")
        original = self.current.resolve()
        self.run_theme("set", "retro", success=False, FAIL_RELOAD="1")
        self.assertEqual(self.current.resolve(), original)
        self.assertEqual(self.run_theme("current").stdout, "rain\n")
        self.assertEqual(self.run_theme("bar-position").stdout, "bottom\n")
        self.assert_complete()

    def test_invalid_bar_position_and_arguments_do_not_change_state(self):
        self.run_theme("init")
        original = self.current.resolve()
        for arguments in (("left",), ("",), ("TOP",), ("$(false)",), ("../top",),
                          ("top", "--unknown"), ("top", "--no-reload", "extra")):
            with self.subTest(arguments=arguments):
                self.run_theme("bar-position", *arguments, success=False)
        self.assertEqual(self.current.resolve(), original)
        self.assert_complete()

    def test_invalid_saved_position_is_rejected_and_can_be_repaired(self):
        self.run_theme("init")
        original = self.current.resolve()
        (self.current / "bar-position").write_text("left\n")
        for arguments in (("bar-position",), ("init",), ("set", "retro", "--no-reload")):
            self.run_theme(*arguments, success=False)
            self.assertEqual(self.current.resolve(), original)
        self.run_theme("bar-position", "default", "--no-reload")
        self.assertEqual(self.run_theme("bar-position").stdout, "default\n")
        self.assert_complete()

    def test_validation_is_headless_without_changing_live_reload_environment(self):
        self.run_theme("init")
        self.script("sway", '[[ "$WLR_BACKENDS" == headless && "$WLR_RENDERER" == pixman ]]\n'
                    'printf "validated %s\\n" "$SWAY_NOIR_THEME_DIR" >> "$THEME_LOG"\n')
        self.script("swaymsg", '[[ "$WLR_BACKENDS" == drm && "$WLR_RENDERER" == gles2 ]]\n'
                    '[[ "$SWAY_NOIR_THEME_DIR" == "$EXPECTED_CURRENT" ]]\n'
                    'printf "reloaded\\n" >> "$THEME_LOG"\n')
        self.run_theme("select", MENU_INDEX="2", WLR_BACKENDS="drm", WLR_RENDERER="gles2",
                       EXPECTED_CURRENT=str(self.current))
        self.assertEqual(self.run_theme("current").stdout, "retro\n")
        self.assertIn("validated " + str(self.current.resolve()), self.log.read_text())
        self.assertIn("reloaded", self.log.read_text())
        self.assert_complete()

    def test_offline_selection_and_missing_saved_theme_fallback(self):
        self.run_theme("set", "retro", "--no-reload", SWAYSOCK="", SWAY_NOIR_SESSION_ID="")
        self.run_theme("bar-position", "bottom", "--no-reload", SWAYSOCK="", SWAY_NOIR_SESSION_ID="")
        self.assertFalse(self.log.exists())
        (self.profile / "themes/retro/theme.conf").unlink()
        result = self.run_theme("init")
        self.assertIn("using Rain", result.stderr)
        self.assertEqual(self.run_theme("current").stdout, "rain\n")
        self.assertEqual(self.run_theme("bar-position").stdout, "bottom\n")
        self.assertEqual(load_waybar_config(self.current / "waybar/config.jsonc")["position"], "bottom")

    def test_bundled_status_labels_have_no_percent_signs(self):
        for theme in BUNDLED_THEMES:
            self.run_theme("set", theme, "--no-reload")
            config = load_waybar_config(self.current / "waybar/config.jsonc")
            for module in ("cpu", "memory", "network", "pulseaudio", "battery", "custom/gpu"):
                for key, value in config[module].items():
                    if key == "format" or key.startswith("format-"):
                        with self.subTest(theme=theme, module=module, key=key):
                            self.assertNotIn("%", value)
            # Clock strftime placeholders are unrelated and must remain intact.
            self.assertIn("%H:%M", config["clock"]["format"])

    def test_bundled_bars_have_no_theme_switcher(self):
        for theme in BUNDLED_THEMES:
            with self.subTest(theme=theme):
                self.run_theme("set", theme, "--no-reload")
                config = load_waybar_config(self.current / "waybar/config.jsonc")
                self.assertNotIn("custom/theme", config)
                for position in ("left", "center", "right"):
                    self.assertNotIn("custom/theme", config[f"modules-{position}"])
                self.assertNotIn("#custom-theme", (self.current / "waybar/style.css").read_text())

    def test_shared_waybar_behavior_changes_reach_every_bundled_theme(self):
        base = self.profile / "waybar/base.jsonc"
        base.write_text(base.read_text().replace('"interval": 3', '"interval": 7')
                        .replace('"scroll-step": 2', '"scroll-step": 4')
                        .replace('"clock"]', '"clock", "custom/test"]'))
        for theme in BUNDLED_THEMES:
            with self.subTest(theme=theme):
                self.run_theme("set", theme, "--no-reload")
                config = load_waybar_config(self.current / "waybar/config.jsonc")
                self.assertEqual(config["cpu"]["interval"], 7)
                self.assertEqual(config["pulseaudio"]["scroll-step"], 4)
                self.assertEqual(config["modules-right"][-1], "custom/test")
                self.assert_complete()

    def test_theme_waybar_overrides_do_not_inherit_rain_only_options(self):
        for theme in BUNDLED_THEMES:
            with self.subTest(theme=theme):
                self.run_theme("set", theme, "--no-reload")
                config = load_waybar_config(self.current / "waybar/config.jsonc")
                self.assertEqual("rewrite" in config["sway/window"], theme == "rain")
                self.assertEqual("max-length" in config["network"], theme == "rain")
                self.assertEqual("tooltip-format" in config["memory"], theme != "retro")
                self.assertEqual(config["tray"]["spacing"], 6 if theme == "praxis" else 8)
                self.assertEqual("icon-size" in config["tray"], theme == "praxis")

    def test_local_waybar_overrides_win_and_keep_theme_and_base_defaults(self):
        local = self.profile / "waybar/local.jsonc"
        original = '''{
            // Personal settings use native JSONC, including trailing commas.
            "modules-right": ["cpu", "custom/gpu", "memory", "clock"],
            "cpu": {"interval": 11, "format": "LOAD {usage}"},
            "custom/gpu": {
                "exec": "printf 42",
                "interval": 3,
                "format": "<span foreground=\\"{{muted}}\\">GPU</span> {}",
            },
        }'''
        local.write_text(original)
        for theme in BUNDLED_THEMES:
            with self.subTest(theme=theme):
                self.run_theme("set", theme, "--no-reload")
                self.run_theme("init")
                config = load_waybar_config(self.current / "waybar/config.jsonc")
                self.assertEqual(config["modules-right"], ["cpu", "custom/gpu", "memory", "clock"])
                self.assertEqual(config["cpu"]["interval"], 11)
                self.assertEqual(config["cpu"]["format"], "LOAD {usage}")
                self.assertFalse(config["cpu"]["tooltip"])
                self.assertEqual(config["memory"]["interval"], 5)
                self.assertEqual(config["height"], {"rain": 34, "praxis": 36, "retro": 32}[theme])
                self.assertEqual(config["position"], "top" if theme == "rain" else "bottom")
                self.assertIn('foreground="#', config["custom/gpu"]["format"])
                self.assertEqual(local.read_text(), original)
                self.assert_complete()
        self.assertFalse(self.log.exists())

    def test_local_gpu_inherits_cpu_text_style_when_switching_themes(self):
        local = self.profile / "waybar/local.jsonc"
        original = json.dumps({
            "modules-right": ["cpu", "memory", "custom/gpu", "clock"],
            "custom/gpu": {"exec": "printf 7", "interval": 3, "tooltip": False},
        })
        local.write_text(original)
        for theme in (*BUNDLED_THEMES, "praxis", "rain"):
            with self.subTest(theme=theme):
                self.run_theme("set", theme, "--no-reload")
                self.run_theme("init")
                config = load_waybar_config(self.current / "waybar/config.jsonc")
                gpu = config["custom/gpu"]
                expected = (config["cpu"]["format"].replace("CPU", "GPU")
                            .replace("{usage:02}", "{:0>2}").replace("{usage}", "{}"))
                self.assertEqual(gpu["format"], expected)
                self.assertEqual(gpu.get("align"), config["cpu"].get("align"))
                self.assertEqual(gpu.get("justify"), config["cpu"].get("justify"))
                self.assertEqual(gpu["exec"], "printf 7")
                self.assertEqual(gpu["interval"], 3)
                self.assertFalse(gpu["tooltip"])
                self.assertEqual(local.read_text(), original)
                if theme == "praxis":
                    # Custom command output is text, so pad a string, not an int.
                    labels = ET.fromstring(f'<root>{gpu["format"].format("7")}</root>').findall("span")
                    self.assertEqual(labels[0].text, "GPU")
                    self.assertEqual(labels[0].get("size"), "small")
                    self.assertEqual(labels[0].get("foreground"), "#a39b89")
                    self.assertEqual(labels[1].text, "07")
                    self.assertEqual(labels[1].get("weight"), "semibold")
                    composite = ET.fromstring(
                        f'<root>{gpu["format"].format("12 · 54")}</root>'
                    ).findall("span")
                    self.assertEqual(composite[1].text, "12 · 54")
                self.assert_complete()
        self.assertFalse(self.log.exists())

    def test_local_waybar_snapshot_survives_failed_reload(self):
        local = self.profile / "waybar/local.jsonc"
        local.write_text('{"cpu": {"interval": 11}}')
        self.run_theme("init")
        original = self.current.resolve()
        local.write_text('{"cpu": {"interval": 12}}')
        self.assertEqual(load_waybar_config(self.current / "waybar/config.jsonc")["cpu"]["interval"], 11)
        self.run_theme("set", "praxis", success=False, FAIL_RELOAD="1")
        self.assertEqual(self.current.resolve(), original)
        self.assertEqual(load_waybar_config(self.current / "waybar/config.jsonc")["cpu"]["interval"], 11)
        self.assert_complete()
        self.run_theme("set", "praxis")
        self.assertEqual(load_waybar_config(self.current / "waybar/config.jsonc")["cpu"]["interval"], 12)
        self.assert_complete()

    def test_empty_and_removed_local_waybar_settings_restore_defaults(self):
        self.run_theme("init")
        original = load_waybar_config(self.current / "waybar/config.jsonc")
        local = self.profile / "waybar/local.jsonc"
        shutil.copyfile(self.profile / "waybar/local.jsonc.example", local)
        self.run_theme("init")
        self.assertEqual(load_waybar_config(self.current / "waybar/config.jsonc"), original)
        local.write_text('{"modules-right": []}')
        self.run_theme("init")
        self.assertEqual(load_waybar_config(self.current / "waybar/config.jsonc")["modules-right"], [])
        local.unlink()
        self.run_theme("init")
        self.assertEqual(load_waybar_config(self.current / "waybar/config.jsonc"), original)
        self.assertFalse((self.current / "waybar/local.jsonc").exists())
        self.assertFalse((self.current / "waybar/theme.jsonc").exists())
        self.assert_complete()

    def test_local_waybar_symlink_is_read_without_modifying_its_target(self):
        target = self.directory / "personal settings.jsonc"
        marker = self.directory / "should-not-exist"
        text = json.dumps({"cpu": {"interval": 11},
                           "custom/gpu": {"exec": f'$(touch "{marker}")'}})
        target.write_text(text)
        local = self.profile / "waybar/local.jsonc"
        local.symlink_to(target)
        self.run_theme("init")
        self.assertTrue(local.is_symlink())
        self.assertEqual(target.read_text(), text)
        self.assertEqual(load_waybar_config(self.current / "waybar/config.jsonc")["cpu"]["interval"], 11)
        self.assertFalse((self.current / "waybar/local.jsonc").is_symlink())
        self.assertFalse(marker.exists())
        self.assert_complete()

    def test_invalid_local_waybar_path_leaves_current_generation_unchanged(self):
        self.run_theme("init")
        original = self.current.resolve()
        local = self.profile / "waybar/local.jsonc"
        local.mkdir()
        self.run_theme("init", success=False)
        self.assertEqual(self.current.resolve(), original)
        local.rmdir()
        local.symlink_to(self.directory / "missing.jsonc")
        self.run_theme("init", success=False)
        self.assertEqual(self.current.resolve(), original)
        self.assert_complete()

    def test_personal_full_waybar_config_remains_a_complete_replacement(self):
        theme = self.profile / "themes/personal"
        (theme / "waybar").mkdir(parents=True)
        (theme / "theme.conf").write_text("name=Personal\n")
        custom = {"position": "{{bar_position}}", "height": 24, "modules-right": ["clock"],
                  "clock": {"format": "{:%H:%M}"}}
        (theme / "waybar/config.jsonc").write_text(json.dumps(custom))
        self.run_theme("set", "personal", "--no-reload")
        self.run_theme("bar-position", "bottom", "--no-reload")
        custom["position"] = "bottom"
        self.assertEqual(load_waybar_config(self.current / "waybar/config.jsonc"), custom)
        self.assert_complete()

    def test_personal_waybar_partial_config_can_include_shared_base(self):
        theme = self.profile / "themes/personal"
        (theme / "waybar").mkdir(parents=True)
        (theme / "theme.conf").write_text("name=Personal\n")
        (theme / "waybar/config.jsonc").write_text(json.dumps({
            "include": '"${SWAY_NOIR_THEME_DIR}/waybar/base.jsonc"',
            "height": 27, "cpu": {"format": "LOAD {usage}"},
        }))
        self.run_theme("set", "personal", "--no-reload")
        config = load_waybar_config(self.current / "waybar/config.jsonc")
        self.assertEqual(config["height"], 27)
        self.assertEqual(config["cpu"], {"format": "LOAD {usage}", "interval": 3, "tooltip": False})
        self.assertEqual(config["position"], "top")
        self.assertIn("on-click", config["pulseaudio"])
        self.assert_complete()

    def test_praxis_and_retro_dividers_follow_bar_position(self):
        for theme, stroke in (("praxis", "1px solid alpha(@accent, 0.32)"),
                              ("retro", "1px solid @border")):
            self.run_theme("set", theme, "--no-reload")
            for preference in ("default", "top", "bottom"):
                with self.subTest(theme=theme, preference=preference):
                    self.run_theme("bar-position", preference, "--no-reload")
                    config = load_waybar_config(self.current / "waybar/config.jsonc")
                    position = "bottom" if preference == "default" else preference
                    self.assertEqual(config["position"], position)
                    css = (self.current / "waybar/style.css").read_text()
                    window_style = css.split("window#waybar {", 1)[1].split("}", 1)[0]
                    self.assertNotIn("border-", window_style)
                    for edge, divider, opposite in (("top", "bottom", "top"), ("bottom", "top", "bottom")):
                        style = css.split(f"window#waybar.{edge} {{", 1)[1].split("}", 1)[0]
                        self.assertIn(f"border-{divider}: {stroke};", style)
                        self.assertIn(f"border-{opposite}: none;", style)
                    self.assert_complete()

    def test_retro_workspace_labels_are_plain_and_high_contrast(self):
        self.run_theme("set", "retro", "--no-reload")
        config = load_waybar_config(self.current / "waybar/config.jsonc")
        self.assertEqual(config["sway/workspaces"]["format"], "{name}")
        css = (self.current / "waybar/style.css").read_text()
        workspace_style = css.split("#workspaces button {", 1)[1].split("}", 1)[0]
        self.assertIn("color: @text;", workspace_style)
        self.assertIn("background: @surface;", workspace_style)
        self.assertIn("font-size: 13px;", workspace_style)
        self.assertIn("font-weight: 600;", workspace_style)

    def test_retro_active_workspace_uses_a_subdued_highlight(self):
        self.run_theme("set", "retro", "--no-reload")
        css = (self.current / "waybar/style.css").read_text()
        self.assertIn("@define-color accent_surface #1b3325;", css)
        self.assertIn("#workspaces button.focused,\n#workspaces button.active {", css)
        active_style = css.split("#workspaces button.active {", 1)[1].split("}", 1)[0]
        self.assertIn("color: @text;", active_style)
        self.assertIn("background: @accent_surface;", active_style)
        self.assertIn("border-color: alpha(@accent, 0.65);", active_style)
        self.assertNotIn("background: @accent;", active_style)

    def test_bundled_bars_center_window_title_and_put_clock_last(self):
        for theme in BUNDLED_THEMES:
            with self.subTest(theme=theme):
                self.run_theme("set", theme, "--no-reload")
                config = load_waybar_config(self.current / "waybar/config.jsonc")
                self.assertEqual(config["modules-center"], ["sway/window"])
                self.assertNotIn("sway/window", config["modules-left"])
                self.assertEqual(config["modules-right"][-1], "clock")
                self.assertEqual(config["clock"]["format"], "{:%m-%d · %H:%M}")
                self.assertTrue(config.get("fixed-center", True))
        css = (self.current / "waybar/style.css").read_text()
        window_style = css.split("#window {", 1)[1].split("}", 1)[0]
        self.assertNotIn("margin-left", window_style)
        self.assertIn("padding: 0 12px;", window_style)

    def test_retro_and_praxis_assets_are_distinct_qhd_pngs(self):
        for theme in ("retro", "praxis"):
            with self.subTest(theme=theme):
                images = []
                for filename in ("wallpaper.png", "lock-screen.png"):
                    image = (self.profile / "themes" / theme / filename).read_bytes()
                    self.assertEqual(image[:8], b"\x89PNG\r\n\x1a\n")
                    self.assertEqual(int.from_bytes(image[16:20], "big"), 2560)
                    self.assertEqual(int.from_bytes(image[20:24], "big"), 1440)
                    images.append(image)
                self.assertNotEqual(*images)

    def test_praxis_renders_gold_components_and_own_layout(self):
        self.run_theme("set", "praxis", "--no-reload")
        self.assert_complete()
        sway = (self.current / "sway.conf").read_text()
        self.assertIn("set $accent    #d5b36a", sway)
        self.assertIn("default_border pixel 1", sway)
        self.assertIn("gaps inner 12", sway)
        self.assertIn('"$SWAY_NOIR_DIR/themes/praxis/wallpaper.png" fill #0c0e0d', sway)
        config = load_waybar_config(self.current / "waybar/config.jsonc")
        self.assertEqual(config["position"], "bottom")
        self.assertEqual(config["height"], 36)
        self.assertNotIn("width", config)
        self.assertEqual(config["margin-top"], 0)
        self.assertEqual(config["margin-bottom"], 0)
        self.assertEqual(config["margin-left"], 0)
        self.assertEqual(config["margin-right"], 0)
        self.assertEqual(config["sway/workspaces"]["format"], "{name}")
        self.assertEqual(config["sway/window"].get("rotate", 0), 0)
        self.assertEqual(config["sway/window"]["max-length"], 32)
        for module in ("cpu", "memory", "network", "pulseaudio", "battery", "custom/gpu"):
            self.assertEqual(config[module]["align"], 0.5)
            self.assertEqual(config[module]["justify"], "center")
            for key, value in config[module].items():
                if key == "format" or key.startswith("format-"):
                    with self.subTest(module=module, key=key):
                        self.assertNotIn("\n", value)
                        self.assertIn('foreground="#a39b89"', value)
                        labels = ET.fromstring(f"<root>{value}</root>").findall("span")
                        self.assertEqual(len(labels), 2)
                        self.assertEqual(labels[0].get("size"), "small")
                        self.assertEqual(labels[1].get("weight"), "semibold")
        css = (self.current / "waybar/style.css").read_text()
        self.assertIn('@define-color accent #d5b36a;', css)
        self.assertIn('font-family: "IBM Plex Sans", sans-serif;', css)
        active_style = css.split("#workspaces button.active {", 1)[1].split("}", 1)[0]
        self.assertIn("background: @accent_surface;", active_style)
        self.assertIn("border-bottom-color: @accent;", active_style)
        self.assertNotIn("background: @accent;", active_style)
        launcher = (self.current / "fuzzel/fuzzel.ini").read_text()
        self.assertIn('prompt="run: "', launcher)
        self.assertIn("match=d5b36aff", launcher)
        self.assertIn("width=48", launcher)
        self.assertIn("anchor=center", launcher)
        self.assertIn("selection-match=0c0e0dff", launcher)
        self.assertIn("border-color=#d5b36aff", (self.current / "mako/config").read_text())
        lock = (self.current / "swaylock/config").read_text()
        self.assertIn("indicator-radius=60", lock)
        self.assertIn("indicator-thickness=2", lock)
        self.assertIn("key-hl-color=d5b36aff", lock)
        self.assertIn(f"image={self.profile}/themes/praxis/lock-screen.png", lock)

    def test_live_switching_between_all_bundled_themes_is_persistent(self):
        self.run_theme("init")
        for theme in (*BUNDLED_THEMES, "praxis"):
            with self.subTest(theme=theme):
                self.run_theme("set", theme)
                self.assertEqual(self.run_theme("current").stdout.strip(), theme)
                self.run_theme("init")
                self.assertEqual((self.current / "theme-id").read_text().strip(), theme)
                self.assert_complete()
        self.assertNotIn("restart", self.log.read_text())

    def test_solid_background_and_no_lock_image_remain_supported(self):
        theme = self.profile / "themes/solid"
        theme.mkdir()
        (theme / "theme.conf").write_text("name=Solid Rain\nwallpaper=none\nlock_wallpaper=none\n")
        self.run_theme("set", "solid", "--no-reload")
        self.assertIn("output * background #111315 solid_color", (self.current / "sway.conf").read_text())
        self.assertNotIn("image=", (self.current / "swaylock/config").read_text())

    def test_failed_validation_or_reload_preserves_selection(self):
        self.run_theme("init")
        original = self.current.resolve()
        self.run_theme("set", "retro", success=False, FAIL_VALIDATE="1")
        self.assertEqual(self.current.resolve(), original)
        self.assertNotIn("swaymsg", self.log.read_text())
        self.run_theme("set", "retro", success=False, FAIL_RELOAD="2")
        self.assertEqual(self.current.resolve(), original)
        self.assertEqual(self.run_theme("current").stdout, "rain\n")
        self.assertNotIn("systemctl", self.log.read_text())
        self.assert_complete()

    def test_failed_ui_reload_warns_without_losing_saved_theme(self):
        self.run_theme("init")
        result = self.run_theme("set", "retro", FAIL_UI="1")
        self.assertIn("Warning:", result.stderr)
        self.assertEqual(self.run_theme("current").stdout, "retro\n")
        result = self.run_theme("bar-position", "top", FAIL_UI="1")
        self.assertIn("Warning:", result.stderr)
        self.assertEqual(self.run_theme("bar-position").stdout, "top\n")
        self.assertEqual(self.run_theme("current").stdout, "retro\n")
        self.assert_complete()

    def test_bad_ids_values_and_templates_do_not_change_current(self):
        self.run_theme("init")
        original = self.current.resolve()
        for id_ in ("../rain", "", "RAIN", "does-not-exist"):
            self.run_theme("set", id_, "--no-reload", success=False)
        theme = self.profile / "themes/bad"
        theme.mkdir()
        for content in ("accent=green", "font=$(touch /tmp/unsafe)", "wallpaper=../outside.png", "unknown=value", "gaps_inner=100",
                        "bar_position=left", "bar_position=default", "bar_margin_top=-1", "bar_margin_bottom=100"):
            (theme / "theme.conf").write_text(content + "\n")
            self.run_theme("set", "bad", "--no-reload", success=False)
        (theme / "theme.conf").write_text("name=Broken\n")
        (theme / "sway.conf").write_text("{{missing}}\n")
        self.run_theme("set", "bad", "--no-reload", success=False)
        self.assertEqual(self.current.resolve(), original)
        self.assert_complete()

    def test_foreign_session_is_rejected(self):
        for environment in ({"SWAYSOCK": ""}, {"SWAY_NOIR_SESSION_ID": "invalid"}, {"SWAY_NOIR_THEME_DIR": "/foreign"}):
            self.run_theme("set", "retro", success=False, **environment)
            self.run_theme("bar-position", "top", success=False, **environment)
        self.assertFalse(self.state.exists())

    def test_menu_selects_by_index_and_cancellation_does_nothing(self):
        self.run_theme("init")
        self.run_theme("select", MENU_INDEX="2")
        self.assertEqual(self.run_theme("current").stdout, "retro\n")
        self.assertIn("Retro (retro)", Path(str(self.log) + ".menu").read_text())
        self.assertIn("Rain (rain)", Path(str(self.log) + ".menu").read_text())
        self.assertIn("Praxis (praxis)", Path(str(self.log) + ".menu").read_text())
        self.assertNotIn("Noir", Path(str(self.log) + ".menu").read_text())
        self.assertIn("Waybar position: Theme default", Path(str(self.log) + ".menu").read_text())
        original = self.current.resolve()
        self.run_theme("select", MENU_STATUS="1")
        self.assertEqual(self.current.resolve(), original)
        for index in ("-1", "4", "9999999999999999", "$(false)"):
            self.run_theme("select", MENU_INDEX=index, success=False)
        self.assertEqual(self.current.resolve(), original)

    def test_menu_can_select_praxis(self):
        self.run_theme("init")
        self.run_theme("select", MENU_INDEX="0")
        self.assertEqual(self.run_theme("current").stdout, "praxis\n")
        self.assert_complete()

    def test_menu_can_set_and_reset_bar_position_without_switching_theme(self):
        self.run_theme("set", "retro", "--no-reload")
        for index, position, label in (
            ("1", "top", "Always top"), ("2", "bottom", "Always bottom"),
            ("0", "default", "Theme default"),
        ):
            with self.subTest(position=position):
                self.run_theme("select", MENU_INDEX="3", POSITION_INDEX=index)
                self.assertEqual(self.run_theme("bar-position").stdout, position + "\n")
                self.assertEqual(self.run_theme("current").stdout, "retro\n")
                self.run_theme("select", MENU_STATUS="1")
                self.assertIn("Waybar position: " + label, Path(str(self.log) + ".menu").read_text())
                self.assert_complete()

    def test_position_menu_marks_current_selection_and_cancel_does_nothing(self):
        self.run_theme("bar-position", "top", "--no-reload")
        original = self.current.resolve()
        self.run_theme("select", MENU_INDEX="3", POSITION_STATUS="1")
        self.assertEqual(Path(str(self.log) + ".position-menu").read_text().splitlines(),
                         ["Theme default", "Always top (selected)", "Always bottom"])
        for index in ("-1", "3", "9999999999999999", "$(false)"):
            self.run_theme("select", MENU_INDEX="3", POSITION_INDEX=index, success=False)
        self.assertEqual(self.current.resolve(), original)
        self.assertFalse(self.log.exists())
        self.assert_complete()

    def test_menu_shows_activation_errors_without_changing_selection(self):
        self.script("swaynag", 'cat > "$THEME_LOG.error"\n'
                    'printf "%s\\n" "$@" >> "$THEME_LOG.error"\n')
        self.run_theme("init")
        original = self.current.resolve()
        for menu_index, failure, message in (
            ("2", "FAIL_VALIDATE", "validation failed"), ("2", "FAIL_RELOAD", "reload failed"),
            ("3", "FAIL_VALIDATE", "validation failed"), ("3", "FAIL_RELOAD", "reload failed"),
        ):
            with self.subTest(menu_index=menu_index, failure=failure):
                error = Path(str(self.log) + ".error")
                error.unlink(missing_ok=True)
                result = self.run_theme("select", MENU_INDEX=menu_index, POSITION_INDEX="2",
                                        success=False, **{failure: "1"})
                self.assertIn(message, result.stderr)
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    if error.exists() and message in error.read_text():
                        break
                    time.sleep(0.01)
                else:
                    self.fail("Theme menu did not show the activation error")
                self.assertEqual(self.current.resolve(), original)
                self.assert_complete()

    def test_simultaneous_switches_are_serialized(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
            results = list(executor.map(lambda id_: self.run_theme("set", id_, "--no-reload"), BUNDLED_THEMES * 3))
        self.assertEqual(len(results), 9)
        self.assert_complete()
        self.assertIn(self.run_theme("current").stdout.strip(), BUNDLED_THEMES)

    def test_simultaneous_theme_and_position_changes_preserve_both(self):
        for _ in range(3):
            self.run_theme("set", "rain", "--no-reload")
            self.run_theme("bar-position", "default", "--no-reload")
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
                theme = executor.submit(self.run_theme, "set", "retro", "--no-reload")
                position = executor.submit(self.run_theme, "bar-position", "top", "--no-reload")
                theme.result()
                position.result()
            self.assertEqual(self.run_theme("current").stdout, "retro\n")
            self.assertEqual(self.run_theme("bar-position").stdout, "top\n")
            self.assertEqual(load_waybar_config(self.current / "waybar/config.jsonc")["position"], "top")
            self.assert_complete()

    def test_lock_helper_resolves_latest_theme_without_restarting_locker(self):
        self.script("swaylock", 'printf "%s\\n" "$@" > "$THEME_LOG"\n')
        self.run_theme("set", "retro", "--no-reload")
        result = subprocess.run([str(self.profile / "session/lock-screen")], env=self.environment, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.log.read_text().splitlines(), ["--daemonize", "--config", str(self.current / "swaylock/config")])

    def test_launcher_initializes_and_exports_saved_theme_before_sway(self):
        shutil.copy2(ROOT / "start-sway-noir", self.profile / "start-sway-noir")
        self.run_theme("set", "retro", "--no-reload")
        self.script("sway", '[[ -f "$SWAY_NOIR_THEME_DIR/sway.conf" ]]\n'
                    'printf "theme=%s\\n" "$(cat "$SWAY_NOIR_THEME_DIR/theme-id")" >> "$THEME_LOG"\n')
        (self.bin / "start-sway").symlink_to(self.bin / "sway")
        self.environment["XDG_CONFIG_HOME"] = str(self.profile.parent)
        Path(self.environment["HOME"]).mkdir()
        result = subprocess.run([str(self.profile / "start-sway-noir")], env=self.environment,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("theme=retro", self.log.read_text())
        self.assert_complete()

    def test_supervisor_reloads_only_appearance_and_survives_signal(self):
        self.run_theme("init")
        self.script("waybar", 'trap \'printf "waybar-reloaded\\n" >> "$THEME_LOG"\' USR2\nprintf "waybar-ready\\n" >> "$THEME_LOG"\nwhile true; do sleep 0.02; done\n')
        self.script("mako", 'printf "mako-ready\\n" >> "$THEME_LOG"\nwhile true; do sleep 0.02; done\n')
        self.script("makoctl", 'printf "makoctl %s\\n" "$*" >> "$THEME_LOG"\n')
        self.script("swayidle", 'printf "idle-ready\\n" >> "$THEME_LOG"\nwhile true; do sleep 0.02; done\n')
        process = subprocess.Popen(
            [str(self.profile / "session/run-apps"), "lock-screen", "true", "true"],
            env=self.environment, start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        try:
            self.wait_for_log("waybar-ready", process)
            self.wait_for_log("mako-ready", process)
            self.wait_for_log("idle-ready", process)
            os.kill(process.pid, signal.SIGUSR2)
            self.wait_for_log("waybar-reloaded", process)
            self.wait_for_log("makoctl reload", process)
            self.assertIsNone(process.poll())
            log = self.log.read_text()
            for name in ("waybar-ready", "mako-ready", "idle-ready"):
                self.assertEqual(log.count(name), 1)
        finally:
            os.killpg(process.pid, signal.SIGTERM)
            process.communicate(timeout=5)

    def test_supervisor_exports_fallback_directory_for_waybar_include(self):
        self.run_theme("init")
        self.script("waybar", '[[ -f "$SWAY_NOIR_THEME_DIR/waybar/base.jsonc" ]]\n'
                    'printf "%s\\n" "$SWAY_NOIR_THEME_DIR" > "$THEME_LOG"\n')
        self.script("mako", "exit 0\n")
        self.script("swayidle", "exit 0\n")
        environment = self.environment.copy()
        environment.pop("SWAY_NOIR_THEME_DIR")
        result = subprocess.run(
            [str(self.profile / "session/run-apps"), "lock-screen", "true", "true"],
            env=environment, capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.log.read_text().strip(), str(self.current))

    def wait_for_log(self, text, process):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            self.assertIsNone(process.poll(), "supervisor exited unexpectedly")
            if self.log.exists() and text in self.log.read_text():
                return
            time.sleep(0.01)
        self.fail(f"Timed out waiting for {text}")


if __name__ == "__main__":
    unittest.main()
