#!/usr/bin/env bash
#
# AUTOBLEEM-38: payload_linux/install.sh's install_ps1_bios() and the BIOS pack. The rules (owner's answers):
#   - nothing overwrites an installed System/Bios/romw.bin or romJP.bin - a Sony one, OpenBIOS, not even a newer OpenBIOS;
#   - an empty slot gets the package's system/openbios.bin, nothing is ever copied from the pack;
#   - --retroarch none fetches nothing (no network call); the pack goes to RetroArch/system only (--retroarch-add --bios);
#   - a manifest entry named romw.bin is skipped; --retroarch-remove --bios leaves System/Bios alone.
#
# The functions are extracted verbatim from install.sh and run against a fake wget (served from a folder, every call
# logged) and a fake manifest - no network, the "BIOS files" are text.
#
# Run: tests/rc/test_ps1_bios.sh [path-to-install.sh]
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${1:-$SCRIPT_DIR/../../payload_linux/install.sh}"

for tool in bash xargs sha256sum awk mktemp cmp; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: no $tool on PATH"; exit 0; }
done
echo x | xargs -d '\n' echo >/dev/null 2>&1 || { echo "SKIP: xargs has no -d"; exit 0; }
[ -f "$INSTALL_SH" ] || { echo "FAIL: $INSTALL_SH not found"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail=0
check() { # check "what" cmd...
    local what="$1"; shift
    if "$@"; then echo "ok   - $what"; else echo "FAIL - $what"; fail=1; fi
}

for fn in bg_reap bg_track bios_fetch_one download_bios_pack is_openbios install_ps1_bios; do
    awk -v f="$fn" '$0 ~ "^" f "\\(\\) \\{" {p=1} p{print; if (/^\}/) exit}' "$INSTALL_SH" >"$WORK/$fn.sh"
    [ -s "$WORK/$fn.sh" ] || { echo "FAIL: could not extract $fn() from $INSTALL_SH"; exit 1; }
done

# fake wget: serves $FAKE_SITE/<name>, logs every call
SITE="$WORK/site"; mkdir -p "$SITE" "$WORK/bin"
export FAKE_SITE="$SITE" FAKE_LOG="$WORK/wget.log"
: >"$FAKE_LOG"
cat >"$WORK/bin/wget" <<'FAKEWGET'
#!/usr/bin/env bash
out=""; url=""
while [ $# -gt 0 ]; do
    case "$1" in -q|-c) ;; -O) out="$2"; shift ;; *) url="$1" ;; esac
    shift
done
name="${url##*/}"
echo "$name" >>"$FAKE_LOG"
[ -f "$FAKE_SITE/$name" ] || { : >"$out"; exit 8; }
cat "$FAKE_SITE/$name" >"$out"
FAKEWGET
chmod +x "$WORK/bin/wget"
PATH="$WORK/bin:$PATH"

# the package: OpenBIOS (a text file with the mark at 0x78), and a manifest with a Sony BIOS, one more file and romw.bin
PKG="$WORK/pkg"; mkdir -p "$PKG/system"
{ printf 'OPENBIOS-PACKAGE-%0103d' 0; printf 'OpenBIOS'; printf 'rest of the image\n'; } >"$PKG/system/openbios.bin"
manifest="$PKG/system/biospack.txt"; : >"$manifest"
add_entry() { # add_entry <name-on-site> <path-in-pack>
    printf 'sony bios %s\n' "$1" >"$SITE/$1"
    printf '%s 20 http://fake/%s %s\n' "$(sha256sum "$SITE/$1" | cut -d' ' -f1)" "$1" "$2" >>"$manifest"
}
add_entry scph5501.bin scph5501.bin
add_entry scph5500.bin scph5500.bin
add_entry gba_bios.bin gba_bios.bin
add_entry romw.bin romw.bin

# the harness around the functions
STICK="$WORK/stick"
LOG="$WORK/install.log"
DO_BIOS=1; DRY_RUN=0; ARCH=armhf; RETROARCH_MODE=full; RA_ACTION=""
log()  { echo "$*" >>"$LOG"; }
warn() { echo "WARN $*" >>"$LOG"; }
run()  { "$@"; }
sync() { :; }
ra_item() { :; }
ra_marker() { :; }
BG_PIDS=""; BG_PREV_EXIT=""; BG_GUARD=0
# shellcheck disable=SC1090
for fn in bg_reap bg_track bios_fetch_one download_bios_pack is_openbios install_ps1_bios; do . "$WORK/$fn.sh"; done
export SCRIPT_DIR="$PKG"

fresh() { # a new stick with an empty System/Bios
    rm -rf "$STICK"; mkdir -p "$STICK/System/Bios" "$STICK/RetroArch/system"
    DATA_MOUNT="$STICK"; RA_ROOT="$STICK/RetroArch"; : >"$FAKE_LOG"; : >"$LOG"
}
BIOS="$STICK/System/Bios"
open_bin="$PKG/system/openbios.bin"

