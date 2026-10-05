#!/usr/bin/env python3
"""The PlayStation Classic release as two zips to unzip onto a stick (PLATFORM-21), neither with a BIOS file.

    autobleem-psc-<version>-base.zip   the stick's file system (autobleem-psc-<version>.tar.gz) plus the cover
                                       databases - no RetroArch/
    autobleem-psc-<version>-full.zip   the same plus RetroArch/ : the console's RetroArch, its cores, retroarch.cfg
                                       and the empty folders it keeps its files in

The folder layout is the one AutoBleemInstaller.exe lays down for "RetroArch" ticked (autobleem-core's
installer_job.cpp: RetroArch/bin/{retroarch,VERSION,cores,info,"Retroarch themes",fonts,assets,...},
RetroArch/bios, RetroArch/roms) - the libretro asset bundles, the apps pack and the runtime libraries are what the
installer adds on top. The zips are written from the package and the site's packs directly, member by member.

No BIOS file goes in, and the build fails when one does: check_zip() reads the finished zip back and refuses a
known BIOS name, any .bin/.rom/.bios member that is not on the short allow-list of the stick's own files, any
file under a bios folder but its README, and (--biospack) any file whose name the BIOS list of the download site
(psc/bios/biospack.txt) names. The PlayStation BIOS itself needs no file: the console copies its own at boot.

    python3 tools/psc_zips.py --package autobleem-psc-V.tar.gz --version V --site https://autobleem.retromenele.pl
    python3 tools/psc_zips.py --package autobleem-psc-V.tar.gz --version V --covers-dir DIR \\
        --retroarch-zip retroarch-psc-TAG.zip --cores-tar cores-psc-DATE.tar.gz [--biospack FILE] [--out-dir DIR]
    python3 tools/psc_zips.py --check autobleem-psc-V-base.zip autobleem-psc-V-full.zip [--biospack FILE]

Only the standard library is needed.
"""

import argparse
import fnmatch
import hashlib
import json
import os
import posixpath
import shutil
import sys
import tarfile
import tempfile
import time
import urllib.request
import zipfile

COVERS = ("coversJ.db", "coversP.db", "coversU.db")
COVERS_DEST = "Autobleem/bin/db"

# the empty folders RetroArch keeps its files in (what the installer creates under RetroArch/bin)
RA_BIN_DIRS = ("Retroarch themes", "fonts", "playlists", "saves", "savestates", "screenshots", "config", "logs",
               "thumbnails", "downloads", "records", "cores", "info")

# the RetroArch zip's files and where they go under RetroArch/bin (installer_job.cpp, theme/README.md)
RA_PLACES = (
    ("retroarch", "retroarch"),
    ("VERSION", "VERSION"),
    ("theme/Autobleem2.png", "Retroarch themes/Autobleem2.png"),
    ("theme/ab2-1280x720.png", "Retroarch themes/ab2-1280x720.png"),
    ("theme/selawik-light.ttf", "fonts/selawik-light.ttf"),
    ("theme/OFL.txt", "fonts/OFL.txt"),
)
RA_ASSETS_FROM = "theme/assets/"
# the keys of retroarch.cfg: the installer's own (writeRetroArchCfg), then the build's, the theme's, the save states'
RA_CFG_HEAD = (
    "# Written for the AutoBleem stick zip, as AutoBleem's installer writes it. RetroArch keeps this file up to date\n"
    "# itself; AutoBleem edits a few display keys around each launch. Every directory lives under RetroArch/bin\n"
    "# (\":/\" is this file's folder), the BIOS files under RetroArch/bios, the games under RetroArch/roms.\n")
RA_CFG_BASE = (
    ("libretro_directory", ":/cores"), ("libretro_info_path", ":/info"),
    ("system_directory", "/media/RetroArch/bios"), ("rgui_browser_directory", "/media/RetroArch/roms/"),
    ("core_assets_directory", ":/downloads"), ("savefile_directory", ":/saves"),
    ("savestate_directory", ":/savestates"), ("playlist_directory", ":/playlists"),
    ("content_database_path", ":/database/rdb"), ("cursor_directory", ":/database/cursors"),
    ("cheat_database_path", ":/cheats"), ("assets_directory", ":/assets"),
    ("joypad_autoconfig_dir", ":/autoconfig"), ("overlay_directory", ":/overlays"),
    ("video_shader_dir", ":/shaders"), ("thumbnails_directory", ":/thumbnails"),
    ("screenshot_directory", ":/screenshots"), ("recording_output_directory", ":/records"),
    ("recording_config_directory", ":/records"), ("rgui_config_directory", ":/config"),
    ("core_options_path", ":/config/retroarch-core-options.cfg"), ("global_core_options", "true"),
    ("log_dir", ":/logs"), ("cache_directory", "/tmp/ra_cache"), ("video_fullscreen", "true"),
    ("input_autodetect_enable", "true"), ("menu_show_core_updater", "false"),
)
RA_CFG_FROM_ZIP = ("theme/retroarch-psc.cfg", "theme/ab2-theme.cfg", "theme/ab2-states.cfg")

