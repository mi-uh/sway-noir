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
        self.script("fuzzel", 'cat > "$THEME_LOG.menu"\nprintf "%s\\n" "${MENU_INDEX:-0}"\nexit "${MENU_STATUS:-0}"\n')

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
        self.assertEqual(json.loads((self.current / "waybar/config.jsonc").read_text())["position"], "top")
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
        self.assertEqual(json.loads((self.current / "waybar/config.jsonc").read_text())["position"], "bottom")
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
        self.assertFalse(self.log.exists())
        (self.profile / "themes/retro/theme.conf").unlink()
        result = self.run_theme("init")
        self.assertIn("using Rain", result.stderr)
        self.assertEqual(self.run_theme("current").stdout, "rain\n")

    def test_bundled_status_labels_have_no_percent_signs(self):
        for theme in BUNDLED_THEMES:
            self.run_theme("set", theme, "--no-reload")
            config = json.loads((self.current / "waybar/config.jsonc").read_text())
            for module in ("cpu", "memory", "network", "pulseaudio", "battery"):
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
                config = json.loads((self.current / "waybar/config.jsonc").read_text())
                self.assertNotIn("custom/theme", config)
                for position in ("left", "center", "right"):
                    self.assertNotIn("custom/theme", config[f"modules-{position}"])
                self.assertNotIn("#custom-theme", (self.current / "waybar/style.css").read_text())

    def test_retro_workspace_labels_are_plain_and_high_contrast(self):
        self.run_theme("set", "retro", "--no-reload")
        config = json.loads((self.current / "waybar/config.jsonc").read_text())
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
                config = json.loads((self.current / "waybar/config.jsonc").read_text())
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
        config = json.loads((self.current / "waybar/config.jsonc").read_text())
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
        for module in ("cpu", "memory", "network", "pulseaudio", "battery"):
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
        self.assert_complete()

    def test_bad_ids_values_and_templates_do_not_change_current(self):
        self.run_theme("init")
        original = self.current.resolve()
        for id_ in ("../rain", "", "RAIN", "does-not-exist"):
            self.run_theme("set", id_, "--no-reload", success=False)
        theme = self.profile / "themes/bad"
        theme.mkdir()
        for content in ("accent=green", "font=$(touch /tmp/unsafe)", "wallpaper=../outside.png", "unknown=value", "gaps_inner=100"):
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
        self.assertFalse(self.state.exists())

    def test_menu_selects_by_index_and_cancellation_does_nothing(self):
        self.run_theme("init")
        self.run_theme("select", MENU_INDEX="2")
        self.assertEqual(self.run_theme("current").stdout, "retro\n")
        self.assertIn("Retro (retro)", Path(str(self.log) + ".menu").read_text())
        self.assertIn("Rain (rain)", Path(str(self.log) + ".menu").read_text())
        self.assertIn("Praxis (praxis)", Path(str(self.log) + ".menu").read_text())
        self.assertNotIn("Noir", Path(str(self.log) + ".menu").read_text())
        original = self.current.resolve()
        self.run_theme("select", MENU_STATUS="1")
        self.assertEqual(self.current.resolve(), original)
        for index in ("-1", "3", "9999999999999999", "$(false)"):
            self.run_theme("select", MENU_INDEX=index, success=False)
        self.assertEqual(self.current.resolve(), original)

    def test_menu_can_select_praxis(self):
        self.run_theme("init")
        self.run_theme("select", MENU_INDEX="0")
        self.assertEqual(self.run_theme("current").stdout, "praxis\n")
        self.assert_complete()

    def test_menu_shows_activation_errors_without_changing_selection(self):
        self.script("swaynag", 'cat > "$THEME_LOG.error"\n'
                    'printf "%s\\n" "$@" >> "$THEME_LOG.error"\n')
        self.run_theme("init")
        original = self.current.resolve()
        for failure, message in (("FAIL_VALIDATE", "validation failed"),
                                 ("FAIL_RELOAD", "reload failed")):
            with self.subTest(failure=failure):
                error = Path(str(self.log) + ".error")
                error.unlink(missing_ok=True)
                result = self.run_theme("select", MENU_INDEX="2", success=False, **{failure: "1"})
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
