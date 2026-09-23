#!/usr/bin/env bash
# assemble.sh PLATFORM VERSION - compose a Linux appliance payload from PUBLISHED component artifacts, with
# NO compilation (the compile-once/assemble-many model, docs/repo-split-analysis.md). Because every
# component is tagged the same unified version, one VERSION selects them all.
#   PLATFORM: rpi-armhf | rpi-arm64 | pcusb        VERSION: e.g. v2.0.0-alpha1
set -euo pipefail
PLATFORM="${1:?platform}"; VERSION="${2:?version}"
case "$PLATFORM" in
  rpi-armhf) EMU=rpi-armhf; TOP=autobleem-rpi ;;
  rpi-arm64) EMU=rpi-arm64; TOP=autobleem-rpi ;;
  pcusb)     EMU=pcusb;     TOP=autobleem-pcusb ;;
  *) echo "platform: rpi-armhf|rpi-arm64|pcusb" >&2; exit 2 ;;
esac
work="$(mktemp -d)"; STAGE="$work/$TOP"; mkdir -p "$STAGE"
# 1. the appliance skeleton (install.sh, first-boot, system/, the data-partition tree) - from THIS repo
cp -a payload_linux/. "$STAGE/"
# 2. the emulators - PUBLISHED artifacts, fetched not built; pcsx-ab -> bin/emu, pcsx-abnxt -> bin/emunxt
dl="$work/dl"; mkdir -p "$dl"
gh release download "$VERSION" --repo autobleem2/pcsx-ab    --pattern "*-$EMU.tar.gz" --dir "$dl" --clobber
gh release download "$VERSION" --repo autobleem2/pcsx-abnxt --pattern "*-$EMU.tar.gz" --dir "$dl" --clobber
rm -rf "$STAGE/Autobleem/bin/emu" "$STAGE/Autobleem/bin/emunxt"
mkdir -p "$STAGE/Autobleem/bin/emu" "$STAGE/Autobleem/bin/emunxt"
tar -xzf "$dl"/pcsx-ab-*-"$EMU".tar.gz    -C "$STAGE/Autobleem/bin/emu"
tar -xzf "$dl"/pcsx-abnxt-*-"$EMU".tar.gz -C "$STAGE/Autobleem/bin/emunxt"
# 3. the launcher - PUBLISHED artifact (autobleem2/autobleem's publish-launcher.yml), fetched not built.
#    launcher-<platform>.tar.gz mirrors the payload the launcher repo contributes: Autobleem/bin/autobleem
#    (gui + resources), Autobleem/bin/abpad (the virtual-gamepad daemon + shim) and Themes/ (the five themes,
#    which stay in the launcher repo - no theme pack), so it extracts straight over the payload.
gh release download "$VERSION" --repo autobleem2/autobleem --pattern "launcher-$PLATFORM-*.tar.gz" --dir "$dl" --clobber
tar -xzf "$dl"/launcher-"$PLATFORM"-*.tar.gz -C "$STAGE"
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
