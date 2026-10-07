#!/usr/bin/env python3
"""The PlayStation Classic installer download that carries its own payload (PLATFORM-23): the folder AutoBleemInstaller
-<version>-full.zip is made of, minus the programs - no BIOS file in it, ever.

AutoBleemInstaller.exe (autobleem-pc-tools) installs from a `payload/` folder next to it when there is one: the
catalogs, packs and libretro bundles it would fetch from the download site are served from that folder (autobleem-core's
LocalBundle), each file checked once against payload/bundle.json (path, size, sha256), and unpacked straight from the
file. Only the BIOS files still come over the net, from the pinned RetroBIOS source (psc/bios, tools/biospack.py).

    python3 tools/psc_bundle.py --package autobleem-psc-V.tar.gz --version V --site https://autobleem.retromenele.pl \\
        --out-dir stage [--updateroms-dir UpdateRoms] [--work-dir DIR]
    python3 tools/psc_bundle.py --check AutoBleemInstaller-V-full.zip|payload-dir [--biospack FILE]

The out dir gets:

    payload/bundle.json                     the manifest (format 1: version, package, files by site path)
    payload/<site path>                     what the site serves under that path: psc/retroarch/latest.json and its zip,
                                            psc/cores|libs|apps/latest.json and their tarballs, samples/..., db/covers*.db
                                            (+ .sha256), assets/frontend/<name>.zip (libretro's bundles), the package
    payload/UpdateRoms/                     the PC scanner, the installer puts it on the stick (when --updateroms-dir)
    README.txt, VERSION, LICENSE, THIRD_PARTY_NOTICES.md, SOURCE-OFFER.txt, CORES-LICENSES.txt

The layout is the one psc_zips.py reads from the same site (the stick zips are the packs unpacked and merged; this is
the packs themselves, so the installer keeps its update rules - config.ini, the user's files, RetroArch kept when current).
The BIOS check is psc_zips's: a known BIOS name, a .bin/.rom/.bios that is not the stick's own, any file in a bios
folder, a name the site's BIOS list has - looked for in every member of every archive in the folder, and the build fails.
Only the standard library is needed.
"""

import argparse
import hashlib
import io
import json
import os
import posixpath
import shutil
import sys
import tarfile
import tempfile
import urllib.parse
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import psc_zips  # noqa: E402

FORMAT = 1
BUILDBOT_URL = psc_zips.BUILDBOT_URL
COVERS = psc_zips.COVERS
BUNDLES = [name for name, _ in psc_zips.BUNDLES]
# catalogs of the site's own packs: <site>/<rel>/latest.json, either {name,url,sha256} or {zip:{...}} (retroarch)
KINDS = ("psc/retroarch", "psc/cores", "psc/libs", "psc/apps", "samples")

README = """AutoBleem 2 - the installer for the PlayStation Classic, with everything in the download
==========================================================================================

This download carries AutoBleem itself, RetroArch with its cores, the libraries and apps, libretro's asset bundles
and the cover databases in the folder payload\\ next to AutoBleemInstaller.exe. Unzip the WHOLE zip into one folder,
then run AutoBleemInstaller.exe. It installs from that folder: nothing else is downloaded, apart from the BIOS files
if you ask for them (the window says "This download" instead of a channel).

  1. Plug a USB stick into the PC. Pick it in the stick box (only removable drives are offered).
     The console needs a FAT32 stick (exFAT works with the AutoBleem kernel) - "Format..." makes one,
     erasing everything on it. Windows formats FAT32 up to 32 GB; for a bigger stick put fat32format.exe
     (Ridgecrop's free tool) next to this program, or use exFAT.
  2. Choose: the cover databases (Japan, USA, PAL), RetroArch for the other systems' games, the BIOS files those
     cores need (about 300 MB, fetched from the public RetroBIOS collection - they are not part of this download),
     the sample games.
  3. Install. The first thing it does is check every file of payload\\ against payload\\bundle.json once, so a zip
     that was cut short or damaged is reported before anything is written to the stick. Then put the stick into
     the console's second controller port and boot it.

PlayStation games need no BIOS file from you: the console copies its own at every boot. The BIOS files are only for
the other systems' cores.

Run it again over a stick that has AutoBleem to update it: the launcher, the scripts, the themes and the console
tools are replaced; your games, save states, memory cards, settings, RetroArch's saves and playlists, and anything
else on the stick stay as they are.

For scripts: AutoBleemInstaller.exe --quiet --drive F: [--covers JUP] [--retroarch] [--bios [--ps1-bios-only]]
             [--samples] [--online | --channel release|testing|nightly]
             --online (or --channel) ignores payload\\ and downloads from https://autobleem.retromenele.pl as the
             small installer does.

Licences: LICENSE, THIRD_PARTY_NOTICES.md (AutoBleem and what it contains), CORES-LICENSES.txt (each RetroArch core's
licence, from its info file) and SOURCE-OFFER.txt (where the source code is) are in this folder.

If the console no longer starts at all - and Sony's recovery (the stick with LBOOT.EPB, the power cord
pulled and put back) does not bring it back - LastResortRecovery\\LastResortRecovery.exe in this folder
writes the console's own backup back to it over USB. Its README.txt says what it takes.
"""

