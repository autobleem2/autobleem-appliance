#!/usr/bin/env python3
"""payload_linux/system systemd units: no directive glued to a comment line, and autobleem.service's After=
list is the fast-boot one. Run: python3 tests/test_systemd_units.py"""
import glob
import os
import re
import unittest

SYSTEM_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "payload_linux", "system")
UNITS = sorted(glob.glob(os.path.join(SYSTEM_DIR, "*.service")))

# a comment line that carries "Name=value" after some prose: the directive is part of the comment, so systemd
# never sees it (this is how autobleem.service once lost its After= line)
GLUED = re.compile(r"^\s*[#;]\s*\S+.*\s(?:After|Before|Requires|Wants|Conflicts|RequiresMountsFor|BindsTo|PartOf"
                   r"|Requisite|Restart|RestartSec|ExecStart|Type|WantedBy)=\S")


def after_lists(path):
    """every unit named by After= lines of the [Unit] section, plus how many After= lines there are"""
    names, lines, section = [], 0, None
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if line.startswith("[") and line.endswith("]"):
                section = line
            elif section == "[Unit]" and line.startswith("After="):
                lines += 1
                names += line[len("After="):].split()
    return names, lines


class SystemdUnits(unittest.TestCase):
    def test_units_found(self):
        self.assertTrue(UNITS)

    def test_no_directive_glued_to_a_comment(self):
        for path in UNITS:
            with open(path, encoding="utf-8") as f:
                for n, line in enumerate(f, 1):
                    self.assertIsNone(GLUED.match(line), "%s:%d directive glued to a comment: %s"
                                      % (os.path.basename(path), n, line.strip()))

    def test_autobleem_service_after(self):
        names, lines = after_lists(os.path.join(SYSTEM_DIR, "autobleem.service"))
        self.assertGreaterEqual(lines, 1, "autobleem.service has no After= line")
        self.assertIn("systemd-udev-trigger.service", names)
        self.assertIn("plymouth-start.service", names)
        self.assertNotIn("systemd-user-sessions.service", names)
        for name in names:
            self.assertNotIn("network", name, "After= must not wait for the network: " + name)


if __name__ == "__main__":
    unittest.main()
