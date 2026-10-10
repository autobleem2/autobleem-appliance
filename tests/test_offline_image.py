"""The Pi image's offline payload: tools/check_image.sh on a tiny fake root, and install.sh's offline fall-back
for the cover databases and the sample pack (they come from the image when it checks out, else from the site)."""
import hashlib
import io
import os
import re
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHECK_IMAGE = os.path.join(ROOT, "tools", "check_image.sh")
INSTALL_SH = os.path.join(ROOT, "payload_linux", "install.sh")
SBIN = os.environ.get("PATH", "") + ":/usr/sbin:/sbin"
ENV = dict(os.environ, PATH=SBIN)


def have(*tools):
    return all(shutil.which(t, path=SBIN) for t in tools)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def make_tar(members, top="autobleem-rpi-v9/"):
    """members: {path: bytes} -> tar.gz bytes, under a top folder like assemble.sh's"""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as t:
        for path, data in members.items():
            ti = tarfile.TarInfo(top + path)
            ti.size = len(data)
            t.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


STAMP = b"\0sdk=%d;cxx=gcc-12;cxx11abi=1;target=rpi\0"


def package(sdk=8, ext_sdk=8, drop=()):
    members = {
        "Autobleem/bin/autobleem/autobleem-gui": b"ELF" + STAMP % sdk,
        "extensions/store/extension.ini": b"x",
        "extensions/store/bin/rpi/store.so": b"ELF" + STAMP % ext_sdk,
        "extensions/pscbios/extension.ini": b"x",
        "extensions/pscbios/bin/rpi/pscbios.so": b"ELF" + STAMP % ext_sdk,
        "processors/unzip/processor.ini": b"x",
        "processors/pe/processor.ini": b"x",
    }
    for d in drop:
        members = {k: v for k, v in members.items() if not k.startswith(d + "/")}
    return make_tar(members)


FILES = {
    "retroarch.tar.gz": b"ra",
    "cores.tar.gz": b"cores",
    "coversU.db": b"U",
    "coversP.db": b"P",
    "coversJ.db": b"J",
    "samples.tar.gz": make_tar({"Games/G1/Game.ini": b"x"}, top=""),
}


def build_image(tmp, pkg=None, files=None, sums_extra=None, journald=True, skip=(), bad_sum=()):
    """a tiny image: MBR with a small first partition and an ext4 second one holding the fake root"""
    root = os.path.join(tmp, "root")
    off = os.path.join(root, "opt", "autobleem-image", "offline")
    os.makedirs(off)
    files = FILES if files is None else files
    sums = ""
    for name, data in files.items():
        if name in skip:
            continue
        with open(os.path.join(off, name), "wb") as f:
            f.write(data)
        sums += "%s  %s\n" % ("0" * 64 if name in bad_sum else sha(data), name)
    if "SHA256SUMS" not in skip:
        with open(os.path.join(off, "SHA256SUMS"), "w") as f:
            f.write(sums + (sums_extra or ""))
    with open(os.path.join(root, "opt", "autobleem-image", "autobleem-rpi.tar.gz"), "wb") as f:
        f.write(pkg if pkg is not None else package())
    if journald:
        os.makedirs(os.path.join(root, "etc", "systemd", "journald.conf.d"))
        with open(os.path.join(root, "etc", "systemd", "journald.conf.d", "autobleem-persistent.conf"), "w") as f:
            f.write("[Journal]\nStorage=persistent\n")
    img = os.path.join(tmp, "test.img")
    start = 2048                      # sectors: the offset comes from the table, not a constant
    fs_mib = 8
    with open(img, "wb") as f:
        f.truncate((start + 100 + fs_mib * 2048) * 512)
    table = "label: dos\nunit: sectors\n\n%d,100,c\n%d,%d,83\n" % (start - 1000, start + 100, fs_mib * 2048)
    subprocess.run(["sfdisk", "-q", img], input=table, text=True, env=ENV, check=True, capture_output=True)
    subprocess.run(["mke2fs", "-q", "-F", "-t", "ext4", "-d", root, "-E", "offset=%d" % ((start + 100) * 512),
                    img, "%dM" % fs_mib], env=ENV, check=True, capture_output=True)
    return img