ZIP_README = """AutoBleem 2 for the PlayStation Classic - the stick as a zip
=============================================================

Unzip this onto an empty USB stick (FAT32, or exFAT with the AutoBleem kernel) so that Autobleem/, Themes/ and
the other folders are at the top of the stick, then put the stick into the console's second controller port.

There are two zips of every release:
  base   AutoBleem without RetroArch (smaller).
  full   AutoBleem with RetroArch and its cores (RetroArch/ on the stick).
AutoBleemInstaller.exe (a separate download) does the same on a PC and can add RetroArch to a base stick later.

No BIOS files are in either zip. The PlayStation games need none: the console copies its own BIOS at every boot.
RetroArch's other systems need the BIOS files of their own consoles - put your own into RetroArch/bios/
(see the README.txt there).
"""

BIOS_README = """RetroArch's system directory (retroarch.cfg: system_directory = "/media/RetroArch/bios").

The BIOS files the RetroArch cores look for go here, laid out as the core expects them (for example scph5501.bin
at the top, dc/ for Dreamcast, PPSSPP/ for PSP). They are not part of AutoBleem and not in this zip: use the
files of your own consoles.

PlayStation games played by AutoBleem's own emulators need no file here - the console's BIOS is copied at boot.
AutoBleemInstaller.exe can fetch the BIOS list for the cores from the public RetroBIOS collection if you want it
to ("BIOS files", needs RetroArch ticked).
"""

# ---- the BIOS check ---------------------------------------------------------------------------------------

# a known BIOS / firmware name, matched on the lower-cased file name (never on a folder name: the stick has a
# folder called pscbios, the PSC-Bios extension, which is no BIOS file)
BIOS_NAME_PATTERNS = (
    "scph*", "psxonpsp*", "ps1_rom*", "romw.bin", "psx*.bin", "bios*", "*_bios.*", "*-bios.*", "*bios*.bin",
    "*bios*.rom", "*bios*.zip", "*.bios", "sega_101*", "mpr-*", "saturn*.bin", "dc_boot*", "dc_flash*",
    "kick*.rom", "neogeo.zip", "pgm.zip", "qsound.zip", "syscard*", "panafz*", "goldstar*", "disksys.rom",
    "fdsbios*", "firmware*.bin", "lynxboot*", "pcfx.rom", "scsi.rom", "carta.rom", "stv*.zip", "cd32*.rom",
    "cdtv*.rom", "bioscd*",
)
# a file of these extensions is a BIOS unless it is one of the stick's own, listed here (lower case, full path)
BIOS_EXTENSIONS = (".bin", ".rom", ".bios")
OWN_FILES = (
    "028c18a9-ec4b-4632-b2cf-d4e20f252e8f/lupdata.bin",  # the console's update trigger, not a BIOS
)
BIOS_README_NAME = "readme.txt"
# the BIOS list also names plain text and config files some cores keep next to their BIOS (config.ini, ...): a
# file of these kinds is never taken for a BIOS by name alone
SAFE_EXTENSIONS = (".ini", ".txt", ".cfg", ".json", ".xml", ".md", ".png", ".jpg", ".ttf", ".ogg", ".wav", ".sh")
# the BIOS list also names plain text and config files some cores keep next to their BIOS (config.ini, ...): a
# file of these kinds is never taken for a BIOS by name alone
SAFE_EXTENSIONS = (".ini", ".txt", ".cfg", ".json", ".xml", ".md", ".png", ".jpg", ".ttf", ".ogg", ".wav", ".sh")


def load_biospack_names(path):
    """The file names (lower case) the BIOS list names: lines `<sha256> <size> <url> <path under system/>`."""
    names = set()
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            parts = line.rstrip("\n").split(" ", 3)
            if len(parts) == 4:
                names.add(posixpath.basename(parts[3]).lower())
    return names


