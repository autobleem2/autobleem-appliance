#!/usr/bin/env python3
"""Tests for tools/rpi_rootfs.py (PLATFORM-23): the MBR reading/resizing and the permission fix-up after
debugfs rdump. debugfs itself is faked by a script on PATH that prints what `debugfs -f` prints.

Run: python3 tests/test_rpi_rootfs.py
"""
import os
import stat
import struct
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "..", "tools", "rpi_rootfs.py")
sys.path.insert(0, os.path.join(HERE, "..", "tools"))
import rpi_rootfs  # noqa: E402


def make_mbr(path, parts):
    """An image file whose MBR has the given (start_sector, sector_count) entries."""
    data = bytearray(512)
    for i, (start, count) in enumerate(parts):
        struct.pack_into("<II", data, 0x1BE + i * 16 + 8, start, count)
    data[510:512] = b"\x55\xaa"
    with open(path, "wb") as f:
        f.write(data)


class MbrTest(unittest.TestCase):
    def test_offsets_and_resize(self):
        with tempfile.TemporaryDirectory() as d:
            img = os.path.join(d, "x.img")
            make_mbr(img, [(16384, 1048576), (1064960, 4374528)])
            out = subprocess.check_output([sys.executable, TOOL, "offsets", img]).split()
            self.assertEqual([int(x) for x in out], [16384 * 512, 1048576 * 512, 1064960 * 512, 4374528 * 512])
            subprocess.check_call([sys.executable, TOOL, "mbr-resize", img, "2", "7000000"], stdout=subprocess.DEVNULL)
            parts = rpi_rootfs.partitions(img)
            self.assertEqual(parts[1], (1064960 * 512, 7000000 * 512))
            self.assertEqual(parts[0], (16384 * 512, 1048576 * 512))     # the boot partition is untouched

    def test_one_partition_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            img = os.path.join(d, "x.img")
            make_mbr(img, [(16384, 1048576)])
            self.assertNotEqual(subprocess.call([sys.executable, TOOL, "offsets", img], stderr=subprocess.DEVNULL), 0)


class ParseTest(unittest.TestCase):
    def test_ls_p(self):
        text = "\n".join([
            "debugfs 1.47.2 (1-Jan-2025)",
            'debugfs: ls -p "/usr/lib/dbus-1.0"',
            "/7509/040755/0/0/.//",
            "/4936/040755/0/0/..//",
            "/7510/104754/0/990/dbus-daemon-launch-helper/38304/",
            "",
            'debugfs: ls -p "/tmp"',
            "/1500/041777/0/0/.//",
            "/77/100644/0/0/a file with spaces/5/",
        ])
        rows = list(rpi_rootfs.parse_ls_p(text))
        self.assertEqual(rows[0], ("/usr/lib/dbus-1.0", 7510, 0o104754, 0, 990, "dbus-daemon-launch-helper"))
        self.assertEqual(rows[1], ("/tmp", 77, 0o100644, 0, 0, "a file with spaces"))
        self.assertEqual(len(rows), 2)        # . and .. never


FAKE_DEBUGFS = """#!/bin/sh
# prints what debugfs -f prints for the commands in the file ($2 is -f's argument)
cat <<EOF
debugfs 1.47.2 (1-Jan-2025)
debugfs: ls -p "/"
/2/040755/{uid}/{gid}/.//
/2/040755/{uid}/{gid}/../
/12/104755/{uid}/{gid}/sudo/100/
/13/100644/{uid}/{gid}/a/5/
/13/100644/{uid}/{gid}/b/5/
/14/041777/{uid}/{gid}/tmp/4096/
/15/100644/{uid}/{gid}/gone/1/

debugfs: ls -p "/tmp"
/14/041777/{uid}/{gid}/.//
/2/040755/{uid}/{gid}/..//
EOF
"""


class FixModesTest(unittest.TestCase):
    def test_fixmodes(self):
        with tempfile.TemporaryDirectory() as d:
            root = os.path.join(d, "root")
            os.makedirs(os.path.join(root, "tmp"))
            for name, body in (("sudo", b"x" * 10), ("a", b"hello"), ("b", b"hello")):
                with open(os.path.join(root, name), "wb") as f:
                    f.write(body)
                os.chmod(os.path.join(root, name), 0o755 if name == "sudo" else 0o644)
            os.chmod(os.path.join(root, "tmp"), 0o755)
            bindir = os.path.join(d, "bin")
            os.makedirs(bindir)
            fake = os.path.join(bindir, "debugfs")
            with open(fake, "w") as f:
                f.write(FAKE_DEBUGFS.format(uid=os.getuid(), gid=os.getgid()))
            os.chmod(fake, 0o755)
            env = dict(os.environ, PATH=bindir + os.pathsep + os.environ["PATH"])
            out = subprocess.check_output([sys.executable, TOOL, "fixmodes", "ignored.img", "0", root], env=env).decode()
            self.assertTrue(os.stat(os.path.join(root, "sudo")).st_mode & stat.S_ISUID, "setuid back on sudo")
            self.assertEqual(stat.S_IMODE(os.stat(os.path.join(root, "tmp")).st_mode), 0o1777, "sticky /tmp")
            self.assertEqual(os.stat(os.path.join(root, "a")).st_ino, os.stat(os.path.join(root, "b")).st_ino,
                             "a and b are one inode in the image: linked again")
            self.assertIn("2 modes restored", out)
            self.assertIn("1 hard links", out)


if __name__ == "__main__":
    unittest.main()
