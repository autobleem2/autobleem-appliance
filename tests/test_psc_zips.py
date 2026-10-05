#!/usr/bin/env python3
"""tools/psc_zips.py: the two PSC stick zips and their BIOS check. Run: python3 tests/test_psc_zips.py"""
import io
import os
import sys
import tarfile
import tempfile
import unittest
import zipfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
import psc_zips  # noqa: E402

VERSION = "v9.9.9-test"


def make_package(path, extra=()):
    with tarfile.open(path, "w:gz") as tar:
        def add(name, data=b"x", mode=0o644):
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = mode
            info.mtime = 1790000000
            tar.addfile(info, io.BytesIO(data))
        d = tarfile.TarInfo("./Games")
        d.type = tarfile.DIRTYPE
        d.mode = 0o755
        tar.addfile(d)
        add("./Autobleem/start.sh", b"#!/bin/sh\n", 0o755)
        add("./028c18a9-ec4b-4632-b2cf-d4e20f252e8f/LUPDATA.BIN")
        add("./Extensions/pscbios/extension.ini")
        add("./Apps/abflashkit/kernel/boot.img")
        add("./VERSION", (VERSION + "\n").encode())
        for name in extra:
            add(name)


def make_retroarch(path):
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("retroarch", b"ELF")
        z.writestr("VERSION", "v1.22.2-7\n")
        z.writestr("docs/building.md", "not installed")
        z.writestr("theme/Autobleem2.png", b"png")
        z.writestr("theme/ab2-1280x720.png", b"png")
        z.writestr("theme/assets/xmb/custom/font.ttf", b"ttf")
        z.writestr("theme/retroarch-psc.cfg", '# c\nxmb_theme = "7"\nvideo_driver = "gl"\n')
        z.writestr("theme/ab2-theme.cfg", 'xmb_theme = "6"\n')


def make_cores(path, extra=()):
    with tarfile.open(path, "w:gz") as tar:
        for name in ("cores/a_libretro.so", "info/a_libretro.info", "cores.json") + tuple(extra):
            info = tarfile.TarInfo(name)
            info.size = 1
            tar.addfile(info, io.BytesIO(b"x"))


def make_bundles(folder, extra=()):
    os.makedirs(folder, exist_ok=True)
    for name, _ in psc_zips.BUNDLES:
        with zipfile.ZipFile(os.path.join(folder, name + ".zip"), "w") as z:
            z.writestr("%s-file.txt" % name, "x")
            if name == "assets":
                z.writestr("xmb/custom/font.ttf", b"stock font")
                z.writestr("rgui/font/bitmap10x10_eng.bin", b"font")
            for e in extra:
                z.writestr(e, b"x")


def make_pack(path, files):
    with tarfile.open(path, "w:gz") as tar:
        for name in files:
            if name.endswith("@"):
                info = tarfile.TarInfo(name[:-1])
                info.type = tarfile.SYMTYPE
                info.linkname = "target"
                tar.addfile(info)
                continue
            info = tarfile.TarInfo(name)
            info.size = 1
            tar.addfile(info, io.BytesIO(b"x"))


class Args:
    pass


class PscZipsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        self.covers = os.path.join(self.dir, "covers")
        os.makedirs(self.covers)
        for name in psc_zips.COVERS:
            with open(os.path.join(self.covers, name), "wb") as f:
                f.write(b"\0" * 1000001)

    def tearDown(self):
        self.tmp.cleanup()

    def run_build(self, package_extra=(), cores_extra=(), biospack=None, bundle_extra=(), apps_extra=()):
        a = Args()
        a.package = os.path.join(self.dir, "p.tar.gz")
        a.retroarch_zip = os.path.join(self.dir, "ra.zip")
        a.cores_tar = os.path.join(self.dir, "c.tar.gz")
        a.libs_tar = os.path.join(self.dir, "l.tar.gz")
        a.apps_tar = os.path.join(self.dir, "a.tar.gz")
        a.bundles_dir = os.path.join(self.dir, "bundles")
        make_package(a.package, package_extra)
        make_retroarch(a.retroarch_zip)
        make_cores(a.cores_tar, cores_extra)
        make_bundles(a.bundles_dir, bundle_extra)
        make_pack(a.libs_tar, ("libs.json", "apps/libSDL2_image.so.0", "apps/libSDL2_image.so@", "modules/xpad.ko"))
        make_pack(a.apps_tar, ("apps.json", "Apps/doom/doom", "Apps/sdlpop/data/IBM_SND1/res10000.bin") + tuple(apps_extra))
        a.version, a.covers_dir, a.biospack = VERSION, self.covers, biospack
        a.out_dir = os.path.join(self.dir, "out")
        return psc_zips.build(a), a.out_dir

    def names(self, out, kind):
        with zipfile.ZipFile(os.path.join(out, "autobleem-psc-%s-%s.zip" % (VERSION, kind))) as z:
            return set(z.namelist())

    def test_the_two_zips_have_the_stick_layout(self):
        rc, out = self.run_build()
        self.assertEqual(rc, 0)
        base, full = self.names(out, "base"), self.names(out, "full")
        for n in ("Autobleem/start.sh", "VERSION", "Games/", "Autobleem/bin/db/coversJ.db", "Docs/README-zip.txt",
                  "028c18a9-ec4b-4632-b2cf-d4e20f252e8f/LUPDATA.BIN", "Extensions/pscbios/extension.ini"):
            self.assertIn(n, base)
            self.assertIn(n, full)
        self.assertFalse([n for n in base if n.startswith("RetroArch")])
        for n in ("RetroArch/bin/retroarch", "RetroArch/bin/VERSION", "RetroArch/bin/cores/a_libretro.so",
                  "RetroArch/bin/info/a_libretro.info", "RetroArch/bin/retroarch.cfg", "RetroArch/bios/README.txt",
                  "RetroArch/roms/", "RetroArch/bin/assets/xmb/custom/font.ttf"):
            self.assertIn(n, full)
        self.assertNotIn("RetroArch/bin/docs/building.md", full)

    def test_the_full_zip_has_what_the_installer_adds_to_retroarch(self):
        rc, out = self.run_build()
        self.assertEqual(rc, 0)
        full, base = self.names(out, "full"), self.names(out, "base")
        for n in ("RetroArch/bin/autoconfig/autoconfig-file.txt", "RetroArch/bin/database/rdb/database-rdb-file.txt",
                  "RetroArch/bin/database/cursors/database-cursors-file.txt", "RetroArch/bin/cheats/cheats-file.txt",
                  "RetroArch/bin/overlays/overlays-file.txt", "RetroArch/bin/shaders/shaders_glsl-file.txt",
                  "RetroArch/bin/assets/assets-file.txt", "RetroArch/bin/assets/rgui/font/bitmap10x10_eng.bin",
                  "Autobleem/lib/apps/libSDL2_image.so.0", "Autobleem/lib/modules/xpad.ko", "Apps/doom/doom",
                  "Apps/sdlpop/data/IBM_SND1/res10000.bin"):
            self.assertIn(n, full)
        self.assertFalse([n for n in full if n.endswith(("libs.json", "apps.json"))])
        self.assertNotIn("Autobleem/lib/apps/libSDL2_image.so", full)  # links are skipped, as the installer does
        self.assertFalse([n for n in base if n.startswith(("Apps/doom", "Autobleem/lib/apps"))])

    def test_the_theme_goes_over_the_stock_assets_and_keeps_the_stock_file_as_prab2(self):
        rc, out = self.run_build()
        with zipfile.ZipFile(os.path.join(out, "autobleem-psc-%s-full.zip" % VERSION)) as z:
            self.assertEqual(z.read("RetroArch/bin/assets/xmb/custom/font.ttf"), b"ttf")
            self.assertEqual(z.read("RetroArch/bin/assets/xmb/custom/font.ttf.prab2"), b"stock font")

    def test_a_bios_in_a_bundle_or_the_apps_pack_stops_the_build(self):
        self.assertEqual(self.run_build(bundle_extra=("system/scph1001.bin",))[0], 1)
        self.assertEqual(self.run_build(apps_extra=("Apps/amiberry/kickstarts/kick.rom",))[0], 1)
        self.assertEqual(self.run_build(apps_extra=("Apps/x/unknown.bin",))[0], 1)

    def test_retroarch_cfg_takes_the_builds_keys_last_one_wins(self):
        rc, out = self.run_build()
        with zipfile.ZipFile(os.path.join(out, "autobleem-psc-%s-full.zip" % VERSION)) as z:
            cfg = z.read("RetroArch/bin/retroarch.cfg").decode()
        self.assertIn('system_directory = "/media/RetroArch/bios"', cfg)
        self.assertIn('xmb_theme = "6"', cfg)
        self.assertNotIn('xmb_theme = "7"', cfg)
        self.assertEqual(cfg.count("xmb_theme"), 1)

    def test_a_bios_in_the_package_stops_the_build_and_leaves_no_zip(self):
        rc, out = self.run_build(package_extra=("./System/Bios/scph5501.bin",))
        self.assertEqual(rc, 1)
        self.assertEqual(os.listdir(out), [])

    def test_a_bios_among_the_cores_stops_the_build(self):
        rc, out = self.run_build(cores_extra=("info/dc_boot.bin",))
        self.assertEqual(rc, 1)

    def test_a_file_in_a_bios_folder_other_than_its_readme_is_refused(self):
        self.assertIsNotNone(psc_zips.bios_problem("RetroArch/bios/anything.dat"))
        self.assertIsNone(psc_zips.bios_problem("RetroArch/bios/README.txt"))

    def test_the_sticks_own_bin_files_and_the_pscbios_folder_pass(self):
        self.assertIsNone(psc_zips.bios_problem("028c18a9-ec4b-4632-b2cf-d4e20f252e8f/LUPDATA.BIN"))
        self.assertIsNone(psc_zips.bios_problem("Extensions/pscbios/bin/psc/pscbios.so"))
        self.assertIsNone(psc_zips.bios_problem("Apps/abflashkit/kernel/boot.img"))

    def test_known_bios_names_and_extensions_are_refused(self):
        for n in ("scph5501.bin", "SCPH1001.BIN", "psxonpsp660.bin", "bios.bin", "gba_bios.bin", "x/y/neogeo.zip",
                  "dc_flash.bin", "unknown_firmware.rom", "ps1_rom.bin", "romw.bin", "foo.BIOS", "other.bin"):
            self.assertIsNotNone(psc_zips.bios_problem("Autobleem/" + n), n)

    def test_the_bios_list_names_are_refused_but_not_its_config_files(self):
        names = {"somecore.dat", "config.ini"}
        self.assertIsNotNone(psc_zips.bios_problem("X/somecore.dat", names))
        self.assertIsNone(psc_zips.bios_problem("Autobleem/bin/autobleem/config.ini", names))

    def test_a_missing_or_stub_cover_database_stops_the_build(self):
        with open(os.path.join(self.covers, "coversJ.db"), "wb") as f:
            f.write(b"stub")
        with self.assertRaises(SystemExit):
            self.run_build()


if __name__ == "__main__":
    unittest.main()