def bios_problem(member, biospack_names=()):
    """Why a zip member counts as a BIOS file, or None."""
    low = member.lower()
    if low.endswith("/"):
        return None
    base = posixpath.basename(low)
    parts = low.split("/")
    if "bios" in parts[:-1] and base != BIOS_README_NAME:
        return "a file in a bios folder (only its README may be there)"
    if low in OWN_FILES:
        return None
    for pat in BIOS_NAME_PATTERNS:
        if fnmatch.fnmatchcase(base, pat):
            return "matches the BIOS name pattern %s" % pat
    if base.endswith(BIOS_EXTENSIONS):
        return "a %s file that is not one of the stick's own" % posixpath.splitext(base)[1]
    if base in biospack_names and not base.endswith(SAFE_EXTENSIONS):
        return "named in the BIOS list (psc/bios/biospack.txt)"
    return None


def check_zip(path, biospack_names=()):
    """Every member of the zip at `path` that is a BIOS file: [(member, why)]."""
    bad = []
    with zipfile.ZipFile(path) as z:
        for name in z.namelist():
            why = bios_problem(name, biospack_names)
            if why:
                bad.append((name, why))
    return bad


# ---- writing the zips -------------------------------------------------------------------------------------

def zinfo(name, mode, mtime=None, is_dir=False):
    t = time.localtime(mtime if mtime and mtime > 315532800 else time.time())[:6]
    info = zipfile.ZipInfo(name + ("/" if is_dir and not name.endswith("/") else ""), date_time=t)
    info.create_system = 3
    info.external_attr = ((0o40755 if is_dir else (0o100000 | mode)) << 16) | (0x10 if is_dir else 0)
    info.compress_type = zipfile.ZIP_STORED if is_dir else zipfile.ZIP_DEFLATED
    return info


class Writer:
    def __init__(self, path):
        self.path = path
        self.zip = zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True)
        self.names = set()
        self.files = 0

    def add_dir(self, name):
        name = name.strip("/")
        if not name or name + "/" in self.names:
            return
        parent = posixpath.dirname(name)
        if parent:
            self.add_dir(parent)
        self.names.add(name + "/")
        self.zip.writestr(zinfo(name, 0o755, is_dir=True), b"")

    def add_bytes(self, name, data, mode=0o644, mtime=None):
        self.add_dir(posixpath.dirname(name))
        if name in self.names:
            raise SystemExit("psc_zips: %s would be in the zip twice" % name)
        self.names.add(name)
        self.zip.writestr(zinfo(name, mode, mtime), data)
        self.files += 1

    def add_stream(self, name, src, mode, mtime):
        self.add_dir(posixpath.dirname(name))
        if name in self.names:
            raise SystemExit("psc_zips: %s would be in the zip twice" % name)
        self.names.add(name)
        with self.zip.open(zinfo(name, mode, mtime), "w", force_zip64=True) as dst:
            while True:
                chunk = src.read(1 << 20)
                if not chunk:
                    break
                dst.write(chunk)
        self.files += 1

    def add_file(self, name, path, mode=None):
        st = os.stat(path)
        with open(path, "rb") as src:
            self.add_stream(name, src, mode if mode is not None else (st.st_mode & 0o777) | 0o644, st.st_mtime)

    def close(self):
        self.zip.close()


def add_package(w, package):
    """Every member of the stick's file system tarball, at the zip's root."""
    with tarfile.open(package, "r:gz") as tar:
        for m in tar:
            name = posixpath.normpath(m.name)
            if name == ".":
                continue
            if m.isdir():
                w.add_dir(name)
            elif m.isreg():
                w.add_stream(name, tar.extractfile(m), (m.mode & 0o777) | 0o644 | (m.mode & 0o111), m.mtime)
            else:
                raise SystemExit("psc_zips: %s in the package is neither a file nor a folder" % m.name)


def add_covers(w, covers_dir):
    for name in COVERS:
        path = os.path.join(covers_dir, name)
        if not os.path.isfile(path) or os.path.getsize(path) < 1000000:
            raise SystemExit("psc_zips: %s is missing or a stub in %s" % (name, covers_dir))
        w.add_file("%s/%s" % (COVERS_DEST, name), path, 0o644)


def cfg_keys(text):
    """The `key = value` lines of a cfg, comments out: [(key, line)]."""
    out = []
    for line in text.splitlines():
        t = line.strip()
        if t and not t.startswith("#") and "=" in t:
            out.append((t.split("=", 1)[0].strip(), t))
    return out


