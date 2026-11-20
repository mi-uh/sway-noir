#!/usr/bin/env python3
"""Check CI path selection using real, isolated Git histories."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / ".github/scripts/fedora_changes.py"
# Tests must not leave compiled helper files in the source checkout.
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("fedora_changes", SCRIPT)
CHANGES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHANGES)


class FedoraPackages(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(
            prefix="sway-noir-fedora-packages-",
            dir="/tmp/opencode" if os.access("/tmp/opencode", os.W_OK) else None,
        )
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.packages = self.directory / "packages"
        self.useradd = self.directory / "useradd"
        (self.directory / "dependencies.list").write_text((ROOT / "dependencies.list").read_text())
        # Execute the actual workflow block without a package manager or host writes.
        workflow = (ROOT / ".github/workflows/fedora.yml").read_text()
        step = workflow.split("      - name: Install Fedora dependencies", 1)[1]
        step = step.split("      - name:", 1)[0]
        self.script = textwrap.dedent(step.split("        run: |\n", 1)[1])
        self.command("dnf", 'printf "%s\\n" "$@" > "$PACKAGE_LOG"\n'
                     'for package; do\n'
                     '  [[ "$package" != xorg-x11-drv-nvidia-cuda ]] || exit 25\n'
                     'done\nexit "$DNF_STATUS"\n')
        self.command("useradd", 'printf "%s\\n" "$@" > "$USERADD_LOG"\n')

    def command(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/bash\nset -euo pipefail\n" + body)
        path.chmod(0o755)

    def run_install_step(self, status="0"):
        return subprocess.run(
            ["/usr/bin/bash", "-c", self.script], cwd=self.directory,
            env={**os.environ, "PATH": str(self.bin), "PACKAGE_LOG": str(self.packages),
                 "USERADD_LOG": str(self.useradd), "DNF_STATUS": status},
            capture_output=True, text=True, timeout=10,
        )

    def test_base_repository_packages_exclude_vendor_nvidia_driver_tools(self):
        result = self.run_install_step()
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = self.packages.read_text().splitlines()
        self.assertEqual(arguments[:2], ["install", "-y"])
        self.assertNotIn("--skip-unavailable", arguments)
        self.assertNotIn("xorg-x11-drv-nvidia-cuda", arguments)
        for line in (self.directory / "dependencies.list").read_text().splitlines():
            if not line or line.startswith("#"):
                continue
            scope, _check, _capability, fedora, _debian, _arch = line.split("|")
            if scope in {"profile", "dark"}:
                for package in fedora.split():
                    self.assertIn(package, arguments)
        for package in ("ShellCheck", "ibm-plex-sans-fonts", "lxqt-policykit"):
            self.assertIn(package, arguments)
        self.assertTrue(self.useradd.exists())

    def test_package_installation_failure_still_stops_the_job(self):
        result = self.run_install_step(status="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.packages.exists())
        self.assertFalse(self.useradd.exists())


class FedoraChanges(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(
            prefix="sway-noir-ci-",
            dir="/tmp/opencode" if os.access("/tmp/opencode", os.W_OK) else None,
        )
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.repository = self.directory / "repository"
        self.repository.mkdir()
        self.environment = {
            **os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
        }
        self.git("init", "--initial-branch=main")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        (self.repository / "README.md").write_text("Initial documentation\n")
        (self.repository / "dependencies.list").write_text("Initial dependencies\n")
        self.base = self.commit()

    def git(self, *arguments):
        return subprocess.check_output(
            ["git", *arguments], cwd=self.repository, env=self.environment,
            text=True, stderr=subprocess.PIPE,
        ).strip()

    def commit(self):
        self.git("add", ".")
        self.git("commit", "--allow-empty", "-m", "Fixture change")
        return self.git("rev-parse", "HEAD")

    def push_decision(self, head):
        return CHANGES.needs_fedora("push", {"before": self.base, "after": head}, self.repository)[0]

    def test_relevant_paths(self):
        for path in (
            "dependencies.list", "install.sh", "start-sway-noir", "session/theme",
            "session/installer/files.sh", "tests/install-test.sh", "tests/preflight-test.sh",
            "tests/dependencies-test.py", "tests/registry-test.sh", "tests/polkit-test.py",
            "tests/run.sh", "tests/new-platform-test.py", "tests/new-helper.py",
            ".github/workflows/secrets.yml", ".github/scripts/fedora_changes.py",
        ):
            with self.subTest(path=path):
                self.assertTrue(CHANGES.relevant_path(path))

    def test_unrelated_paths(self):
        for path in (
            "README.md", "ASSETS.md", "tests/README.md", ".github/scripts/README.md",
            "screenshots/rain.webp", "themes/praxis/wallpaper.jpg", "themes/rain/theme.conf",
            "waybar/config.jsonc", "sway/config.d/99-startup.conf", "session-other/config",
            "tests/theme-test.py", "tests/waybar-test.py", "tests/waybar_config.py", "tests/ci-test.py",
        ):
            with self.subTest(path=path):
                self.assertFalse(CHANGES.relevant_path(path))

    def test_documentation_only_push_skips_fedora(self):
        (self.repository / "README.md").write_text("Updated documentation\n")
        self.assertFalse(self.push_decision(self.commit()))

    def test_dependency_push_runs_fedora(self):
        (self.repository / "dependencies.list").write_text("New dependency\n")
        self.assertTrue(self.push_decision(self.commit()))

    def test_appearance_changes_with_tests_skip_fedora_for_push_and_pr(self):
        for path in ("themes/praxis/waybar/style.css", "themes/retro/waybar/style.css",
                     "waybar/base.jsonc", "tests/theme-test.py", "tests/waybar-test.py",
                     "tests/waybar_config.py", "tests/README.md"):
            file = self.repository / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text("Appearance change\n")
        head = self.commit()
        self.assertFalse(self.push_decision(head))
        required, _ = CHANGES.needs_fedora(
            "pull_request", {"pull_request": {"base": {"sha": self.base}, "head": {"sha": head}}},
            self.repository,
        )
        self.assertFalse(required)
        self.run_cli({"before": self.base, "after": head}, "false")

    def test_platform_tests_still_trigger_fedora_alongside_appearance_tests(self):
        tests = self.repository / "tests"
        tests.mkdir()
        (tests / "theme-test.py").write_text("Appearance check\n")
        (tests / "dependencies-test.py").write_text("Dependency check\n")
        head = self.commit()
        self.assertTrue(self.push_decision(head))
        required, _ = CHANGES.needs_fedora(
            "pull_request", {"pull_request": {"base": {"sha": self.base}, "head": {"sha": head}}},
            self.repository,
        )
        self.assertTrue(required)

    def test_session_changes_still_trigger_fedora_alongside_appearance_tests(self):
        for path in ("tests/theme-test.py", "session/theme"):
            file = self.repository / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text("Change\n")
        self.assertTrue(self.push_decision(self.commit()))

    def test_renaming_appearance_test_to_platform_test_runs_fedora(self):
        tests = self.repository / "tests"
        tests.mkdir()
        (tests / "theme-test.py").write_text("Test\n")
        self.base = self.commit()
        self.git("mv", "tests/theme-test.py", "tests/dependencies-test.py")
        self.assertTrue(self.push_decision(self.commit()))

    def test_empty_commit_skips_fedora(self):
        self.assertFalse(self.push_decision(self.commit()))

    def test_pr_dependency_change_runs_fedora(self):
        (self.repository / "dependencies.list").write_text("New dependency\n")
        head = self.commit()
        required, _ = CHANGES.needs_fedora(
            "pull_request", {"pull_request": {"base": {"sha": self.base}, "head": {"sha": head}}},
            self.repository,
        )
        self.assertTrue(required)

    def test_all_commits_in_push_are_considered(self):
        (self.repository / "dependencies.list").write_text("New dependency\n")
        self.commit()
        (self.repository / "README.md").write_text("Document new dependency\n")
        self.assertTrue(self.push_decision(self.commit()))

    def test_deleted_dependency_file_runs_fedora(self):
        (self.repository / "dependencies.list").unlink()
        self.assertTrue(self.push_decision(self.commit()))

    def test_renamed_dependency_file_runs_fedora(self):
        self.git("mv", "dependencies.list", "archived-dependencies.txt")
        self.assertTrue(self.push_decision(self.commit()))

    def test_pr_ignores_unrelated_base_branch_changes(self):
        self.git("checkout", "-b", "topic", self.base)
        (self.repository / "README.md").write_text("PR documentation\n")
        head = self.commit()
        self.git("checkout", "main")
        (self.repository / "dependencies.list").write_text("Unrelated base dependency change\n")
        base = self.commit()
        required, _ = CHANGES.needs_fedora(
            "pull_request", {"pull_request": {"base": {"sha": base}, "head": {"sha": head}}},
            self.repository,
        )
        self.assertFalse(required)

    def test_uncertain_comparisons_run_fedora(self):
        for name, event in (
            ("workflow_dispatch", {}), ("unknown", {}), ("push", None), ("push", {}),
            ("pull_request", {"pull_request": None}),
            ("push", {"before": "0" * 40, "after": self.base}),
            ("push", {"before": "1" * 40, "after": self.base}),
            ("push", {"before": "invalid", "after": self.base}),
        ):
            with self.subTest(name=name, event=event):
                self.assertTrue(CHANGES.needs_fedora(name, event, self.repository)[0])

    def test_output_for_documentation_only_push(self):
        (self.repository / "README.md").write_text("Documentation\n")
        self.run_cli({"before": self.base, "after": self.commit()}, "false")

    def test_malformed_event_runs_fedora(self):
        self.run_cli("{invalid", "true")

    def run_cli(self, event, expected):
        event_path = self.directory / "event.json"
        event_path.write_text(json.dumps(event) if isinstance(event, dict) else event)
        output_path = self.directory / "output"
        result = subprocess.run(
            [sys.executable, str(SCRIPT)], cwd=self.repository, capture_output=True, text=True,
            env={**self.environment, "GITHUB_EVENT_NAME": "push", "GITHUB_EVENT_PATH": str(event_path),
                 "GITHUB_OUTPUT": str(output_path)}, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output_path.read_text(), f"fedora={expected}\n")


if __name__ == "__main__":
    unittest.main()