SOURCE_OFFER = """Source code of what is in this download
=======================================

AutoBleem and its tools are free software under the GNU General Public License (see LICENSE). The complete source
code of AutoBleem - the launcher, the installer, the console tools, the emulators and the build scripts - is public
at https://github.com/autobleem2 (each program in its own repository; the version this download was made from is
named in VERSION). RetroArch and the cores in payload\\psc\\cores are libretro's: their source code is at
https://github.com/libretro (a core's repository is named after it, see CORES-LICENSES.txt); the console's own build
of RetroArch is in https://github.com/autobleem2/retroarch-psc.

Anyone who received this download may ask for the source code of any GPL-licensed part of it, for three years from the
day they received it, at the address on https://autobleem.retromenele.pl (the site's Support page). The BIOS files
are no part of this download and are not distributed by AutoBleem; the installer fetches them from the public
RetroBIOS collection when asked.
"""


def urlpath(url):
    return urllib.parse.unquote(urllib.parse.urlparse(url).path).lstrip("/")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            chunk = f.read(1 << 20)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def put(out, rel, url, sha256=None):
    """The site's file at `url` under payload/<rel>; returns the bytes' path."""
    dest = os.path.join(out, *rel.split("/"))
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    psc_zips.fetch(url, dest, sha256)
    return dest


def pack_info(doc):
    """(url, sha256) of the file a catalog names: {name,url,sha256} or {zip: {...}}."""
    node = doc["zip"] if isinstance(doc.get("zip"), dict) else doc
    return node["url"], node.get("sha256")


def fetch_payload(site, buildbot_url, out, kinds=KINDS):
    """Every file the installer asks the site and libretro for with RetroArch, the covers and the samples chosen, laid
    under `out` at the path of its URL. Returns the site-relative paths of what was written."""
    site = site.rstrip("/")
    written = []
    for kind in kinds:
        cat = put(out, kind + "/latest.json", "%s/%s/latest.json" % (site, kind))
        written.append(kind + "/latest.json")
        with open(cat, encoding="utf-8") as f:
            url, sha = pack_info(json.load(f))
        rel = urlpath(url)
        print("    %s" % rel)
        put(out, rel, url, sha)
        written.append(rel)
    for name in COVERS:
        side = put(out, "db/%s.sha256" % name, "%s/db/%s.sha256" % (site, name))
        with open(side, encoding="utf-8") as f:
            want = f.read().split()[0]
        print("    db/%s" % name)
        put(out, "db/" + name, "%s/db/%s" % (site, name), want)
        written += ["db/%s.sha256" % name, "db/" + name]
    for name in BUNDLES:
        url = "%s/%s.zip" % (buildbot_url.rstrip("/"), name)
        rel = urlpath(url)
        print("    %s (libretro)" % rel)
        dest = put(out, rel, url)
        if not zipfile.is_zipfile(dest):
            raise SystemExit("psc_bundle: %s is not a zip" % url)
        written.append(rel)
    return written


# ---- the BIOS check -----------------------------------------------------------------------------------------

def archive_members(path):
    """The member names of a zip or tar(.gz) at `path`, [] for anything else."""
    try:
        if zipfile.is_zipfile(path):
            with zipfile.ZipFile(path) as z:
                return z.namelist()
        if path.endswith((".tar", ".tar.gz", ".tgz")):
            with tarfile.open(path, "r:*") as tar:
                return [m.name for m in tar if not m.isdir()]
    except (tarfile.TarError, zipfile.BadZipFile, OSError):
        pass
    return []


def stick_prefix(rel):
    """Where an archive's members land on the stick, so the BIOS check sees their names as the stick has them (the
    allow-list of the stick's own .bin files is by stick path): payload-relative path of the archive in, prefix out."""
    rel = rel.split("payload/", 1)[-1]
    for name, dest in psc_zips.BUNDLES:
        if rel == "assets/frontend/%s.zip" % name:
            return "RetroArch/bin/%s/" % dest
    for folder, prefix in (("psc/cores/", "RetroArch/bin/"), ("psc/retroarch/", "RetroArch/bin/"),
                           ("psc/libs/", "Autobleem/lib/")):
        if rel.startswith(folder):
            return prefix
    return ""