def add_retroarch(w, retroarch_zip, cores_tar):
    bin_dir = "RetroArch/bin"
    for d in ("RetroArch/bios", "RetroArch/roms", bin_dir) + tuple("%s/%s" % (bin_dir, x) for x in RA_BIN_DIRS):
        w.add_dir(d)
    w.add_bytes("RetroArch/bios/README.txt", BIOS_README.replace("\n", "\r\n").encode("utf-8"))
    lines = {}
    for k, v in RA_CFG_BASE:
        lines[k] = '%s = "%s"' % (k, v)
    with zipfile.ZipFile(retroarch_zip) as z:
        names = set(z.namelist())
        for src, dst in RA_PLACES:
            if src not in names:
                if src in ("retroarch", "VERSION"):
                    raise SystemExit("psc_zips: %s lacks %s" % (os.path.basename(retroarch_zip), src))
                continue
            info = z.getinfo(src)
            with z.open(info) as f:
                w.add_stream("%s/%s" % (bin_dir, dst), f, 0o755 if src == "retroarch" else 0o644,
                             time.mktime(info.date_time + (0, 0, -1)))
        for n in sorted(names):
            if n.startswith(RA_ASSETS_FROM) and not n.endswith("/"):
                info = z.getinfo(n)
                with z.open(info) as f:
                    w.add_stream("%s/assets/%s" % (bin_dir, n[len(RA_ASSETS_FROM):]), f, 0o644,
                                 time.mktime(info.date_time + (0, 0, -1)))
        for cfg in RA_CFG_FROM_ZIP:
            if cfg in names:
                for k, line in cfg_keys(z.read(cfg).decode("utf-8")):
                    lines[k] = line
    w.add_bytes("%s/retroarch.cfg" % bin_dir, (RA_CFG_HEAD + "\n".join(lines.values()) + "\n").encode("utf-8"))
    n = 0
    with tarfile.open(cores_tar, "r:gz") as tar:
        for m in tar:
            name = posixpath.normpath(m.name)
            if m.isdir():
                continue
            if not m.isreg():
                raise SystemExit("psc_zips: %s in the cores pack is neither a file nor a folder" % m.name)
            w.add_stream("%s/%s" % (bin_dir, name), tar.extractfile(m), 0o755 if name.startswith("cores/") else 0o644,
                         m.mtime)
            n += name.startswith("cores/")
    if n == 0:
        raise SystemExit("psc_zips: no core in %s" % os.path.basename(cores_tar))
    return n


def fetch(url, dest, sha256=None, tries=3):
    """Download url to dest (through a .part file), checking the SHA-256 when it is known."""
    last = None
    for attempt in range(tries):
        try:
            h = hashlib.sha256()
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "autobleem-appliance"}),
                                        timeout=120) as r, open(dest + ".part", "wb") as f:
                while True:
                    chunk = r.read(1 << 20)
                    if not chunk:
                        break
                    h.update(chunk)
                    f.write(chunk)
            if sha256 and h.hexdigest() != sha256.lower():
                raise ValueError("SHA-256 %s, expected %s" % (h.hexdigest(), sha256))
            os.replace(dest + ".part", dest)
            return
        except (OSError, ValueError) as e:
            last = e
            time.sleep(2 * (attempt + 1))
    if os.path.exists(dest + ".part"):
        os.remove(dest + ".part")
    raise SystemExit("psc_zips: cannot fetch %s: %s" % (url, last))


def fetch_json(url):
    tmp = tempfile.NamedTemporaryFile(delete=False)
    tmp.close()
    try:
        fetch(url, tmp.name)
        with open(tmp.name, encoding="utf-8") as f:
            return json.load(f)
    finally:
        os.remove(tmp.name)


