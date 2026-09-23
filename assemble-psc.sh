#!/usr/bin/env bash
# assemble-psc.sh VERSION - compose the PlayStation Classic package (autobleem-psc-<v>.tar.gz, the "psc-fs"
# release kind in autobleem-repo's tools/repo_index.py) from PUBLISHED component artifacts, no compilation -
# the same compile-once/assemble-many model as assemble.sh for the Linux appliances. Mirrors the launcher
# repo's tools/make_psc_package.sh tarball branch exactly (see that script's own comment for the full
# rationale), just sourcing every piece from a release artifact instead of a local build directory.
#
# This tarball is deliberately NOT self-contained: no RetroArch/ and no cover databases
# (Autobleem/bin/db/), same as make_psc_package.sh's tarball branch - AutoBleemInstaller.exe
# (autobleem2/autobleem's apps/installer, which runs on a PC WITH network, unlike the console) fetches those
# from the download site at install time: RetroArch itself, its cores, the
# Autobleem/lib/{apps,retroarch,modules} pack, the third-party Apps pack, the BIOS files
# (psc/bios/biospack.txt) and the cover databases (db/). None of that belongs in this script.
#
# BIOS in particular needs no fetch at all for PS1 on the console: the console's own copy
# (Autobleem/rc/backup.sh, part of the psc skeleton below, copies /gaadata/system/bios/romw.bin ->
# System/Bios at every boot - the console's stock firmware BIOS) is what pcsx-ab reads. The
# RetroArch/bios/biospack.txt manifest this repo's skeleton carries is only for RetroArch's OTHER systems
# (Saturn, Dreamcast, PC-FX, ...), which AutoBleemInstaller.exe fetches on request, same as everything else
# in the paragraph above - never bundled here.
#
#   VERSION: e.g. v2.0.0-alpha1
set -euo pipefail
VERSION="${1:?version}"
. "$(dirname "$0")/tools/release_assets.sh"

work="$(mktemp -d)"; STAGE="$work/autobleem-psc"; mkdir -p "$STAGE"
dl="$work/dl"; mkdir -p "$dl"

# 1. the psc skeleton + launcher (autobleem2/autobleem's publish-launcher.yml, psc target): the exploit dir,
#    Autobleem/{rc,start.sh,lib/libs.tar.gz}, Docs/, Games/, Themes/, Autobleem/bin/autobleem
#    (gui+absplash+abfatflag+resources+internal.db) and Autobleem/bin/abpad. NOT RetroArch/, NOT Apps/ -
#    see the header comment.
fetch_release_assets autobleem2/autobleem "$VERSION" "launcher-psc-*.tar.gz" "$dl"
tar -xzf "$dl"/launcher-psc-*.tar.gz -C "$STAGE"
for need in 028c18a9-ec4b-4632-b2cf-d4e20f252e8f/LUPDATA.BIN Autobleem/start.sh Autobleem/rc/boot.sh \
            Autobleem/lib/libs.tar.gz Autobleem/bin/autobleem/autobleem-gui; do
    [ -e "$STAGE/$need" ] || { echo "launcher-psc lacks $need - an artifact from before the psc skeleton?" >&2; exit 1; }
done

# 2. the console tools (autobleem2/autobleem-console-tools): the tarball's root is Apps/ - pscbios and
#    abflashkit, abflashkit with its kernel/ flash payload
fetch_release_assets autobleem2/autobleem-console-tools "$VERSION" "console-tools-psc-*.tar.gz" "$dl"
tar -xzf "$dl"/console-tools-psc-*.tar.gz -C "$STAGE"
[ -s "$STAGE/Apps/abflashkit/kernel/boot.img" ] || { echo "console-tools-psc lacks Apps/abflashkit/kernel/boot.img" >&2; exit 1; }

# 3. the two PS1 emulators - PUBLISHED artifacts, fetched not built; pcsx-ab -> bin/emu, pcsx-abnxt -> bin/emunxt
fetch_release_assets autobleem2/pcsx-ab    "$VERSION" "pcsx-ab-*-psc.tar.gz"    "$dl"
fetch_release_assets autobleem2/pcsx-abnxt "$VERSION" "pcsx-abnxt-*-psc.tar.gz" "$dl"
rm -rf "$STAGE/Autobleem/bin/emu" "$STAGE/Autobleem/bin/emunxt"
mkdir -p "$STAGE/Autobleem/bin/emu" "$STAGE/Autobleem/bin/emunxt"
tar -xzf "$dl"/pcsx-ab-*-psc.tar.gz    -C "$STAGE/Autobleem/bin/emu"
tar -xzf "$dl"/pcsx-abnxt-*-psc.tar.gz -C "$STAGE/Autobleem/bin/emunxt"

# 4. VERSION file (tools/make_psc_package.sh's / tools/make_rpi_package.sh's rule: the tag as given - this
#    assembler only ever runs against a real published version, so no dirty/hash fallback is needed here).
printf '%s\n' "$VERSION" > "$STAGE/VERSION"

find "$STAGE" -type f -name placeholder -delete

# executable bits: none of the three tarballs above are guaranteed to have kept them (Windows-hosted repo
# splits have already lost this bit more than once this session - see assemble.sh's own history)
chmod +x "$STAGE/Autobleem/bin/autobleem/autobleem-gui" "$STAGE/Autobleem/bin/autobleem/absplash" \
         "$STAGE/Autobleem/bin/autobleem/abfatflag" 2>/dev/null || true
chmod +x "$STAGE"/Autobleem/*.sh "$STAGE"/Autobleem/rc/*.sh 2>/dev/null || true
chmod +x "$STAGE"/Apps/*/*.sh "$STAGE"/Apps/pscbios/pscbios "$STAGE"/Apps/abflashkit/abflashkit 2>/dev/null || true
chmod +x "$STAGE"/Autobleem/bin/abpad/abpadd 2>/dev/null || true
chmod +x "$STAGE"/Autobleem/bin/emu/pcsx-ab "$STAGE"/Autobleem/bin/emunxt/pcsx-ab 2>/dev/null || true

# rooted at the stick's root, no top-level folder (unlike the Linux tarballs): AutoBleemInstaller.exe
# extracts it straight onto the stick and recognises it by Autobleem/bin/autobleem/autobleem-gui, Themes/
# and VERSION at the top - make_psc_package.sh's tarball has always been made this way
out="autobleem-psc-$VERSION.tar.gz"
tar -czf "$out" --owner=0 --group=0 -C "$STAGE" .
echo "==> $out ($(du -h "$out" | cut -f1)); staged tree:"
find "$STAGE" -maxdepth 2 -type d | sed "s#$STAGE/##"
