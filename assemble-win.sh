#!/usr/bin/env bash
# assemble-win.sh VERSION - compose the Windows product from PUBLISHED component artifacts, no compilation -
# the same compile-once/assemble-many model as assemble.sh / assemble-psc.sh:
#
#   autobleem-win-product-<v>.zip   AutoBleem/: the program folder - the site's "win-product" kind, the
#                                   portable copy (dataroot.txt names the data folder)
#   AutoBleemSetup-<v>.exe          the NSIS installer over that folder - the "win-setup" kind, what a Windows
#                                   user downloads and what the launcher's own update (C3) runs with /S
#
# The pieces: the launcher's program folder + its NSIS script (autobleem2/autobleem, publish-launcher.yml's
# win target: AutoBleem/ with autobleem-gui.exe, resources, DLLs, Themes/, dataroot.txt.example, and nsis/),
# the two PS1 emulators' win64 packages (pcsx-ab -> emu/, pcsx-abnxt -> emunxt/ - Options -> "PS1 Emulator"
# picks, as on the console and the Pi) and AutoBleemWinSetup.exe, the setup helper that fills the data tree
# from the site (autobleem2/autobleem-pc-tools). The same program folder tools/make_win_package.sh --product
# stages in the launcher repo, sourced from releases instead of local builds. Needs makensis (apt: nsis).
#
#   VERSION: e.g. v2.0.0-alpha2
set -euo pipefail
VERSION="${1:?version}"
. "$(dirname "$0")/tools/release_assets.sh"

work="$(mktemp -d)"; STAGE="$work/stage"; mkdir -p "$STAGE"
dl="$work/dl"; mkdir -p "$dl"
APP="$STAGE/AutoBleem"

# 1. the launcher's program folder and the installer script
fetch_release_assets autobleem2/autobleem "$VERSION" "launcher-win64-*.tar.gz" "$dl"
tar -xzf "$dl"/launcher-win64-*.tar.gz -C "$STAGE"
for need in AutoBleem/autobleem-gui.exe AutoBleem/SDL2.dll AutoBleem/Themes nsis/autobleem.nsi; do
    [ -e "$STAGE/$need" ] || { echo "launcher-win64 lacks $need" >&2; exit 1; }
done
# VERSION next to the program: Env::productVersion() reads it, so its window and log show this release's
# version, written as everything else writes it (the owner's rule, 2026-09-23)
# (the launcher and AutoBleemWinSetup.exe both live in this folder; the NSIS script installs it with the rest)
printf '%s\n' "$VERSION" > "$APP/VERSION"

# 2. the two PS1 emulators: each win64 zip is one folder (pcsx-ab/ or pcsx-abnxt/) holding pcsx-ab.exe, its
#    DLLs, plugins/, skin/ (and lang/ for nxt) - moved in as emu/ and emunxt/
fetch_release_assets autobleem2/pcsx-ab    "$VERSION" "pcsx-ab-*-win64.zip"    "$dl"
fetch_release_assets autobleem2/pcsx-abnxt "$VERSION" "pcsx-abnxt-*-win64.zip" "$dl"
for pair in "pcsx-ab emu" "pcsx-abnxt emunxt"; do
    set -- $pair
    x="$work/x-$1"; mkdir -p "$x"
    unzip -q "$dl"/"$1"-*-win64.zip -d "$x"
    [ -f "$x/$1/pcsx-ab.exe" ] || { echo "$1's win64 package has no $1/pcsx-ab.exe" >&2; exit 1; }
    rm -rf "${APP:?}/$2"
    mv "$x/$1" "$APP/$2"
done

# 3. the setup helper (autobleem-pc-tools' pc-tools-win64 asset: AutoBleemWinSetup/AutoBleemWinSetup.exe,
#    Release, static, stripped, packed)
fetch_release_assets autobleem2/autobleem-pc-tools "$VERSION" "pc-tools-win64-*.zip" "$dl"
unzip -q "$dl"/pc-tools-win64-*.zip -d "$work/pc"
[ -s "$work/pc/AutoBleemWinSetup/AutoBleemWinSetup.exe" ] || { echo "pc-tools-win64 lacks AutoBleemWinSetup.exe" >&2; exit 1; }
cp "$work/pc/AutoBleemWinSetup/AutoBleemWinSetup.exe" "$APP/"

find "$APP" -type f -name placeholder -delete

# 4. the program folder as a zip, AutoBleem/ at its top (as make_win_package.sh --product has always made it)
out_zip="$PWD/autobleem-win-product-$VERSION.zip"; rm -f "$out_zip"
(cd "$STAGE" && zip -r -9 -q "$out_zip" AutoBleem)

# 5. the installer (the Linux makensis takes forward slashes in File specs - the script picks STAGE, not
#    STAGE_WIN, when it is not run on Windows)
makensis -V2 -DVERSION="$VERSION" -DSTAGE="$APP" -DOUT="$PWD/AutoBleemSetup-$VERSION.exe" \
    -DICON="$STAGE/nsis/autobleem.ico" "$STAGE/nsis/autobleem.nsi"

ls -l "autobleem-win-product-$VERSION.zip" "AutoBleemSetup-$VERSION.exe"
echo "program folder:"; find "$APP" -maxdepth 1 | sed "s#$STAGE/##" | sort
