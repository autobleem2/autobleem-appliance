#!/usr/bin/env python3
"""tools/check_psc_modes.sh: a staged program without u+x fails the check. Run: python3 tests/test_psc_modes.py"""
import os
import subprocess
import tempfile
import unittest

CHECK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools", "check_psc_modes.sh")
ELF = b"\x7fELF\x02\x01\x01\x00"


def put(stage, rel, data, mode):
    path = os.path.join(stage, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)
    os.chmod(path, mode)


def run(stage):
    return subprocess.run(["bash", CHECK, stage], capture_output=True, text=True)


class CheckPscModes(unittest.TestCase):
    def test_good_tree_passes(self):
        with tempfile.TemporaryDirectory() as s:
            put(s, "Autobleem/bin/autobleem/abfetch", ELF, 0o755)
            put(s, "Autobleem/bin/autobleem/run.sh", b"#!/bin/sh\n", 0o755)
            put(s, "Autobleem/bin/autobleem/libx.so.1", ELF, 0o644)
            put(s, "Autobleem/bin/autobleem/data.ini", b"a=b\n", 0o644)
            put(s, "Autobleem/bin/emu/pcsx-ab", ELF, 0o755)
            self.assertEqual(run(s).returncode, 0)

    def test_elf_without_bit_fails(self):
        with tempfile.TemporaryDirectory() as s:
            put(s, "Autobleem/bin/autobleem/abdialog", ELF, 0o644)
            r = run(s)
            self.assertEqual(r.returncode, 1)
            self.assertIn("Autobleem/bin/autobleem/abdialog", r.stderr)

    def test_script_without_bit_fails(self):
        for rel in ("Autobleem/rc/x.sh", "Autobleem/bin/emunxt/run", "Autobleem/bin/abpad/abpadd"):
            with tempfile.TemporaryDirectory() as s:
                put(s, rel, b"#!/bin/sh\n", 0o644)
                self.assertEqual(run(s).returncode, 1, rel)


if __name__ == "__main__":
    unittest.main()