@unittest.skipUnless(have("debugfs", "sfdisk", "mke2fs"), "needs e2fsprogs and sfdisk")
class CheckImage(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = self._tmp.name
        self.addCleanup(self._tmp.cleanup)

    def run_check(self, img, *args):
        p = subprocess.run(["bash", CHECK_IMAGE, img, *args], capture_output=True, text=True, env=ENV, timeout=120)
        return p.returncode, p.stdout, p.stderr

    def test_good_image_passes(self):
        rc, out, err = self.run_check(build_image(self.tmp))
        self.assertEqual((rc, err), (0, ""), out)
        self.assertTrue(out.startswith("OK:"), out)

    def test_good_image_xz_and_arm64(self):
        img = build_image(self.tmp)
        subprocess.run(["xz", "-k", img], check=True)
        for arch in ("arm64", "armhf"):
            rc, out, _ = self.run_check(img + ".xz", "--arch", arch)
            self.assertEqual(rc, 0, out)

    def test_pe_required_on_every_arch(self):
        img = build_image(self.tmp, pkg=package(drop=("processors/pe",)))
        for arch in ("arm64", "armhf"):
            rc, out, _ = self.run_check(img, "--arch", arch)
            self.assertEqual(rc, 1, out)
            self.assertIn("no processors/pe/", out)

    def test_missing_offline_file_and_sums_line(self):
        rc, out, _ = self.run_check(build_image(self.tmp, skip=("coversJ.db", "SHA256SUMS")))
        self.assertEqual(rc, 1, out)
        self.assertIn("offline/coversJ.db is missing", out)
        self.assertIn("offline/SHA256SUMS is missing", out)
        self.assertEqual(len(out.strip().splitlines()), 7, out)   # SHA256SUMS + J, then no line for the other five

    def test_sha_mismatch(self):
        rc, out, _ = self.run_check(build_image(self.tmp, bad_sum=("samples.tar.gz",)))
        self.assertEqual(rc, 1, out)
        self.assertRegex(out, r"FAIL: .*samples\.tar\.gz: sha256 [0-9a-f]{64} does not match")
        self.assertEqual(len(out.strip().splitlines()), 1, out)

    def test_package_without_store_and_unzip(self):
        img = build_image(self.tmp, pkg=package(drop=("extensions/store", "processors/unzip")))
        rc, out, _ = self.run_check(img)
        self.assertEqual(rc, 1, out)
        self.assertIn("no extensions/store/", out)
        self.assertIn("no processors/unzip/", out)
        self.assertNotIn("pscbios", out)

    def test_extension_sdk_differs_from_launcher(self):
        rc, out, _ = self.run_check(build_image(self.tmp, pkg=package(sdk=8, ext_sdk=7)))
        self.assertEqual(rc, 1, out)
        self.assertIn("store.so carries sdk=7, the launcher is sdk=8", out)

    def test_sdk_argument_when_launcher_is_unreadable(self):
        pkg = package()
        pkg = make_tar({
            "Autobleem/bin/autobleem/autobleem-gui": b"UPX!",
            "extensions/store/bin/rpi/store.so": b"ELF" + STAMP % 8,
            "extensions/pscbios/bin/rpi/pscbios.so": b"ELF" + STAMP % 8,
            "processors/unzip/processor.ini": b"x",
            "processors/pe/processor.ini": b"x",
        })
        img = build_image(self.tmp, pkg=pkg)
        rc, out, _ = self.run_check(img)
        self.assertEqual(rc, 1, out)
        self.assertIn("pass --sdk N", out)
        rc, out, _ = self.run_check(img, "--sdk", "8")
        self.assertEqual(rc, 0, out)
        rc, out, _ = self.run_check(img, "--sdk", "9")
        self.assertEqual(rc, 1, out)

    def test_launcher_and_sdk_argument_disagree(self):
        rc, out, _ = self.run_check(build_image(self.tmp), "--sdk", "9")
        self.assertEqual(rc, 1, out)
        self.assertIn("launcher's SDK ABI is 8, --sdk says 9", out)

    def test_no_persistent_journal(self):
        rc, out, _ = self.run_check(build_image(self.tmp, journald=False))
        self.assertEqual(rc, 1, out)
        self.assertIn("autobleem-persistent.conf is missing", out)

    def test_image_is_not_changed(self):
        img = build_image(self.tmp)
        before = sha(open(img, "rb").read())
        self.run_check(img)
        self.assertEqual(sha(open(img, "rb").read()), before)


def extract(fn):
    text = open(INSTALL_SH).read()
    m = re.search(r"^%s\(\) \{\n.*?^\}\n" % fn, text, re.S | re.M)
    assert m, fn
    return m.group(0)


class InstallOfflineFallback(unittest.TestCase):
    """offline_setup + install_cover_databases + install_sample_games, extracted from install.sh, with a wget stub
    that records every request and fails"""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = self._tmp.name
        self.addCleanup(self._tmp.cleanup)
        self.off = os.path.join(self.tmp, "offline")
        self.data = os.path.join(self.tmp, "data")
        os.makedirs(self.off)
        os.makedirs(self.data)
        os.makedirs(os.path.join(self.tmp, "bin"))
        self.calls = os.path.join(self.tmp, "wget.calls")
        stub = os.path.join(self.tmp, "bin", "wget")
        with open(stub, "w") as f:
            f.write('#!/bin/sh\necho "wget $*" >> "%s"\nexit 1\n' % self.calls)
        os.chmod(stub, 0o755)
        funcs = "".join(extract(f) for f in ("offline_setup", "install_cover_databases", "install_sample_games"))
        self.script = os.path.join(self.tmp, "funcs.sh")
        with open(self.script, "w") as f:
            f.write('log() { echo "log: $*"; }\nwarn() { echo "warn: $*"; }\n' + funcs)

    def stage(self, changed=(), skip=()):
        sums = ""
        for name, data in FILES.items():
            if name in skip:
                continue
            with open(os.path.join(self.off, name), "wb") as f:
                f.write(data + (b"!" if name in changed else b""))
            sums += "%s  %s\n" % (sha(data), name)
        with open(os.path.join(self.off, "SHA256SUMS"), "w") as f:
            f.write(sums)

    def run_install(self, dry=0, offline=True):
        body = ('set -u\nDRY_RUN=%d; OFFLINE_DIR="%s"; OFFLINE_GOOD=" "; RETROARCH_TARBALL=""; CORES_TARBALL=""\n'
                'DATA_MOUNT="%s"; REPO_URL=http://site.invalid; DO_SAMPLES=1; RETROARCH_MODE=none\n'
                'offline_setup\ninstall_cover_databases\ninstall_sample_games\n'
                % (dry, self.off if offline else "", self.data))
        p = subprocess.run(["bash", "-c", "source %s\n%s" % (self.script, body)], capture_output=True, text=True,
                           env=dict(os.environ, PATH=os.path.join(self.tmp, "bin") + ":" + os.environ["PATH"]),
                           timeout=60)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        wgets = open(self.calls).read().splitlines() if os.path.exists(self.calls) else []
        return p.stdout, wgets

    def db(self, name):
        return os.path.join(self.data, "Autobleem", "bin", "db", name)

    def test_everything_from_the_image_makes_no_request(self):
        self.stage()
        out, wgets = self.run_install()
        self.assertEqual(wgets, [])
        for name in ("coversU.db", "coversP.db", "coversJ.db"):
            self.assertEqual(open(self.db(name), "rb").read(), FILES[name])
        self.assertTrue(os.path.exists(os.path.join(self.data, "Games", "G1", "Game.ini")))
        self.assertIn("pack the image", open(os.path.join(self.data, "System", "samples.txt")).read())

    def test_dry_run_names_the_image_and_asks_nothing(self):
        self.stage()
        out, wgets = self.run_install(dry=1)
        self.assertEqual(wgets, [])
        self.assertIn("would copy coversU.db from", out)
        self.assertIn("would unpack the sample pack", out)
        self.assertFalse(os.path.exists(self.db("coversU.db")))

    def test_damaged_file_falls_back_to_the_site(self):
        self.stage(changed=("coversP.db", "samples.tar.gz"))
        out, wgets = self.run_install()
        self.assertIn("warn: Offline: coversP.db does not match", out)
        self.assertTrue(any("db/coversP.db" in w for w in wgets), wgets)
        self.assertTrue(any("samples/latest.json" in w for w in wgets), wgets)
        self.assertFalse(any("coversU.db" in w or "coversJ.db" in w for w in wgets), wgets)
        self.assertEqual(open(self.db("coversU.db"), "rb").read(), b"U")
        self.assertFalse(os.path.exists(self.db("coversP.db")))
        self.assertFalse(os.path.exists(os.path.join(self.data, "System", "samples.txt")))

    def test_missing_file_falls_back_to_the_site(self):
        self.stage(skip=("coversJ.db",))
        out, wgets = self.run_install()
        self.assertTrue(any("db/coversJ.db" in w for w in wgets), wgets)
        self.assertFalse(any("samples" in w for w in wgets), wgets)

    def test_without_offline_everything_comes_from_the_site(self):
        self.stage()
        out, wgets = self.run_install(offline=False)
        self.assertEqual(len([w for w in wgets if "/db/covers" in w and ".sha256" not in w]), 3, wgets)
        self.assertTrue(any("samples/latest.json" in w for w in wgets), wgets)


class CheckReleaseBundled(unittest.TestCase):
    """tools/check_release.sh: a Pi package without the bundled extensions / processors is a package-level FAIL"""

    def run_release(self, name, pkg):
        with tempfile.TemporaryDirectory() as tmp:
            dist = os.path.join(tmp, "dist")
            os.mkdir(dist)
            with open(os.path.join(dist, name), "wb") as f:
                f.write(pkg)
            lock = os.path.join(tmp, "t.lock")
            with open(lock, "w") as f:
                f.write("[release]\nversion = v9.0.0\nchannel = prerelease\nsdk = 8\n\n[launcher]\ncommit = abcdef0\n")
            p = subprocess.run(["bash", os.path.join(ROOT, "tools", "check_release.sh"), lock, dist],
                               capture_output=True, text=True, timeout=120)
        return p.stdout + p.stderr

    def test_complete_package(self):
        out = self.run_release("autobleem-rpi-armhf-v9.0.0.tar.gz", package())
        self.assertIn("PASS rpi-pkg: package carries the bundled", out)

    def test_missing_folders(self):
        out = self.run_release("autobleem-rpi-armhf-v9.0.0.tar.gz",
                               package(drop=("extensions/store", "extensions/pscbios", "processors/unzip", "processors/pe")))
        self.assertIn("FAIL rpi-pkg: package lacks: extensions/store extensions/pscbios processors/unzip processors/pe", out)

    def test_arm64_needs_pe_too(self):
        out = self.run_release("autobleem-rpi-arm64-v9.0.0.tar.gz", package(drop=("processors/pe",)))
        self.assertIn("FAIL rpi64-pkg: package lacks: processors/pe", out)

    def test_pcusb_needs_pe_too(self):
        out = self.run_release("autobleem-pcusb-i386-v9.0.0.tar.gz", package(drop=("processors/pe",)))
        self.assertIn("package lacks: processors/pe", out)


LAUNCHER_SDK = os.path.join(ROOT, "tools", "launcher_sdk.sh")
CORE_SHA = "7761e82e" + "0" * 32
HEADER = """// how: AB_SDK_ABI (bumped by any change to the layout of a class)
// "layout changed - bump AB_SDK_ABI and update the table". Change a class: bump AB_SDK_ABI
#ifndef AB_SDK_ABI_H
#define AB_SDK_ABI 11
#define AB_SDK_STR(x) #x
"""
# a gh that answers the three contents calls launcher_sdk.sh makes and logs each path?ref
FAKE_GH = r"""#!/usr/bin/env bash
shift                                   # api
while [ "${1:-}" = -H ]; do shift 2; done
url="$1"; echo "$url" >> "$FAKE_GH_LOG"
case "$url" in
    repos/autobleem2/autobleem/contents/.gitmodules\?ref=*) cat "$FAKE_GH_DIR/gitmodules" ;;
    repos/autobleem2/autobleem/contents/autobleem-core\?ref=*) echo "$FAKE_GH_SHA" ;;
    repos/autobleem2/autobleem-core/contents/src/code/gui/extension.h\?ref="$FAKE_GH_SHA") cat "$FAKE_GH_DIR/extension.h" ;;
    *) exit 1 ;;
esac
"""


class LauncherSdk(unittest.TestCase):
    """tools/launcher_sdk.sh: the SDK number of a launcher build, from the autobleem-core pin's extension.h"""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = self._tmp.name
        self.addCleanup(self._tmp.cleanup)

    def header(self, text):
        path = os.path.join(self.tmp, "extension.h")
        with open(path, "w") as f:
            f.write(text)
        return path

    def run_script(self, *args, env=None):
        p = subprocess.run(["bash", LAUNCHER_SDK, *args], capture_output=True, text=True, timeout=60,
                           env=env or os.environ)
        return p.returncode, p.stdout, p.stderr

    def test_fake_extension_h_to_number(self):
        rc, out, err = self.run_script("--from-header", self.header(HEADER))
        self.assertEqual((rc, out, err), (0, "11\n", ""))

    def test_define_with_trailing_comment_and_spaces(self):
        rc, out, _ = self.run_script("--from-header", self.header("#  define   AB_SDK_ABI  42 // bumped\n"))
        self.assertEqual((rc, out), (0, "42\n"))

    def test_header_without_define(self):
        rc, out, err = self.run_script("--from-header", self.header("// AB_SDK_ABI 7 only in a comment\n#define OTHER 3\n"))
        self.assertEqual((rc, out), (1, ""))
        self.assertIn("no '#define AB_SDK_ABI", err)

    def test_resolves_through_the_pin(self):
        d = os.path.join(self.tmp, "fake")
        os.mkdir(d)
        with open(os.path.join(d, "gh"), "w") as f:
            f.write(FAKE_GH)
        os.chmod(os.path.join(d, "gh"), 0o755)
        with open(os.path.join(d, "gitmodules"), "w") as f:
            f.write('[submodule "autobleem-themes"]\n\tpath = autobleem-themes\n'
                    '[submodule "autobleem-core"]\n\tpath = autobleem-core\n\turl = x\n')
        with open(os.path.join(d, "extension.h"), "w") as f:
            f.write(HEADER)
        log = os.path.join(self.tmp, "gh.log")
        env = dict(os.environ, PATH=d + ":" + os.environ.get("PATH", ""), FAKE_GH_DIR=d, FAKE_GH_LOG=log,
                   FAKE_GH_SHA=CORE_SHA)
        rc, out, err = self.run_script("v2.0.0-alpha1-45-g7761e82", env=env)
        self.assertEqual((rc, out, err), (0, "11\n", ""))
        with open(log) as f:
            calls = f.read().split()
        # the describe is cut to the launcher commit, the core is read at the pinned sha
        self.assertEqual(calls, ["repos/autobleem2/autobleem/contents/.gitmodules?ref=7761e82",
                                 "repos/autobleem2/autobleem/contents/autobleem-core?ref=7761e82",
                                 "repos/autobleem2/autobleem-core/contents/src/code/gui/extension.h?ref=" + CORE_SHA])

    def test_unreachable_data_is_an_error(self):
        d = os.path.join(self.tmp, "fake")
        os.mkdir(d)
        with open(os.path.join(d, "gh"), "w") as f:
            f.write("#!/usr/bin/env bash\nexit 1\n")
        os.chmod(os.path.join(d, "gh"), 0o755)
        env = dict(os.environ, PATH=d + ":" + os.environ.get("PATH", ""))
        rc, out, err = self.run_script("v2.0.0", env=env)
        self.assertEqual((rc, out), (1, ""))
        self.assertIn("cannot read .gitmodules", err)


if __name__ == "__main__":
    unittest.main()