def member_problems(rel, members, biospack_names):
    bad = []
    prefix = stick_prefix(rel)
    for member in members:
        why = psc_zips.bios_problem(posixpath.normpath(prefix + member), biospack_names)
        if why:
            bad.append(("%s: %s" % (rel, member), why))
    return bad


def bundle_problems(folder, biospack_names=()):
    """Every BIOS-looking file in the folder, itself and inside each archive: [(where, why)]."""
    bad = []
    for base, _dirs, files in os.walk(folder):
        for name in sorted(files):
            path = os.path.join(base, name)
            rel = os.path.relpath(path, folder).replace(os.sep, "/")
            why = psc_zips.bios_problem(rel, biospack_names)
            if why:
                bad.append((rel, why))
            bad += member_problems(rel, archive_members(path), biospack_names)
    return bad


def zip_problems(path, biospack_names=()):
    """The same for a built bundle zip: its members and the archives inside it (read through, never unpacked to disk)."""
    bad = []
    with zipfile.ZipFile(path) as z:
        for info in z.infolist():
            if info.is_dir():
                continue
            why = psc_zips.bios_problem(info.filename, biospack_names)
            if why:
                bad.append((info.filename, why))
            members = []
            try:
                if info.filename.endswith((".tar.gz", ".tgz", ".tar")):
                    with z.open(info) as raw, tarfile.open(fileobj=raw, mode="r|*") as tar:
                        members = [m.name for m in tar if not m.isdir()]
                elif info.filename.endswith(".zip"):
                    with z.open(info) as raw:
                        members = zipfile.ZipFile(raw).namelist()
            except (tarfile.TarError, zipfile.BadZipFile, OSError):
                members = []
            bad += member_problems(info.filename, members, biospack_names)
    return bad


# ---- the rest of the folder ---------------------------------------------------------------------------------

def cores_licenses(cores_tar):
    """CORES-LICENSES.txt from the info files of the cores pack: one line per core - name, licence, authors."""
    rows = []
    with tarfile.open(cores_tar, "r:gz") as tar:
        for m in tar:
            if not (m.isreg() and m.name.startswith("info/") and m.name.endswith(".info")):
                continue
            info = {}
            for line in tar.extractfile(m).read().decode("utf-8", "replace").splitlines():
                if "=" in line and not line.lstrip().startswith("#"):
                    k, v = line.split("=", 1)
                    info[k.strip()] = v.strip().strip('"')
            core = posixpath.basename(m.name)[:-len(".info")]
            rows.append((core, info.get("display_name", ""), info.get("license", "(not stated)"),
                         info.get("authors", "")))
    rows.sort()
    out = ["Cores in payload/psc/cores - licence as the core's own info file states it (libretro)", "",
           "%-34s %-34s %s" % ("core", "licence", "authors")]
    out += ["%-34s %-34s %s" % (c, lic, authors) for c, _name, lic, authors in rows]
    return "\n".join(out) + "\n"


def notices_from_package(package, out):
    """LICENSE and THIRD_PARTY_NOTICES.md as the stick package carries them (next to the launcher)."""
    found = {}
    with tarfile.open(package, "r:gz") as tar:
        for m in tar:
            base = posixpath.basename(m.name)
            if m.isreg() and base in ("LICENSE", "THIRD_PARTY_NOTICES.md") and base not in found:
                found[base] = tar.extractfile(m).read()
    for need in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
        if need not in found:
            raise SystemExit("psc_bundle: %s has no %s - the notices travel with the launcher" % (package, need))
        with open(os.path.join(out, need), "wb") as f:
            f.write(found[need])