# --- 1: --retroarch none: no network call, OpenBIOS stays as romw/romJP ---
fresh; RETROARCH_MODE=none
download_bios_pack >"$WORK/o1" 2>&1
check "--retroarch none: no network call"            test ! -s "$FAKE_LOG"
check "--retroarch none: romw.bin is OpenBIOS"       cmp -s "$open_bin" "$BIOS/romw.bin"
check "--retroarch none: romJP.bin is OpenBIOS"      cmp -s "$open_bin" "$BIOS/romJP.bin"
check "--retroarch none: RetroArch/system is empty"  test -z "$(ls -A "$RA_ROOT/system")"
download_bios_pack >"$WORK/o1b" 2>&1
check "--retroarch none, again: still OpenBIOS, logged as kept" grep -q 'OpenBIOS kept' "$LOG"
check "--retroarch none, again: still no network call" test ! -s "$FAKE_LOG"

# --- 2: a pack with scph5501 does not replace OpenBIOS (and a package with a different OpenBIOS does not refresh it) ---
fresh; RETROARCH_MODE=full
install_ps1_bios >/dev/null 2>&1
want="$(sha256sum "$BIOS/romw.bin" | cut -d' ' -f1)"
download_bios_pack >"$WORK/o2" 2>&1
check "the pack's scph5501 is in RetroArch/system"   test -f "$RA_ROOT/system/scph5501.bin"
check "romw.bin is still OpenBIOS"                   test "$(sha256sum "$BIOS/romw.bin" | cut -d' ' -f1)" = "$want"
check "romJP.bin is still OpenBIOS"                  cmp -s "$open_bin" "$BIOS/romJP.bin"
printf 'OpenBIOS-NEWER %0112d' 0 | head -c 120 >"$WORK/newer.bin"; printf 'OpenBIOS newer' >>"$WORK/newer.bin"
cp "$open_bin" "$WORK/open.keep"; cp "$WORK/newer.bin" "$open_bin"
install_ps1_bios >/dev/null 2>&1
check "a newer OpenBIOS in the package does not refresh (no refresh case)" \
    test "$(sha256sum "$BIOS/romw.bin" | cut -d' ' -f1)" = "$want"
cp "$WORK/open.keep" "$open_bin"

# --- 3: the user's own Sony romw.bin is kept ---
fresh; RETROARCH_MODE=full
printf 'USERS OWN SONY BIOS\n' >"$BIOS/romw.bin"
download_bios_pack >"$WORK/o3" 2>&1
check "the user's romw.bin is kept"                  test "$(cat "$BIOS/romw.bin")" = "USERS OWN SONY BIOS"
check "the empty romJP.bin slot gets OpenBIOS"       cmp -s "$open_bin" "$BIOS/romJP.bin"
check "the user's file is logged as kept"            grep -q 'Keeping the existing .*romw.bin' "$LOG"

# --- 4: --retroarch-add --bios fills RetroArch/system, System/Bios stays byte-identical ---
fresh; RETROARCH_MODE=prebuilt; RA_ACTION=add
printf 'USERS OWN SONY BIOS\n' >"$BIOS/romw.bin"
install_ps1_bios >/dev/null 2>&1
before="$(cd "$BIOS" && sha256sum romw.bin romJP.bin)"
download_bios_pack >"$WORK/o4" 2>&1
after="$(cd "$BIOS" && sha256sum romw.bin romJP.bin)"
check "--retroarch-add --bios: RetroArch/system is filled" \
    test -f "$RA_ROOT/system/scph5501.bin" -a -f "$RA_ROOT/system/scph5500.bin" -a -f "$RA_ROOT/system/gba_bios.bin"
check "--retroarch-add --bios: System/Bios is byte-identical" test "$before" = "$after"
RA_ACTION=""

# --- 5: a manifest entry named romw.bin is skipped ---
check "the romw.bin entry was never fetched"         test -z "$(grep -x 'romw.bin' "$FAKE_LOG")"
check "no romw.bin in RetroArch/system"              test ! -e "$RA_ROOT/system/romw.bin"

# --- 6: --retroarch-remove --bios leaves System/Bios alone (the folders it removes are all under RetroArch/) ---
dirs_line="$(awk '/local dirs=\(/ {p=1} p {print} /RA_WITH_BIOS.*dirs\+=/ {exit}' "$INSTALL_SH")"
check "--retroarch-remove --bios: only RetroArch folders are removed" \
    test -n "$dirs_line" && ! printf '%s' "$dirs_line" | grep -qi 'System/Bios'

# --- the old option is gone ---
check "--ps1-bios-only is gone from install.sh"      test -z "$(grep -n 'ps1-bios-only\|PS1_BIOS_ONLY' "$INSTALL_SH")"

[ "$fail" -eq 0 ] && echo "PASS" || echo "FAILED"
exit "$fail"
