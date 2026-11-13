#!/usr/bin/env python3
"""Check required/optional dependencies without using host desktop commands."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
CORE = (
    "dbus-update-activation-environment", "flock", "foot", "fuzzel", "mako", "makoctl", "sway",
    "swaybg", "swayidle", "swaylock", "swaymsg", "swaynag", "systemctl",
    "systemd-analyze", "systemd-run", "waybar",
)
PORTAL_UNITS = (
    "xdg-desktop-portal.service", "xdg-desktop-portal-gtk.service",
    "xdg-desktop-portal-wlr.service",
)
OPTIONAL = (
    "wpctl", "gammastep", "brightnessctl", "playerctl", "grim", "slurp",
    "pavucontrol", "lxqt-policykit-agent",
)
UTILITIES = (
    "cat", "chmod", "date", "dirname", "find", "findmnt", "grep", "head", "install", "mktemp", "mv",
    "readlink", "rm", "rmdir", "sha256sum", "sort", "stat", "tr",
)


class IsolatedTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)

    def script(self, path, body):
        path.write_text("#!/usr/bin/bash\n" + body)
        path.chmod(0o755)
        return path


@unittest.skipIf(os.geteuid() == 0, "The installer intentionally rejects root")
class InstallerDependencies(IsolatedTest):
    def install(self, missing=(), version="systemd 254 (254.1)", missing_units=(),
                libexec_agent=False, atomic=False, arguments=("--profile-only",),
                os_release="ID=fedora\n"):
        case = Path(tempfile.mkdtemp(dir=self.directory))
        fixture = case / "repo"
        fixture.mkdir()
        for name in ("dependencies.list", "start-sway-noir", "sway", "swaylock", "waybar", "fuzzel",
                     "mako", "gammastep", "systemd", "xdg-desktop-portal"):
            (fixture / name).symlink_to(ROOT / name)
        shutil.copytree(ROOT / "session", fixture / "session")
        shutil.copytree(ROOT / "themes", fixture / "themes")
        library = fixture / "session/dependencies.sh"
        library.write_text(library.read_text().replace(
            "/usr/libexec/", str(case / "libexec") + "/"
        ).replace("/run/ostree-booted", str(case / "ostree-booted")).replace(
            "/etc/os-release", str(case / "os-release")
        ))
        (case / "os-release").write_text(os_release)
        installer = fixture / "install.sh"
        installer.write_text((ROOT / "install.sh").read_text())
        if atomic:
            (case / "ostree-booted").touch()
        if libexec_agent:
            (case / "libexec").mkdir()
            self.script(case / "libexec/lxqt-policykit-agent", "exit 0\n")
        units = case / "units"
        units.mkdir()
        for unit in PORTAL_UNITS:
            if unit not in missing_units:
                (units / unit).write_text("[Unit]\nDescription=Mock portal\n")
        binary_dir = case / "bin"
        binary_dir.mkdir()
        for command in UTILITIES:
            (binary_dir / command).symlink_to(shutil.which(command))
        for command in (*CORE, *OPTIONAL):
            if command not in missing:
                (binary_dir / command).symlink_to(shutil.which("true"))
        if "systemd-run" not in missing:
            (binary_dir / "systemd-run").unlink()
            self.script(binary_dir / "systemd-run", 'printf "%s\\n" "$SYSTEMD_VERSION"\n')
        if "systemd-analyze" not in missing:
            (binary_dir / "systemd-analyze").unlink()
            self.script(binary_dir / "systemd-analyze", 'printf "%s\\n" "$UNIT_PATHS"\n')
        if "-y" in arguments or "--set-dark-mode" in arguments:
            self.script(binary_dir / "gsettings", 'printf "org.gnome.desktop.interface\\n"\n')
        # An unexpected package-manager or privilege escalation call must fail
        # visibly, even if the installer were to ignore its exit status.
        for command in ("sudo", "dnf", "rpm-ostree", "apt"):
            self.script(binary_dir / command, 'printf called > "$PACKAGE_LOG"\nexit 99\n')
        # Package queries report no installed packages; only pacman's read-only
        # query is allowed, never an installation or another modifying command.
        for command in ("rpm", "dpkg-query"):
            self.script(binary_dir / command, "exit 1\n")
        self.script(binary_dir / "pacman", '[[ "${1:-}" != -Q ]] || exit 1\n'
                    'printf called > "$PACKAGE_LOG"\nexit 99\n')
        config = case / "home/config"
        environment = {
            **os.environ, "HOME": str(case / "home"), "XDG_CONFIG_HOME": str(config),
            "XDG_CONFIG_DIRS": str(case / "etc"), "XDG_DATA_DIRS": str(case / "share"),
            "XDG_DATA_HOME": str(case / "data"), "PATH": str(binary_dir),
            "PACKAGE_LOG": str(case / "package.log"),
            "SYSTEMD_VERSION": version, "UNIT_PATHS": f"{case / 'absent-units'}\n{units}",
        }
        result = subprocess.run(
            ["/usr/bin/bash", str(installer), *arguments],
            env=environment, capture_output=True, text=True,
        )
        self.assertFalse((case / "package.log").exists(), result.stderr)
        return result, config

    def test_loading_installer_modules_is_read_only(self):
        home = self.directory / "home"
        result = subprocess.run(
            ["/usr/bin/bash", "-c", 'source "$1"; '
             'declare -F preflight_installation install_profile_files install_external_files '
             'verify_installation uninstall_sway_noir >/dev/null',
             "installer-module-probe", str(ROOT / "install.sh")],
            cwd=self.directory, env={**os.environ, "HOME": str(home),
                                     "XDG_CONFIG_HOME": str(home / "config"),
                                     "XDG_STATE_HOME": str(home / "state")},
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "")
        self.assertFalse(home.exists())

    def test_help_does_not_require_desktop_dependencies(self):
        result, config = self.install(missing=set(CORE), arguments=("--help",))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Usage: ./install.sh", result.stdout)
        self.assertFalse(config.exists())

    def test_each_required_dependency_blocks_before_writes(self):
        for command in CORE:
            with self.subTest(command=command):
                result, config = self.install(missing={command})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(command, result.stderr)
                if command != "systemctl":
                    self.assertIn("sudo dnf install", result.stderr)
                self.assertFalse(config.exists())

    def test_package_hints_match_distribution(self):
        for os_release, expected in (
            ("ID=fedora\n", "sudo dnf install mako"),
            ("ID=ubuntu\nID_LIKE=debian\n", "sudo apt install mako-notifier"),
            ("ID=debian\n", "sudo apt install mako-notifier"),
            ("ID=arch\n", "sudo pacman -S --needed mako"),
            ("ID=derivative\nID_LIKE=\"arch linux\"\n", "sudo pacman -S --needed mako"),
        ):
            with self.subTest(os_release=os_release):
                result, config = self.install(missing={"mako"}, os_release=os_release)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)
                self.assertFalse(config.exists())

    def test_each_optional_dependency_warns_but_installs(self):
        for command in OPTIONAL:
            with self.subTest(command=command):
                result, config = self.install(missing={command})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"Optional command not found: {command}.", result.stderr)
                self.assertTrue((config / "sway-noir/session/optional-command").is_file())

    def test_all_optional_dependencies_can_be_missing(self):
        result, config = self.install(missing=set(OPTIONAL))
        self.assertEqual(result.returncode, 0, result.stderr)
        for command in OPTIONAL:
            self.assertIn(f"Optional command not found: {command}.", result.stderr)
        self.assertTrue((config / "sway-noir/start-sway-noir").is_file())

    def test_fedora_libexec_agent_does_not_produce_a_missing_warning(self):
        result, config = self.install(missing={"lxqt-policykit-agent"}, libexec_agent=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Optional command not found: lxqt-policykit-agent", result.stderr)
        self.assertTrue((config / "sway-noir/session/dependencies.sh").is_file())

    def test_old_or_unparseable_systemd_blocks_before_writes(self):
        for version in ("systemd 253 (253.9)", "", "unexpected version"):
            with self.subTest(version=version):
                result, config = self.install(version=version)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("systemd 254 or newer", result.stderr)
                self.assertFalse(config.exists())

    def test_supported_systemd_versions(self):
        for version in ("systemd 254 (254.1)", "systemd 259 (259.5-1.fc44)\n+PAM +AUDIT"):
            with self.subTest(version=version):
                result, _ = self.install(version=version)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_check_deps_validates_systemd_without_writes(self):
        for version, success in (("systemd 253 (253.9)", False), ("systemd 254 (254.1)", True)):
            with self.subTest(version=version):
                result, config = self.install(version=version, arguments=("--check-deps",))
                self.assertEqual(result.returncode == 0, success, result.stderr)
                self.assertFalse(config.exists())

    def test_check_deps_validates_required_portals_without_writes(self):
        result, config = self.install(missing_units=PORTAL_UNITS, arguments=("--check-deps",))
        self.assertNotEqual(result.returncode, 0)
        for unit in PORTAL_UNITS:
            self.assertIn(unit, result.stderr)
        self.assertFalse(config.exists())

    def test_list_deps_includes_merged_tools_without_writes(self):
        result, config = self.install(arguments=("--list-deps",))
        self.assertEqual(result.returncode, 0, result.stderr)
        for command in ("systemd-run", "systemd-analyze", "wpctl", "lxqt-policykit-agent"):
            self.assertIn(command, result.stdout)
        self.assertFalse(config.exists())

    def test_each_missing_portal_blocks_before_writes(self):
        for unit in PORTAL_UNITS:
            with self.subTest(unit=unit):
                result, config = self.install(missing_units={unit})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(unit, result.stderr)
                self.assertIn("required desktop portal user units are missing", result.stderr)
                self.assertFalse(config.exists())

    def test_atomic_login_without_verified_manager_blocks_before_sudo_or_writes(self):
        for arguments in (("--login-session",), ("-y",)):
            with self.subTest(arguments=arguments):
                result, config = self.install(atomic=True, arguments=arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("--profile-only", result.stderr)
                self.assertIn("Cannot identify the display-manager executable", result.stderr)
                self.assertFalse(config.exists())

    def test_atomic_profile_only_still_installs(self):
        result, config = self.install(atomic=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((config / "sway-noir/start-sway-noir").is_file())

    def test_atomic_missing_command_prints_host_layering_guidance(self):
        result, config = self.install(atomic=True, missing={"fuzzel"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sudo rpm-ostree install", result.stderr)
        self.assertNotIn("sudo dnf install", result.stderr)
        self.assertFalse(config.exists())

    def test_uninstall_does_not_require_runtime_dependencies(self):
        result, _ = self.install(missing={"sway", "systemd-run", "systemd-analyze"},
                                 missing_units=PORTAL_UNITS, arguments=("--uninstall", "-y"))
        self.assertEqual(result.returncode, 0, result.stderr)


class OptionalCommands(IsolatedTest):
    def setUp(self):
        super().setUp()
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.log = self.directory / "arguments"
        self.environment = {
            **os.environ, "PATH": str(self.bin), "FEATURE_LOG": str(self.log),
            "SWAY_NOIR_DIR": str(ROOT),
        }
        self.record = self.script(
            self.bin / "record", 'printf "%s\\n" "$@" > "$FEATURE_LOG"\n'
        )

    def run_optional(self, *arguments):
        return subprocess.run(
            [str(ROOT / "session/optional-command"), *arguments], env=self.environment,
            capture_output=True, text=True,
        )

    def test_missing_commands_skip_only_the_feature(self):
        for command in OPTIONAL:
            with self.subTest(command=command):
                result = self.run_optional("test-feature", command)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(command, result.stderr)
                self.assertIn("skipping this feature", result.stderr)
        self.assertFalse(self.log.exists())

    def test_regular_argument_quoting_and_failure_status(self):
        result = self.run_optional("test-feature", "record", "a b", "$(not-a-command)")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.log.read_text().splitlines(), ["a b", "$(not-a-command)"])
        self.script(self.bin / "failure", "exit 12\n")
        self.assertEqual(self.run_optional("test-feature", "failure").returncode, 12)

    def test_shell_overrides_disabled_and_missing(self):
        for command in ("", "true"):
            result = self.run_optional("--shell", "test-feature", command)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, "")
        self.assertFalse(self.log.exists())
        result = self.run_optional("--shell", "test-feature", "record 'quoted argument'")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.log.read_text().splitlines(), ["quoted argument"])
        result = self.run_optional("--shell", "test-feature", "not-installed")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("optional test-feature command is unavailable", result.stderr)
        self.assertEqual(self.run_optional("--shell", "test-feature", "exit 5").returncode, 5)

    def test_waybar_click_honors_session_command_override(self):
        command = json.loads((ROOT / "waybar/config.jsonc").read_text())["pulseaudio"]["on-click"]
        self.environment["SWAY_NOIR_AUDIO_SETTINGS_COMMAND"] = "record 'custom audio settings'"
        result = subprocess.run(
            ["/usr/bin/bash", "-c", command], env=self.environment, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.log.read_text().splitlines(), ["custom audio settings"])
        self.log.unlink()
        self.environment["SWAY_NOIR_AUDIO_SETTINGS_COMMAND"] = "true"
        subprocess.run(["/usr/bin/bash", "-c", command], env=self.environment, check=True)
        self.assertFalse(self.log.exists())

    def test_default_night_color_checks_runtime_availability(self):
        config = (ROOT / "sway/config").read_text()
        command = re.search(r"^set \$gammastep_command (.+)$", config, re.MULTILINE)[1]
        result = subprocess.run(
            ["/usr/bin/bash", "-c", command], env=self.environment, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("night-color requires gammastep", result.stderr)

    def test_generated_media_and_brightness_commands(self):
        expected = {
            "XF86AudioPlay": ("playerctl", ["play-pause"]),
            "XF86AudioPause": ("playerctl", ["pause"]),
            "XF86AudioPrev": ("playerctl", ["previous"]),
            "XF86AudioNext": ("playerctl", ["next"]),
            "XF86AudioStop": ("playerctl", ["stop"]),
            "XF86MonBrightnessDown": ("brightnessctl", ["set", "5%-"]),
            "XF86MonBrightnessUp": ("brightnessctl", ["set", "5%+"]),
        }
        variables = dict(re.findall(
            r"^set (\$\w+) (.+)$", (ROOT / "sway/config").read_text(), re.MULTILINE
        ))
        bindings = (ROOT / "sway/config.d/60-keybindings.conf").read_text()
        for key, (binary, arguments) in expected.items():
            with self.subTest(key=key):
                command = next(line.split(" exec ", 1)[1] for line in bindings.splitlines() if f" {key} exec " in line)
                for name, value in variables.items():
                    command = command.replace(name, value)
                mock = self.bin / binary
                self.script(mock, 'printf "%s\\n" "$@" > "$FEATURE_LOG"\n')
                result = subprocess.run(
                    ["/usr/bin/bash", "-c", command], env=self.environment, capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.log.read_text().splitlines(), arguments)
                mock.unlink()
                self.log.unlink()
                result = subprocess.run(
                    ["/usr/bin/bash", "-c", command], env=self.environment, capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"requires {binary}", result.stderr)
                self.assertFalse(self.log.exists())

    def test_local_examples_disable_bindings_after_defaults(self):
        examples = (ROOT / "sway/config.d/99-local.conf.example").read_text()
        bindings = (ROOT / "sway/config.d/60-keybindings.conf").read_text()
        for flags, key in re.findall(r"^bindsym (--locked )?(\S+) exec", bindings, re.MULTILINE):
            if key.startswith("XF86") or key in {"Print", "Shift+Print"}:
                self.assertIn(f"# unbindsym {flags}{key}\n", examples)
        for command in ("gammastep", "polkit_agent"):
            self.assertIn(f"# set ${command}_command true", examples)
        self.assertNotIn("set $audio_settings_command", examples)
        names = sorted(path.name for path in (ROOT / "sway/config.d").glob("*.conf*"))
        self.assertLess(names.index("60-keybindings.conf"), names.index("99-local.conf.example"))
        self.assertLess(names.index("99-local.conf.example"), names.index("99-startup.conf"))


if __name__ == "__main__":
    unittest.main()
