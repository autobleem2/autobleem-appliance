#!/usr/bin/env bash
#
# SDK-11: payload_linux/install.sh's install_payload() - what the Pi / PC-stick install and update (--update, the
# online update's autobleem-update.sh) do to the scanner processors.
#
#   - a FRESH install writes no System/Processors/sequence.ini: the launcher stores every processor it finds
#     off, the bundled Unzip included;
#   - a reinstall / update replaces the BUNDLED processor's files and never removes a processor the user
#     installed, nor System/Processors/sequence.ini (their order and on/off), nor Home/processors/<name>/ (the
#     data folder a processor keeps for itself, AB_HOME).
#
# The function is extracted verbatim from install.sh (as test_pkg_first_available.sh does), with `run` as a plain
# command runner and the cover-database step stubbed out.
#
# Run: tests/rc/test_update_keeps_processors.sh [path-to-install.sh]
# Exit 0 = both hold. Exit 1 = a processor or its settings were removed, or a fresh install wrote sequence.ini.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${1:-$SCRIPT_DIR/../../payload_linux/install.sh}"
PAYLOAD_DIR="$(cd "$(dirname "$INSTALL_SH")" && pwd)"

if [ ! -f "$INSTALL_SH" ]; then
    echo "FAIL: $INSTALL_SH not found"
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FUNC_FILE="$WORK/install_payload.sh"
awk '/^install_payload\(\) \{/{p=1} p{print; if (/^\}/) exit}' "$INSTALL_SH" > "$FUNC_FILE"
if [ ! -s "$FUNC_FILE" ] || ! grep -q '^install_payload() {' "$FUNC_FILE"; then
    echo "FAIL: could not extract install_payload() from $INSTALL_SH"
    exit 1
fi

# the package: the launcher, the scripts, the bundled Unzip (version given), a VERSION
make_stage() {
    local stage="$1" version="$2"
    mkdir -p "$stage/Autobleem/bin/autobleem" "$stage/Autobleem/bin/emu" "$stage/Autobleem/bin/emunxt" \
             "$stage/Autobleem/rc" "$stage/processors/unzip/bin/linux-i386"
    echo "gui $version" > "$stage/Autobleem/bin/autobleem/autobleem-gui"
    echo "pcsx" > "$stage/Autobleem/bin/emu/pcsx-ab"
    echo "pcsx" > "$stage/Autobleem/bin/emunxt/pcsx-ab"
    echo "#!/bin/sh" > "$stage/Autobleem/rc/boot.sh"
    printf '[Processor]\nVersion=%s\n' "$version" > "$stage/processors/unzip/processor.ini"
    echo "unzip $version" > "$stage/processors/unzip/bin/linux-i386/unzip"
    echo "$version" > "$stage/VERSION"
}

# runs install_payload against $DATA with the package in $STAGE
install_over() {
    bash -c '
        set -euo pipefail
        log() { :; }
        warn() { echo "warn: $*" >&2; }
        die() { echo "die: $*" >&2; exit 1; }
        run() { "$@"; }
        install_cover_databases() { :; }
        DATA_MOUNT="'"$DATA"'"
        STAGE_DIR="'"$STAGE"'"
        SCRIPT_DIR="'"$PAYLOAD_DIR"'"
        source "'"$FUNC_FILE"'"
        install_payload
    ' 2>"$WORK/stderr"
    local rc=$?
    if [ $rc -ne 0 ]; then
        echo "FAIL: install_payload exited $rc"
        cat "$WORK/stderr"
        exit 1
    fi
}

fail() { echo "FAIL: $*"; exit 1; }

DATA="$WORK/data"
STAGE="$WORK/stage1"
# create_tree() makes these before install_payload() runs
mkdir -p "$DATA/Autobleem/bin/autobleem" "$DATA/Autobleem/bin/emu" "$DATA/Autobleem/bin/emunxt" "$DATA/Autobleem/rc" \
         "$DATA/Games" "$DATA/System/Processors" "$DATA/Themes" "$DATA/Apps" "$DATA/Extensions"
make_stage "$STAGE" "v1"

# --- a fresh install: the bundled Unzip is there, no on/off decided ---
install_over
[ "$(cat "$DATA/System/Processors/unzip/bin/linux-i386/unzip")" = "unzip v1" ] || fail "fresh install: unzip not installed"
[ ! -e "$DATA/System/Processors/sequence.ini" ] || fail "fresh install wrote System/Processors/sequence.ini (a processor would start ON)"

# --- the user's life on it: their own processor, its on/off, its data, a setting of the bundled one ---
mkdir -p "$DATA/System/Processors/mine/bin/linux-i386" "$DATA/Home/processors/mine" "$DATA/Home/processors/unzip"
echo "prog" > "$DATA/System/Processors/mine/bin/linux-i386/mine"
printf '[Processor]\nVersion=1.0\n' > "$DATA/System/Processors/mine/processor.ini"
printf '[ps1]\nmine\n-unzip\n\n[roms]\n-mine\n-unzip\n' > "$DATA/System/Processors/sequence.ini"
echo "data" > "$DATA/Home/processors/mine/cache.dat"
echo "data" > "$DATA/Home/processors/unzip/cache.dat"
SEQ_BEFORE="$(cat "$DATA/System/Processors/sequence.ini")"

# --- an update, twice (a reinstall over an update): the new Unzip, everything of the user's still there ---
STAGE="$WORK/stage2"
make_stage "$STAGE" "v2"
install_over
install_over
[ "$(cat "$DATA/System/Processors/unzip/bin/linux-i386/unzip")" = "unzip v2" ] || fail "update: the bundled unzip was not replaced"
[ "$(cat "$DATA/System/Processors/mine/bin/linux-i386/mine")" = "prog" ] || fail "update removed the user's processor"
[ -f "$DATA/System/Processors/mine/processor.ini" ] || fail "update removed the user's processor.ini"
[ "$(cat "$DATA/System/Processors/sequence.ini")" = "$SEQ_BEFORE" ] || fail "update changed System/Processors/sequence.ini"
[ "$(cat "$DATA/Home/processors/mine/cache.dat")" = "data" ] || fail "update removed Home/processors/mine"
[ "$(cat "$DATA/Home/processors/unzip/cache.dat")" = "data" ] || fail "update removed Home/processors/unzip"

echo "PASS"
exit 0
