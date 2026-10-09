"""tools/check_release.sh: the site packs pinned in the release lock ([pack.<name>] file + sha256), PLATFORM-23 (7)."""
import hashlib
import io
import os
import subprocess
import tempfile
import unittest
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "tools", "check_release.sh")
ALPHA1 = os.path.join(ROOT, "release", "v2.0.0-alpha1.lock")



def small_zip(text):
    # check_release.sh unpacks autobleem-psc-*.zip as a launcher package, so the stick zips must be real zips
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr(zipfile.ZipInfo("Autobleem/note.txt", date_time=(2026, 1, 1, 0, 0, 0)), text)
    return buf.getvalue()


PACKS = {
    "psc-installer-full": ("AutoBleemInstaller-v9.0.0-full.zip", b"installer"),
    "psc-stick-base": ("autobleem-psc-v9.0.0-base.zip", small_zip("base")),
    "psc-stick-full": ("autobleem-psc-v9.0.0-full.zip", small_zip("full")),
    "rpi-image-arm64": ("autobleem-v9.0.0-rpi-arm64.img.xz", b"image"),
    "retroarch-psc": ("retroarch-psc-1.0.zip", b"ra"),
    "cores-psc": ("cores-psc-20261001.tar.gz", b"cores"),
}
HEAD = "[release]\nversion = v9.0.0\nchannel = prerelease\nsdk = 8\n\n[launcher]\ncommit = abcdef0\n\n"


def lock_text(packs=PACKS, digests=None):
    out = HEAD
    for name, (fname, data) in packs.items():
        digest = (digests or {}).get(name) or hashlib.sha256(data).hexdigest()
        out += "[pack.%s]\nfile = %s\nversion = v9.0.0\nsha256 = %s\n\n" % (name, fname, digest)
    return out


class CheckPacks(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = self._tmp.name
        self.dist = os.path.join(self.tmp, "dist")
        os.mkdir(self.dist)
        self.addCleanup(self._tmp.cleanup)

    def write_packs(self, skip=(), changed=()):
        for name, (fname, data) in PACKS.items():
            if name in skip:
                continue
            with open(os.path.join(self.dist, fname), "wb") as f:
                f.write(data + (b"!" if name in changed else b""))

    def run_check(self, text, lock_name="test.lock"):
        lock = os.path.join(self.tmp, lock_name)
        with open(lock, "w") as f:
            f.write(text)
        p = subprocess.run(["bash", SCRIPT, lock, self.dist], capture_output=True, text=True, timeout=120)
        return p.returncode, p.stdout + p.stderr

    def test_fully_pinned_lock_passes(self):
        self.write_packs()
        rc, out = self.run_check(lock_text())
        self.assertEqual(rc, 0, out)
        for name in PACKS:
            self.assertIn("PASS pack %s:" % name, out)

    def test_missing_pack_fails(self):
        self.write_packs(skip=("psc-installer-full",))
        rc, out = self.run_check(lock_text())
        self.assertEqual(rc, 1, out)
        self.assertIn("FAIL pack psc-installer-full: AutoBleemInstaller-v9.0.0-full.zip is missing", out)
        self.assertIn("PASS pack psc-stick-base:", out)

    def test_hash_mismatch_fails(self):
        self.write_packs(changed=("cores-psc",))
        rc, out = self.run_check(lock_text())
        self.assertEqual(rc, 1, out)
        self.assertIn("FAIL pack cores-psc:", out)
        self.assertIn("sha256 expected", out)

    def test_bad_digest_in_lock_fails(self):
        self.write_packs()
        rc, out = self.run_check(lock_text(digests={"psc-stick-full": "TBD"}))
        self.assertEqual(rc, 1, out)
        self.assertIn("FAIL pack psc-stick-full: lock entry needs file and a 64-hex sha256", out)

    def test_bios_is_never_in_the_lock(self):
        packs = {"bios": ("biospack-1.zip", b"x")}
        with open(os.path.join(self.dist, "biospack-1.zip"), "wb") as f:
            f.write(b"x")
        rc, out = self.run_check(lock_text(packs))
        self.assertEqual(rc, 1, out)
        self.assertIn("BIOS is never in the lock", out)

    def test_alpha1_lock_still_validates(self):
        # no pack sections: nothing extra is checked, and the lock is still read
        with open(ALPHA1) as f:
            text = f.read()
        self.assertNotIn("[pack.", text)
        rc, out = self.run_check(text, "alpha1.lock")
        self.assertEqual(rc, 0, out)
        self.assertIn("0 passed, 0 failed", out)


if __name__ == "__main__":
    unittest.main()
