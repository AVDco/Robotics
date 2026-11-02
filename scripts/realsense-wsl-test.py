#!/usr/bin/env python3
"""Offline regression checks for the shipped WSL attach helper (no sudo/USB)."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("realsense-wsl.sh").read_text()
INSTALL = re.search(r"^install_udev\(\) \{\n.*?^\}", SCRIPT, re.M | re.S).group()
SELECT = re.search(r"^select_busid\(\) \{\n.*?^\}", SCRIPT, re.M | re.S).group()
STATE = re.search(r'^state=".*?^.*?\)"', SCRIPT, re.M | re.S).group()


class AttachHelperTest(unittest.TestCase):
    def test_busid_discovery(self):
        cases = (
            ("1-18 8086:0b5c D455 Shared\r\n", "1-18", True),
            ("2-4 30c9:00f8 Webcam Not shared\n3-5 8086:0B5C D455 Attached\n", "3-5", True),
            ("2-4 30c9:00f8 Webcam Not shared\n", "", False),
            ("1-6 8086:0b5c D455 Shared\n1-18 8086:0b5c D455 Shared\n", "", False),
        )
        for listing, expected, success in cases:
            with self.subTest(listing=listing):
                result = subprocess.run(
                    ["bash", "-c", SELECT + '\nselect_busid "$DEVICE_LIST"'],
                    env={**os.environ, "DEVICE_LIST": listing}, capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, success, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)

    def run_install(self, directory, fail=""):
        anchor = "/etc/udev/rules.d/99-realsense-libusb.rules"
        self.assertEqual(INSTALL.count(anchor), 1)
        install = INSTALL.replace(anchor, str(Path(directory) / "rules"))
        # Exercise the actual function, replacing only privileged command dispatch.
        mock = r'''
sudo() {
  if [ "$1" = udevadm ]; then
    printf '%s\n' "$*" >> "$EVENTS"
    [ -z "$FAIL_UDEV" ]
  else
    "$@"
  fi
}
'''
        return subprocess.run(
            ["bash", "-c", "set -uo pipefail\n" + mock + install + "\ninstall_udev"],
            env={**os.environ, "EVENTS": str(Path(directory) / "events"),
                 "FAIL_UDEV": fail}, capture_output=True, text=True)

    def test_install_and_upgrade(self):
        with tempfile.TemporaryDirectory() as d:
            rules = Path(d) / "rules"
            old = '# old USB-only rule\nSUBSYSTEM=="usb", MODE:="0666"\n'
            rules.write_text(old)
            result = self.run_install(d)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(Path(str(rules) + ".before-vision-access").read_text(), old)
            lines = [s for s in rules.read_text().splitlines() if not s.startswith("#")]
            self.assertEqual(len(lines), 3)
            for subsystem in ("usb", "video4linux", "hidraw"):
                line = next(s for s in lines if f'SUBSYSTEM=="{subsystem}"' in s)
                self.assertIn('ATTRS{idVendor}=="8086"', line)
                self.assertIn('ATTRS{idProduct}=="0b5c"', line)
                self.assertIn('MODE:="0666"', line)
                self.assertIn(f"--subsystem-match={subsystem}", (Path(d) / "events").read_text())
            before = rules.stat().st_mtime_ns
            events = (Path(d) / "events").read_text()
            self.assertEqual(self.run_install(d).returncode, 0)
            self.assertEqual(rules.stat().st_mtime_ns, before, "unchanged rules must not be rewritten")
            self.assertEqual((Path(d) / "events").read_text(), events,
                             "unchanged rules must not retrigger a running camera")
            self.assertEqual(Path(str(rules) + ".before-vision-access").read_text(), old)

    def test_udev_failure_is_not_ignored(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertNotEqual(self.run_install(d, fail="1").returncode, 0)

    def test_windows_state_lines(self):
        for state in ("Not shared", "Shared", "Attached"):
            for ending in ("\n", "\r\n"):
                with self.subTest(state=state, ending=repr(ending)):
                    line = f"1-6  8086:0b5c  Intel RealSense D455  {state}{ending}"
                    result = subprocess.run(
                        ["bash", "-c", 'line="$DEVICE_LINE"\n' + STATE + '\nprintf "%s" "$state"'],
                        env={**os.environ, "DEVICE_LINE": line.rstrip("\n")},
                        capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, state)


if __name__ == "__main__":
    unittest.main(verbosity=2)