def write_manifest(out, version, package_rel, rels):
    files = []
    for rel in rels:
        path = os.path.join(out, "payload", *rel.split("/"))
        files.append({"path": rel, "size": os.path.getsize(path), "sha256": sha256_file(path)})
    manifest = {"format": FORMAT, "version": version, "package": package_rel, "files": files}
    with open(os.path.join(out, "payload", "bundle.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    return manifest


def build(args):
    out = args.out_dir
    payload = os.path.join(out, "payload")
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(payload)
    work = tempfile.mkdtemp(prefix="psc_bundle-", dir=args.work_dir)
    try:
        written = fetch_payload(args.site, args.buildbot_url, payload)
        package_rel = os.path.basename(args.package)
        shutil.copyfile(args.package, os.path.join(payload, package_rel))
        written.append(package_rel)
        if args.updateroms_dir:
            shutil.copytree(args.updateroms_dir, os.path.join(payload, "UpdateRoms"))
        names = set()
        if args.biospack:
            names = psc_zips.load_biospack_names(args.biospack)
        else:
            try:
                path = os.path.join(work, "biospack.txt")
                psc_zips.fetch(args.site.rstrip("/") + "/psc/bios/biospack.txt", path, tries=2)
                names = psc_zips.load_biospack_names(path)
            except SystemExit as e:
                print("    (no BIOS list for the name check - the built-in patterns still apply: %s)" % e)
        bad = bundle_problems(payload, names)
        if bad:
            report(out, bad)
            shutil.rmtree(out, ignore_errors=True)
            return 1
        cores = [w for w in written if w.startswith("psc/cores/") and w.endswith(".tar.gz")]
        write_manifest(out, args.version, package_rel, written)
        notices_from_package(args.package, out)
        with open(os.path.join(out, "README.txt"), "w", encoding="utf-8", newline="") as f:
            f.write(README.replace("\n", "\r\n"))
        with open(os.path.join(out, "SOURCE-OFFER.txt"), "w", encoding="utf-8", newline="") as f:
            f.write(SOURCE_OFFER.replace("\n", "\r\n"))
        with open(os.path.join(out, "CORES-LICENSES.txt"), "w", encoding="utf-8", newline="") as f:
            f.write(cores_licenses(os.path.join(payload, *cores[0].split("/"))))
        with open(os.path.join(out, "VERSION"), "w", encoding="utf-8", newline="") as f:
            f.write(args.version + "\n")
    finally:
        shutil.rmtree(work, ignore_errors=True)
    total = sum(os.path.getsize(os.path.join(b, n)) for b, _d, fs in os.walk(payload) for n in fs)
    print("%s: %d files, %.1f MB, no BIOS file" % (payload, len(written), total / 1048576))
    return 0


# already-compressed files are stored: deflating a 300 MB .tar.gz twice costs minutes and saves nothing
STORED = (".gz", ".zip", ".png", ".jpg", ".xz", ".7z")


def zip_folder(parent, top, out):
    """parent/top as top/... in the zip at `out` (zip64 where needed), the big packs stored, the rest deflated."""
    if os.path.exists(out):
        os.remove(out)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, allowZip64=True) as z:
        for base, _dirs, files in os.walk(os.path.join(parent, top)):
            for name in sorted(files):
                path = os.path.join(base, name)
                kind = zipfile.ZIP_STORED if name.lower().endswith(STORED) else zipfile.ZIP_DEFLATED
                z.write(path, os.path.relpath(path, parent).replace(os.sep, "/"), compress_type=kind)


def report(where, bad):
    print("psc_bundle: %s carries %d BIOS file(s) - the build stops:" % (where, len(bad)), file=sys.stderr)
    for name, why in bad[:50]:
        print("    %s  (%s)" % (name, why), file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--package", help="autobleem-psc-<version>.tar.gz, the stick's file system")
    ap.add_argument("--version")
    ap.add_argument("--site", help="the download site the packs are fetched from")
    ap.add_argument("--buildbot-url", default=BUILDBOT_URL, help="where libretro's bundles come from")
    ap.add_argument("--updateroms-dir", help="the UpdateRoms folder (UpdateRoms.exe, README.txt) to carry")
    ap.add_argument("--biospack", help="psc/bios/biospack.txt: also refuse every file name it lists")
    ap.add_argument("--work-dir")
    ap.add_argument("--out-dir", default="bundle-stage")
    ap.add_argument("--check", metavar="ZIP_OR_DIR", help="only check a built bundle zip or a payload folder for BIOS files")
    ap.add_argument("--zip-folder", nargs=3, metavar=("PARENT", "TOP", "OUT"),
                    help="only zip PARENT/TOP as TOP/... into OUT (the big packs stored, not deflated twice)")
    args = ap.parse_args()
    if args.zip_folder:
        zip_folder(*args.zip_folder)
        return 0
    if args.check:
        names = psc_zips.load_biospack_names(args.biospack) if args.biospack else set()
        bad = zip_problems(args.check, names) if os.path.isfile(args.check) else bundle_problems(args.check, names)
        if bad:
            report(args.check, bad)
            return 1
        print("%s: no BIOS file" % os.path.basename(args.check.rstrip("/\\")))
        return 0
    for need in ("package", "version", "site"):
        if not getattr(args, need):
            ap.error("--%s is required" % need)
    return build(args)


if __name__ == "__main__":
    sys.exit(main())
