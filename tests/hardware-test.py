#!/usr/bin/env python3
"""Read fixture counters/sensors and mock NVIDIA output, never host hardware."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
BEFORE = "cpu 100 0 50 850 0 0 0 0 50 10\n"
AFTER = "cpu 112 0 50 938 0 0 0 0 80 20\n"


class HardwareTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(
            prefix="sway-noir-hardware-",
            dir="/tmp/opencode" if os.access("/tmp/opencode", os.W_OK) else None,
        )
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.proc = self.directory / "proc fixtures/stat"
        self.proc.parent.mkdir()
        self.proc.write_text(BEFORE)
        self.hwmon = self.directory / "sys fixtures/hwmon"
        self.thermal = self.directory / "sys fixtures/thermal"
        self.hwmon.mkdir(parents=True)
        self.thermal.mkdir()
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.nvidia_log = self.directory / "nvidia-arguments"
        self.script = self.directory / "hardware-status"
        source = (ROOT / "session/hardware-status").read_text()
        self.script.write_text(source.replace("/proc/stat", str(self.proc))
                               .replace("/sys/class/hwmon", str(self.hwmon))
                               .replace("/sys/class/thermal", str(self.thermal)))
        self.environment = {
            **os.environ, "PATH": str(self.bin), "STAT_FILE": str(self.proc),
            "STAT_AFTER": AFTER, "NVIDIA_LOG": str(self.nvidia_log),
            "NVIDIA_REPLY": "28, 61\n", "NVIDIA_STATUS": "0",
        }
        # Advance counters instantly instead of sleeping or reading the host.
        self.command("sleep", '[[ "$*" == 0.2 ]]\nprintf "%s" "$STAT_AFTER" > "$STAT_FILE"\n')

    def command(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/bash\nset -euo pipefail\n" + body)
        path.chmod(0o755)

    def nvidia(self):
        self.command("nvidia-smi", 'printf "%s\\n" "$@" > "$NVIDIA_LOG"\n'
                     'printf "%s" "$NVIDIA_REPLY"\nexit "$NVIDIA_STATUS"\n')

    def run_status(self, *arguments, success=True, **environment):
        result = subprocess.run(
            ["/usr/bin/bash", str(self.script), *arguments],
            env={**self.environment, **environment}, capture_output=True,
            text=True, timeout=5,
        )
        self.assertEqual(result.returncode == 0, success, result.stderr)
        if success:
            self.assertEqual(result.stderr, "")
        return result.stdout

    def sensor(self, device, driver, number, value, label=None):
        directory = self.hwmon / device
        directory.mkdir(exist_ok=True)
        (directory / "name").write_text(driver + "\n")
        path = directory / f"temp{number}_input"
        path.write_text(str(value) + "\n")
        if label is not None:
            (directory / f"temp{number}_label").write_text(label + "\n")
        return path

    def test_intel_package_temperature_has_degree_sign_only(self):
        self.sensor("hwmon3", "coretemp", 1, 54000, "Package id 0")
        self.sensor("hwmon3", "coretemp", 2, 61000, "Core 0")
        self.sensor("hwmon0", "nvme", 1, 99000, "Composite")
        self.assertEqual(self.run_status("cpu"), "12 · 54°\n")

    def test_hottest_cpu_package_is_selected_across_sockets(self):
        self.sensor("hwmon2", "coretemp", 1, 51000, "Package id 0")
        self.sensor("hwmon7", "coretemp", 1, 56000, "Package id 1")
        self.assertEqual(self.run_status("cpu"), "12 · 56°\n")

    def test_amd_die_is_preferred_over_control_temperature(self):
        for driver in ("k10temp", "zenpower"):
            with self.subTest(driver=driver):
                self.proc.write_text(BEFORE)
                self.sensor("hwmon2", driver, 1, 74000, "Tctl")
                self.sensor("hwmon2", driver, 2, 54000, "Tdie")
                self.assertEqual(self.run_status("cpu"), "12 · 54°\n")

    def test_invalid_die_reading_falls_back_to_control_temperature(self):
        self.sensor("hwmon0", "k10temp", 1, 64000, "Tctl")
        self.sensor("hwmon0", "k10temp", 2, 999999, "Tdie")
        self.assertEqual(self.run_status("cpu"), "12 · 64°\n")

    def test_core_temperature_is_used_if_package_reading_is_missing(self):
        self.sensor("hwmon0", "coretemp", 2, 53000, "Core 0")
        self.sensor("hwmon0", "coretemp", 3, 57000, "Core 1")
        self.assertEqual(self.run_status("cpu"), "12 · 57°\n")

    def test_cpu_thermal_zone_fallback_ignores_other_devices(self):
        for number, kind, temperature in ((0, "acpitz", 91000),
                                           (2, "x86_pkg_temp", 54000)):
            zone = self.thermal / f"thermal_zone{number}"
            zone.mkdir()
            (zone / "type").write_text(kind + "\n")
            (zone / "temp").write_text(str(temperature) + "\n")
        self.sensor("hwmon1", "amdgpu", 1, 80000)
        self.assertEqual(self.run_status("cpu"), "12 · 54°\n")

    def test_cpu_temperature_can_be_explicitly_selected(self):
        selected = self.sensor("hwmon0", "custom-driver", 2, 59000)
        self.sensor("hwmon1", "coretemp", 1, 54000, "Package id 0")
        self.assertEqual(self.run_status("cpu", str(selected)), "12 · 59°\n")

    def test_missing_invalid_and_disappearing_sensors_keep_usage(self):
        sensor = self.sensor("hwmon0", "coretemp", 1, 54000, "Package id 0")
        for value in ("", "N/A", "999999", "-999999", "54.0", "1+2", "0x8000"):
            with self.subTest(value=value):
                self.proc.write_text(BEFORE)
                sensor.write_text(value)
                self.assertEqual(self.run_status("cpu"), "12\n")
        sensor.unlink()
        self.proc.write_text(BEFORE)
        self.assertEqual(self.run_status("cpu"), "12\n")
        self.proc.write_text(BEFORE)
        self.assertEqual(self.run_status("cpu", str(sensor)), "12\n")

    def test_zero_temperature_is_not_treated_as_missing(self):
        self.sensor("hwmon0", "coretemp", 1, 0, "Package id 0")
        self.assertEqual(self.run_status("cpu"), "12 · 0°\n")

    def test_iowait_and_guest_counters_are_not_counted_as_extra_cpu_work(self):
        self.assertEqual(self.run_status(
            "cpu", STAT_AFTER="cpu 112 0 50 918 20 0 0 0 8000 7000\n",
        ), "12\n")

    def test_cpu_usage_boundaries(self):
        for counters, expected in (
            ("cpu 100 0 50 950 0 0 0 0\n", "0\n"),
            ("cpu 200 0 50 850 0 0 0 0\n", "100\n"),
        ):
            with self.subTest(counters=counters):
                self.proc.write_text(BEFORE)
                self.assertEqual(self.run_status("cpu", STAT_AFTER=counters), expected)

    def test_invalid_reset_and_unchanged_cpu_counters_hide_reading(self):
        for counters in (BEFORE, "cpu 0 0 0 0 0 0 0 0\n", "cpu broken\n",
                         "cpu 999999999999999999999 0 0 0 0 0 0 0\n"):
            with self.subTest(counters=counters):
                self.proc.write_text(BEFORE)
                self.assertEqual(self.run_status("cpu", STAT_AFTER=counters), "")
        self.proc.unlink()
        self.assertEqual(self.run_status("cpu"), "")

    def test_nvidia_utilization_and_temperature_has_degree_sign_only(self):
        self.nvidia()
        self.assertEqual(self.run_status("gpu"), "28 · 61°\n")
        self.assertEqual(self.nvidia_log.read_text().splitlines(), [
            "--query-gpu=utilization.gpu,temperature.gpu",
            "--format=csv,noheader,nounits", "-i", "0",
        ])

    def test_nvidia_index_and_whitespace(self):
        self.nvidia()
        self.assertEqual(self.run_status("gpu", "1", NVIDIA_REPLY=" 7 ,  54 \n"), "7 · 54°\n")
        self.assertEqual(self.nvidia_log.read_text().splitlines()[-1], "1")

    def test_missing_nvidia_temperature_keeps_utilization(self):
        self.nvidia()
        for value in ("N/A", "[Not Supported]", "", "999", "$(false)"):
            with self.subTest(temperature=value):
                self.assertEqual(self.run_status("gpu", NVIDIA_REPLY=f"28, {value}\n"), "28\n")

    def test_missing_command_driver_or_invalid_gpu_reading_hides_module(self):
        self.assertEqual(self.run_status("gpu"), "")
        self.nvidia()
        self.assertEqual(self.run_status("gpu", NVIDIA_STATUS="1"), "")
        for value in ("", "N/A, 54", "101, 54", "-1, 54", "28", "28, 54\n29, 55"):
            with self.subTest(value=value):
                self.assertEqual(self.run_status("gpu", NVIDIA_REPLY=value), "")

    def test_external_strings_are_never_executed(self):
        self.nvidia()
        marker = self.directory / "must-not-exist"
        text = f'$(touch "{marker}")'
        self.sensor("hwmon0", "coretemp", 1, text, "Package id 0")
        self.assertEqual(self.run_status("cpu"), "12\n")
        self.assertEqual(self.run_status("gpu", NVIDIA_REPLY=f"{text}, 54"), "")
        self.run_status("gpu", text, success=False)
        self.assertFalse(marker.exists())

    def test_invalid_arguments_do_not_query_hardware(self):
        self.nvidia()
        for arguments in ((), ("other",), ("gpu", "-1"), ("gpu", "10000"),
                          ("cpu", "relative/path"), ("cpu", "/sensor", "extra")):
            with self.subTest(arguments=arguments):
                self.run_status(*arguments, success=False)
        self.assertFalse(self.nvidia_log.exists())


if __name__ == "__main__":
    unittest.main()
