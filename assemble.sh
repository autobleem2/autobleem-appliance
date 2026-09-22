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
# 3. launcher(+resources), themes, cover DBs: the SAME pattern once those repos publish per-target artifacts:
#      gh release download $VERSION --repo autobleem2/autobleem        --pattern "*-$PLATFORM.tar.gz" ...
#      gh release download $VERSION --repo autobleem2/autobleem-themes --pattern "themes-$VERSION.tar.gz" ...
#      curl $AB_REPO_URL/db/coversU.db ...
echo "[assemble] launcher/themes/cover-DBs: fetched here once published (same mechanism)" >&2
# 4. the deliverable
out="autobleem-$PLATFORM-$VERSION.tar.gz"
tar -czf "$out" -C "$work" "$TOP"
echo "==> $out ($(du -h "$out" | cut -f1)); staged tree:"
find "$STAGE/Autobleem/bin" -maxdepth 2 -type d | sed "s#$STAGE/##"
