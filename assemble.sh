#!/usr/bin/env bash
# assemble.sh PLATFORM VERSION - compose a Linux appliance payload from PUBLISHED component artifacts, with
# NO compilation (the compile-once/assemble-many model, docs/repo-split-analysis.md). Because every
# component is tagged the same unified version, one VERSION selects them all.
#   PLATFORM: rpi-armhf | rpi-arm64 | pcusb        VERSION: e.g. v2.0.0-alpha1
set -euo pipefail
PLATFORM="${1:?platform}"; VERSION="${2:?version}"
. "$(dirname "$0")/tools/release_assets.sh"
case "$PLATFORM" in
  rpi-armhf) EMU=rpi-armhf; TOP=autobleem-rpi;   KEYS="rpi linux-armhf" ;;
  rpi-arm64) EMU=rpi-arm64; TOP=autobleem-rpi;   KEYS="rpi64 linux-arm64" ;;
  pcusb)     EMU=pcusb;     TOP=autobleem-pcusb; KEYS="pcusb linux-i386" ;;
  *) echo "platform: rpi-armhf|rpi-arm64|pcusb" >&2; exit 2 ;;
esac
work="$(mktemp -d)"; STAGE="$work/$TOP"; mkdir -p "$STAGE"
# 1. the appliance skeleton (install.sh, first-boot, system/, the data-partition tree) - from THIS repo
cp -a payload_linux/. "$STAGE/"
# 2. the emulators - PUBLISHED artifacts, fetched not built; pcsx-ab -> bin/emu, pcsx-abnxt -> bin/emunxt
dl="$work/dl"; mkdir -p "$dl"
fetch_release_assets autobleem2/pcsx-ab    "$VERSION" "pcsx-ab-*-$EMU.tar.gz"    "$dl"
fetch_release_assets autobleem2/pcsx-abnxt "$VERSION" "pcsx-abnxt-*-$EMU.tar.gz" "$dl"
# the skeleton's checked-in emulator folders (emu*, emunxt*, one per architecture - make_rpi_package.sh's
# staging picked one) all go: the device reads bin/emu and bin/emunxt only, filled from the release below
rm -rf "$STAGE"/Autobleem/bin/emu "$STAGE"/Autobleem/bin/emu-* "$STAGE"/Autobleem/bin/emunxt "$STAGE"/Autobleem/bin/emunxt-*
mkdir -p "$STAGE/Autobleem/bin/emu" "$STAGE/Autobleem/bin/emunxt"
tar -xzf "$dl"/pcsx-ab-*-"$EMU".tar.gz    -C "$STAGE/Autobleem/bin/emu"
tar -xzf "$dl"/pcsx-abnxt-*-"$EMU".tar.gz -C "$STAGE/Autobleem/bin/emunxt"
# 3. the launcher - PUBLISHED artifact (autobleem2/autobleem's publish-launcher.yml), fetched not built.
#    launcher-<platform>.tar.gz mirrors the payload the launcher repo contributes: Autobleem/bin/autobleem
#    (gui + resources), Autobleem/bin/abpad (the virtual-gamepad daemon + shim) and Themes/ (the five themes,
#    which stay in the launcher repo - no theme pack), so it extracts straight over the payload.
fetch_release_assets autobleem2/autobleem "$VERSION" "launcher-$PLATFORM-*.tar.gz" "$dl"
tar -xzf "$dl"/launcher-"$PLATFORM"-*.tar.gz -C "$STAGE"
# the bundled scanner processors - install.sh copies processors/<name>/ into System/Processors/ (not
# System/ in the package: payload_linux already has system/, and a case-insensitive filesystem cannot hold both)
# shellcheck disable=SC2086 - KEYS is a list on purpose
stage_processor autobleem2/proc_unzip unzip "$STAGE/processors" $KEYS
# the package's version: install.sh puts it on the data partition, where the launcher's update check reads
# it (Env::productVersion), and the image builders name the image after it
printf '%s\n' "$VERSION" > "$STAGE/VERSION"
# 4. cover DBs and sample games are NOT bundled - install.sh fetches them from the download repository at
#    install / first boot (a Pi/PC-stick install has the network). The site side (autobleem-repo db/,
#    autobleem-samples) is a separate publish, not part of the appliance payload.
# 5. the deliverable. pcusb keeps the established "-i386" naming (tools/make_rpi_package.sh's own
#    convention, predating this assembler) - the site's repo_index.py matches releases/ files by a regex
#    that requires it literally (^autobleem-pcusb-i386.*\.tar\.gz$), unlike rpi/rpi64 which match any
#    suffix; a plain autobleem-pcusb-<version>.tar.gz silently fails to be picked up as the pcusb release
#    (found live on the site, 2026-09-23 - the auto-updater kept pointing at a stale pre-migration file).
case "$PLATFORM" in
  pcusb) out="autobleem-pcusb-i386-$VERSION.tar.gz" ;;
  *)     out="autobleem-$PLATFORM-$VERSION.tar.gz" ;;
esac
tar -czf "$out" -C "$work" "$TOP"
echo "==> $out ($(du -h "$out" | cut -f1)); staged tree:"
find "$STAGE/Autobleem/bin" -maxdepth 2 -type d | sed "s#$STAGE/##"

# 6. the PC stick's Windows flasher (autobleem2/autobleem-pc-tools' AutoBleemFlasher/, from its pc-tools-win64
#    asset): AutoBleemFlasher-<v>.zip = AutoBleemFlasher/{AutoBleemFlasher.exe,README.txt}, the site's
#    "flasher" kind, published with this release so the PC stick panel offers it next to the image. It
#    downloads the image of the channel picked in it, so nothing else rides in the zip.
if [ "$PLATFORM" = pcusb ]; then
  fetch_release_assets autobleem2/autobleem-pc-tools "$VERSION" "pc-tools-win64-*.zip" "$dl"
  win="$work/win"; mkdir -p "$win"
  unzip -q "$dl"/pc-tools-win64-*.zip 'AutoBleemFlasher/*' -d "$win"
  [ -s "$win/AutoBleemFlasher/AutoBleemFlasher.exe" ] || { echo "pc-tools-win64 lacks AutoBleemFlasher/AutoBleemFlasher.exe" >&2; exit 1; }
  # VERSION next to the program: Env::productVersion() reads it, so its window and log show this release's
  # version, written as everything else writes it (the owner's rule, 2026-09-23)
  printf '%s\n' "$VERSION" > "$win/AutoBleemFlasher/VERSION"
  zip_out="$PWD/AutoBleemFlasher-$VERSION.zip"; rm -f "$zip_out"
  (cd "$win" && zip -r -9 -q "$zip_out" AutoBleemFlasher)
  ls -l "$zip_out"
fi