def fetch_packs(site, work, args):
    """The site's packs a zip is made of: the console's RetroArch and cores (their latest.json name the file and its
    SHA-256), the cover databases (a .sha256 sidecar each) and the BIOS list for the check (best effort)."""
    site = site.rstrip("/")
    if not args.retroarch_zip:
        ra = fetch_json(site + "/psc/retroarch/latest.json")["zip"]
        args.retroarch_zip = os.path.join(work, ra["name"])
        print("    %s" % ra["name"])
        fetch(ra["url"], args.retroarch_zip, ra.get("sha256"))
    if not args.cores_tar:
        cores = fetch_json(site + "/psc/cores/latest.json")
        args.cores_tar = os.path.join(work, cores["name"])
        print("    %s (%s cores)" % (cores["name"], cores.get("count", "?")))
        fetch(cores["url"], args.cores_tar, cores.get("sha256"))
    if not args.covers_dir:
        args.covers_dir = os.path.join(work, "covers")
        os.makedirs(args.covers_dir, exist_ok=True)
        for name in COVERS:
            side = os.path.join(args.covers_dir, name + ".sha256")
            fetch(site + "/db/" + name + ".sha256", side)
            with open(side, encoding="utf-8") as f:
                want = f.read().split()[0]
            print("    %s" % name)
            fetch(site + "/db/" + name, os.path.join(args.covers_dir, name), want)
    if not args.biospack:
        path = os.path.join(work, "biospack.txt")
        try:
            fetch(site + "/psc/bios/biospack.txt", path, tries=2)
            args.biospack = path
        except SystemExit as e:
            print("    (no BIOS list for the name check - the built-in patterns still apply: %s)" % e)


def build(args):
    names =load_biospack_names(args.biospack) if args.biospack else set()
    os.makedirs(args.out_dir, exist_ok=True)
    out = {}
    for kind in ("base", "full"):
        path = os.path.join(args.out_dir, "autobleem-psc-%s-%s.zip" % (args.version, kind))
        out[kind] = path
        w = Writer(path)
        try:
            add_package(w, args.package)
            add_covers(w, args.covers_dir)
            w.add_bytes("Docs/README-zip.txt", ZIP_README.replace("\n", "\r\n").encode("utf-8"))
            cores = add_retroarch(w, args.retroarch_zip, args.cores_tar) if kind == "full" else 0
        finally:
            w.close()
        print("%s: %d files%s, %.1f MB" % (os.path.basename(path), w.files, ", %d cores" % cores if cores else "",
                                         os.path.getsize(path) / 1048576))
    for kind, path in out.items():
        bad = check_zip(path, names)
        if kind == "base" and any(n.startswith("RetroArch/") for n in zipfile.ZipFile(path).namelist()):
            bad.append(("RetroArch/", "the base zip must not carry RetroArch"))
        if bad:
            report(path, bad)
            for p in out.values():
                os.remove(p)
            return 1
    return 0


def report(path, bad):
    print("psc_zips: %s carries %d BIOS file(s) - the build stops:" % (os.path.basename(path), len(bad)),
          file=sys.stderr)
    for name, why in bad[:50]:
        print("    %s  (%s)" % (name, why), file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--package", help="autobleem-psc-<version>.tar.gz, the stick's file system")
    ap.add_argument("--version")
    ap.add_argument("--covers-dir", help="folder with coversJ.db, coversP.db, coversU.db")
    ap.add_argument("--retroarch-zip", help="retroarch-psc-<tag>.zip from the site's psc/retroarch/")
    ap.add_argument("--cores-tar", help="cores-psc-<date>.tar.gz from the site's psc/cores/")
    ap.add_argument("--biospack", help="psc/bios/biospack.txt: also refuse every file name it lists")
    ap.add_argument("--site", help="the download site: fetch whatever of the packs above is not given from it")
    ap.add_argument("--work-dir", help="where --site downloads go (default: the system's temporary folder)")
    ap.add_argument("--out-dir", default=".")
    ap.add_argument("--check", nargs="+", metavar="ZIP", help="only check these zips for BIOS files")
    args = ap.parse_args()
    if args.check:
        names = load_biospack_names(args.biospack) if args.biospack else set()
        rc = 0
        for path in args.check:
            bad = check_zip(path, names)
            if bad:
                report(path, bad)
                rc = 1
            else:
                print("%s: no BIOS file" % os.path.basename(path))
        return rc
    for need in ("package", "version"):
        if not getattr(args, need):
            ap.error("--%s is required" % need)
    if args.site:
        work = tempfile.mkdtemp(prefix="psc_zips-", dir=args.work_dir)
        try:
            fetch_packs(args.site, work, args)
            return build(args)
        finally:
            shutil.rmtree(work, ignore_errors=True)
    for need in ("covers_dir", "retroarch_zip", "cores_tar"):
        if not getattr(args, need):
            ap.error("--%s is required (or --site)" % need.replace("_", "-"))
    return build(args)


if __name__ == "__main__":
    sys.exit(main())
