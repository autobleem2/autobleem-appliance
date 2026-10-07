#!/usr/bin/env python3
"""tools/psc_bundle.py: the installer download's payload folder, its manifest and its BIOS check.
Run: python3 tests/test_psc_bundle.py"""
import hashlib
import http.server
import io
import json
import os
import sys
import tarfile
import tempfile
import threading
import time
import unittest
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "tools"))
sys.path.insert(0, HERE)
import psc_bundle  # noqa: E402
import psc_zips  # noqa: E402
import test_psc_zips as helpers  # noqa: E402

VERSION = helpers.VERSION
NOTICES = ("./Autobleem/bin/autobleem/LICENSE", "./Autobleem/bin/autobleem/THIRD_PARTY_NOTICES.md")


def sha(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


class Args:
    pass


class PscBundleTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        self.site_dir = os.path.join(self.dir, "site")
        os.makedirs(self.site_dir)
        handler = lambda *a, **k: Quiet(*a, directory=self.site_dir, **k)  # noqa: E731
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]
        self.sleep = time.sleep
        time.sleep = lambda s: None  # a failing fetch's retries wait 2 s each
        self.updateroms = os.path.join(self.dir, "UpdateRoms")
        os.makedirs(self.updateroms)
        with open(os.path.join(self.updateroms, "UpdateRoms.exe"), "wb") as f:
            f.write(b"MZ")

    def tearDown(self):
        time.sleep = self.sleep
        self.server.shutdown()
        self.server.server_close()
        self.tmp.cleanup()

    def put(self, rel, data=None):
        path = os.path.join(self.site_dir, *rel.split("/"))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if data is not None:
            with open(path, "wb") as f:
                f.write(data)
        return path

    def catalog(self, kind, name, flat=True, bad_sha=False):
        path = self.put("%s/%s" % (kind, name))
        node = {"name": name, "size": os.path.getsize(path), "sha256": sha(path) if not bad_sha else "0" * 64,
                "url": "%s/%s/%s" % (self.url, kind, name)}
        doc = node if flat else {"version": "v1.22.2-7", "zip": node}
        self.put("%s/latest.json" % kind, json.dumps(doc).encode())

    def make_site(self, cores_extra=(), bundle_extra=(), apps_extra=(), bad_sha_for=None):
        helpers.make_retroarch(self.put("psc/retroarch/retroarch-psc-v1.22.2-7.zip"))
        self.catalog("psc/retroarch", "retroarch-psc-v1.22.2-7.zip", flat=False, bad_sha=bad_sha_for == "retroarch")
        cores = self.put("psc/cores/cores-psc-20261003.tar.gz")
        with tarfile.open(cores, "w:gz") as tar:
            for name, body in (("cores/a_libretro.so", b"x"), ("cores.json", b"{}"),
                               ("info/a_libretro.info", b'display_name = "A core"\nlicense = "GPLv2"\nauthors = "Me"\n'),
                               ("info/b_libretro.info", b'display_name = "B core"\n')) + tuple((e, b"x") for e in cores_extra):
                info = tarfile.TarInfo(name)
                info.size = len(body)
                tar.addfile(info, io.BytesIO(body))
        self.catalog("psc/cores", "cores-psc-20261003.tar.gz", bad_sha=bad_sha_for == "cores")
        helpers.make_pack(self.put("psc/libs/libs-psc-20260920.tar.gz"),
                          ("libs.json", "apps/libSDL2_image.so.0", "modules/xpad.ko"))
        self.catalog("psc/libs", "libs-psc-20260920.tar.gz")
        helpers.make_pack(self.put("psc/apps/apps-psc-20260920.tar.gz"),
                          ("apps.json", "Apps/doom/doom", "Apps/sdlpop/data/IBM_SND1/res10000.bin") + tuple(apps_extra))
        self.catalog("psc/apps", "apps-psc-20260920.tar.gz")
        self.put("samples/samples-20260920.tar.gz", b"samples")
        self.catalog("samples", "samples-20260920.tar.gz")
        for name in psc_zips.COVERS:
            data = b"sqlite " + name.encode()
            self.put("db/" + name, data)
            self.put("db/%s.sha256" % name, ("%s  %s\n" % (hashlib.sha256(data).hexdigest(), name)).encode())
        helpers.make_bundles(os.path.join(self.site_dir, "assets", "frontend"), bundle_extra)
        self.package = os.path.join(self.dir, "autobleem-psc-%s.tar.gz" % VERSION)
        helpers.make_package(self.package, NOTICES)

    def run_build(self, **kw):
        a = Args()
        a.package, a.version, a.site = self.package, VERSION, self.url
        a.buildbot_url, a.updateroms_dir = self.url + "/assets/frontend", self.updateroms
        a.biospack, a.work_dir = kw.get("biospack"), self.dir
        a.out_dir = os.path.join(self.dir, "stage")
        return psc_bundle.build(a), a.out_dir

    def test_the_payload_is_the_site_laid_out_with_a_manifest_that_matches(self):
        self.make_site()
        rc, out = self.run_build()
        self.assertEqual(rc, 0)
        payload = os.path.join(out, "payload")
        with open(os.path.join(payload, "bundle.json"), encoding="utf-8") as f:
            manifest = json.load(f)
        self.assertEqual(manifest["format"], 1)
        self.assertEqual(manifest["version"], VERSION)
        self.assertEqual(manifest["package"], "autobleem-psc-%s.tar.gz" % VERSION)
        by_path = {f["path"]: f for f in manifest["files"]}
        for rel in ("psc/retroarch/latest.json", "psc/retroarch/retroarch-psc-v1.22.2-7.zip",
                    "psc/cores/latest.json", "psc/cores/cores-psc-20261003.tar.gz", "psc/libs/latest.json",
                    "psc/libs/libs-psc-20260920.tar.gz", "psc/apps/latest.json", "samples/latest.json",
                    "db/coversJ.db", "db/coversJ.db.sha256", "db/coversP.db", "assets/frontend/assets.zip",
                    "assets/frontend/shaders_glsl.zip", "autobleem-psc-%s.tar.gz" % VERSION):
            self.assertIn(rel, by_path, rel)
        for rel, f in by_path.items():
            path = os.path.join(payload, *rel.split("/"))
            self.assertEqual(f["size"], os.path.getsize(path), rel)
            self.assertEqual(f["sha256"], sha(path), rel)
        # the catalogs are the site's own bytes, so the installer reads exactly what it would have fetched
        with open(os.path.join(payload, "psc", "cores", "latest.json"), "rb") as f, \
                open(os.path.join(self.site_dir, "psc", "cores", "latest.json"), "rb") as g:
            self.assertEqual(f.read(), g.read())
        self.assertTrue(os.path.isfile(os.path.join(payload, "UpdateRoms", "UpdateRoms.exe")))
        with open(os.path.join(out, "VERSION")) as f:
            self.assertEqual(f.read(), VERSION + "\n")

    def test_the_notices_and_the_cores_licences_travel_with_it(self):
        self.make_site()
        rc, out = self.run_build()
        self.assertEqual(rc, 0)
        for name in ("LICENSE", "THIRD_PARTY_NOTICES.md", "SOURCE-OFFER.txt", "CORES-LICENSES.txt", "README.txt"):
            self.assertTrue(os.path.isfile(os.path.join(out, name)), name)
        with open(os.path.join(out, "CORES-LICENSES.txt"), encoding="utf-8") as f:
            text = f.read()
        self.assertIn("a_libretro", text)
        self.assertIn("GPLv2", text)
        self.assertIn("(not stated)", text)  # b_libretro.info names no licence
        with open(os.path.join(out, "README.txt"), encoding="utf-8", newline="") as f:
            self.assertIn("\r\n", f.read())

    def test_a_bios_file_in_any_pack_stops_the_build_and_leaves_nothing(self):
        for where, kw in (("cores", dict(cores_extra=("system/scph5501.bin",))),
                          ("apps", dict(apps_extra=("Apps/x/bios.bin",))),
                          ("bundle", dict(bundle_extra=("neogeo.zip",)))):
            with self.subTest(where):
                self.make_site(**kw)
                rc, out = self.run_build()
                self.assertEqual(rc, 1)
                self.assertFalse(os.path.exists(out))

    def test_a_bios_name_from_the_sites_list_stops_it_too(self):
        self.make_site(cores_extra=("system/oddcore.dat",))
        with open(os.path.join(self.dir, "biospack.txt"), "w") as f:
            f.write("# list\n%s 1 http://x/oddcore.dat oddcore.dat\n" % ("a" * 64))
        rc, _ = self.run_build(biospack=os.path.join(self.dir, "biospack.txt"))
        self.assertEqual(rc, 1)

    def test_the_sticks_own_bin_files_inside_the_bundle_zips_pass_by_their_stick_path(self):
        # assets.zip's rgui/font/*.bin is RetroArch/bin/assets/rgui/font/*.bin on the stick: the allow-list names
        # it by that path; the same .bin anywhere else is refused
        self.make_site()
        rc, out = self.run_build()
        self.assertEqual(rc, 0)
        self.assertEqual(psc_bundle.stick_prefix("payload/assets/x"), "")
        self.assertEqual(psc_bundle.stick_prefix("assets/frontend/database-rdb.zip"), "RetroArch/bin/database/rdb/")
        self.assertEqual(psc_bundle.stick_prefix("psc/cores/cores-psc-1.tar.gz"), "RetroArch/bin/")
        self.make_site(bundle_extra=("rgui/other.bin",))
        # the extra member sits in every bundle zip, e.g. database-rdb.zip: its stick path is not on the allow-list
        rc, _ = self.run_build()
        self.assertEqual(rc, 1)

    def test_a_pack_that_does_not_match_its_catalog_stops_the_build(self):
        self.make_site(bad_sha_for="cores")
        with self.assertRaises(SystemExit):
            self.run_build()

    def test_check_reads_a_built_zip_through_its_archives(self):
        self.make_site()
        rc, out = self.run_build()
        self.assertEqual(rc, 0)
        zpath = os.path.join(self.dir, "full.zip")
        with zipfile.ZipFile(zpath, "w", zipfile.ZIP_STORED) as z:
            for base, _d, files in os.walk(out):
                for n in files:
                    p = os.path.join(base, n)
                    z.write(p, "AutoBleemInstaller/" + os.path.relpath(p, out).replace(os.sep, "/"))
        self.assertEqual(psc_bundle.zip_problems(zpath), [])
        self.assertEqual(psc_bundle.bundle_problems(os.path.join(out, "payload")), [])
        # a BIOS file inside an archive inside the zip is found
        with zipfile.ZipFile(zpath, "a") as z:
            inner = io.BytesIO()
            with tarfile.open(fileobj=inner, mode="w:gz") as tar:
                info = tarfile.TarInfo("system/scph5501.bin")
                info.size = 1
                tar.addfile(info, io.BytesIO(b"x"))
            z.writestr("AutoBleemInstaller/payload/psc/cores/other.tar.gz", inner.getvalue())
        bad = psc_bundle.zip_problems(zpath)
        self.assertEqual(len(bad), 1)
        self.assertIn("scph5501.bin", bad[0][0])

    def test_zip_folder_stores_the_packs_and_deflates_the_rest(self):
        top = os.path.join(self.dir, "AutoBleemInstaller")
        os.makedirs(os.path.join(top, "payload"))
        for rel, data in (("payload/pack.tar.gz", b"x" * 5000), ("payload/bundle.json", b"{}" * 5000),
                          ("AutoBleemInstaller.exe", b"MZ" * 5000)):
            with open(os.path.join(top, *rel.split("/")), "wb") as f:
                f.write(data)
        out = os.path.join(self.dir, "full.zip")
        psc_bundle.zip_folder(self.dir, "AutoBleemInstaller", out)
        with zipfile.ZipFile(out) as z:
            kinds = {i.filename: i.compress_type for i in z.infolist()}
            self.assertEqual(kinds["AutoBleemInstaller/payload/pack.tar.gz"], zipfile.ZIP_STORED)
            self.assertEqual(kinds["AutoBleemInstaller/payload/bundle.json"], zipfile.ZIP_DEFLATED)
            self.assertEqual(kinds["AutoBleemInstaller/AutoBleemInstaller.exe"], zipfile.ZIP_DEFLATED)
            self.assertIsNone(z.testzip())


if __name__ == "__main__":
    unittest.main()
