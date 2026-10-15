#!/usr/bin/env bash
#
# PLATFORM-23: payload_linux/install.sh's download_bios_pack() / bios_fetch_one() - the BIOS pack fetched four files at
# a time (xargs -P 4), a part an interrupted run left continued (wget -c), a part with wrong bytes dropped and the file
# fetched whole, a file with the right hash kept, a lost one counted and reported.
#
# The two functions are extracted verbatim from install.sh and run against a fake `wget` (served from a folder, -c
# honoured, concurrency measured) and a fake manifest - no network, no BIOS file anywhere (the "files" are text).
#
# Run: tests/rc/test_bios_parallel.sh [path-to-install.sh]
# Exit 0 = all behave. Needs bash, xargs -d (GNU findutils), sha256sum; skips (exit 0) when one is missing.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${1:-$SCRIPT_DIR/../../payload_linux/install.sh}"

for tool in bash xargs sha256sum awk mktemp; do
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

# --- the real functions ---
for fn in bg_reap bg_track bios_fetch_one download_bios_pack; do
    awk -v f="$fn" '$0 ~ "^" f "\\(\\) \\{" {p=1} p{print; if (/^\}/) exit}' "$INSTALL_SH" >"$WORK/$fn.sh"
    [ -s "$WORK/$fn.sh" ] || { echo "FAIL: could not extract $fn() from $INSTALL_SH"; exit 1; }
done

# --- the fake site and the fake wget ---
SITE="$WORK/site"; mkdir -p "$SITE" "$WORK/bin"
export FAKE_SITE="$SITE" FAKE_LOG="$WORK/wget.log" FAKE_CONC="$WORK/conc.log"
: >"$FAKE_LOG"; : >"$FAKE_CONC"
cat >"$WORK/bin/wget" <<'FAKEWGET'
#!/usr/bin/env bash
out=""; resume=0; url=""
while [ $# -gt 0 ]; do
    case "$1" in -q) ;; -c) resume=1 ;; -O) out="$2"; shift ;; *) url="$1" ;; esac
    shift
done
name="${url##*/}"
have=0; [ -f "$out" ] && have="$(wc -c <"$out")"
echo "$name resume=$resume have=$have" >>"$FAKE_LOG"
slot="$FAKE_SITE/.active.$$"; mkdir "$slot"
ls -d "$FAKE_SITE"/.active.* 2>/dev/null | wc -l >>"$FAKE_CONC"
sleep 0.2
rmdir "$slot"
src="$FAKE_SITE/$name"
if [ ! -f "$src" ]; then [ -f "$out" ] || : >"$out"; exit 8; fi
case "$name" in
    cut*)
        if [ ! -f "$FAKE_SITE/.cut-done" ]; then # the connection drops after 100 bytes, once
            touch "$FAKE_SITE/.cut-done"
            if [ "$resume" = 1 ] && [ "$have" -gt 0 ]; then tail -c +$((have + 1)) "$src" | head -c 100 >>"$out"
            else head -c 100 "$src" >"$out"; fi
            exit 4
        fi ;;
esac
if [ "$resume" = 1 ] && [ "$have" -gt 0 ]; then tail -c +$((have + 1)) "$src" >>"$out"; else cat "$src" >"$out"; fi
FAKEWGET
chmod +x "$WORK/bin/wget"

# 10 ordinary files, one that is not on the "server", one whose connection drops, one with a junk part waiting
manifest="$WORK/pkg/system/biospack.txt"; mkdir -p "$WORK/pkg/system"
: >"$manifest"
body() { printf 'text standing in for %s %s\n' "$1" "$(printf 'x%.0s' $(seq 1 300))"; }
for n in 0 1 2 3 4 5 6 7 8 9 cut junk gone; do
    name="f$n.dat"; case "$n" in cut|junk|gone) name="$n.dat" ;; esac
    body "$name" >"$SITE/$name"
    [ "$n" = gone ] && rm -f "$SITE/$name"
    if [ "$n" = gone ]; then sum="$(printf 'a%.0s' $(seq 1 64))"; else sum="$(sha256sum "$SITE/$name" | cut -d' ' -f1)"; fi
    sub=""; [ "$n" = 3 ] && sub="sub dir/"
    printf '%s %s http://fake/%s %s%s\n' "$sum" 300 "$name" "$sub" "$name" >>"$manifest"
done

# --- the harness around the extracted functions ---
RA_ROOT="$WORK/stick/RetroArch"; mkdir -p "$RA_ROOT/system"
DATA_MOUNT="$WORK/stick"; DO_BIOS=1; DRY_RUN=0; ARCH=armhf; RETROARCH_MODE=full; LOG="$WORK/install.log"
log()  { echo "$*" >>"$LOG"; }
warn() { echo "WARN $*" >>"$LOG"; }
install_ps1_bios() { :; }
sync() { :; }
# shellcheck disable=SC1090
BG_PIDS=""; BG_PREV_EXIT=""; BG_GUARD=0     # the globals bg_track keeps (set above the functions in install.sh)
. "$WORK/bg_reap.sh"; . "$WORK/bg_track.sh"
. "$WORK/bios_fetch_one.sh"; . "$WORK/download_bios_pack.sh"
export SCRIPT_DIR="$WORK/pkg"
PATH="$WORK/bin:$PATH"

# a junk part for junk.dat: right size prefix? no - wrong bytes, so the resumed file fails its hash
printf 'JUNK%.0s' $(seq 1 20) >"$RA_ROOT/system/junk.dat.part"

download_bios_pack >"$WORK/run1.out" 2>&1
want="$(body f5.dat)"
check "ordinary files arrive whole"            test "$(cat "$RA_ROOT/system/f5.dat")" = "$want"
check "a path with a space and a folder works"  test -f "$RA_ROOT/system/sub dir/f3.dat"
check "the lost file is reported, not fetched"  grep -q '2 BIOS files did not download' "$LOG"
check "the pack went four at a time"            test "$(sort -n "$FAKE_CONC" | tail -1)" -ge 2 -a "$(sort -n "$FAKE_CONC" | tail -1)" -le 4
check "a dropped connection leaves its part"    test "$(wc -c <"$RA_ROOT/system/cut.dat.part")" -eq 100
check "a junk part is gone, the file is whole"  test "$(cat "$RA_ROOT/system/junk.dat")" = "$(body junk.dat)"
check "the junk part was continued, then the file fetched again from byte 0" \
    test "$(grep -c '^junk.dat' "$FAKE_LOG")" -eq 2 -a "$(grep '^junk.dat' "$FAKE_LOG" | tail -1)" = "junk.dat resume=1 have=0"
check "no part is left for a 404"               test ! -e "$RA_ROOT/system/gone.dat.part"

# the second run: everything but cut and gone is kept (no request), cut continues at byte 100
: >"$FAKE_LOG"
download_bios_pack >"$WORK/run2.out" 2>&1
check "the second run asks only for what is missing" test "$(sort -u "$FAKE_LOG" | cut -d' ' -f1 | sort | tr '\n' ' ')" = "cut.dat gone.dat "
check "the dropped file continues at byte 100"  grep -q '^cut.dat resume=1 have=100$' "$FAKE_LOG"
check "the continued file is whole and checked" test "$(cat "$RA_ROOT/system/cut.dat")" = "$(body cut.dat)"
check "the counter line is on the screen"       grep -q '13/ 13' "$WORK/run2.out"

# --- AUTOBLEEM-38: PlayStation names in a manifest, resume and a second run as above; romw.bin/romJP.bin skipped ---
rm -rf "$SITE" "$WORK/stick"; mkdir -p "$SITE" "$WORK/stick/RetroArch/system"
: >"$manifest"
for name in scph5501.bin SCPH1001.BIN ps1_rom.bin psxonpsp660.bin "scph9002(7502).bin" acpsx.zip gba_bios.bin disksys.rom \
            "sub dir/scph5500.bin"; do
    file="${name##*/}"
    body "$file" >"$SITE/$file"
    printf '%s %s http://fake/%s %s\n' "$(sha256sum "$SITE/$file" | cut -d' ' -f1)" 300 "$file" "$name" >>"$manifest"
done
: >"$FAKE_LOG"; : >"$LOG"
for name in romw.bin romJP.bin; do   # manifest entries named like pcsx-ab's files are skipped
    body "$name" >"$SITE/$name"
    printf '%s %s http://fake/%s %s\n' "$(sha256sum "$SITE/$name" | cut -d' ' -f1)" 300 "$name" "$name" >>"$manifest"
done
# a part an earlier run left (the true first 100 bytes) is continued
body psxonpsp660.bin | head -c 100 >"$RA_ROOT/system/psxonpsp660.bin.part"
download_bios_pack >"$WORK/run3.out" 2>&1
asked="$(cut -d" " -f1 "$FAKE_LOG" | LC_ALL=C sort | tr '\n' ' ')"
check "the whole pack is asked for, but not romw.bin / romJP.bin" \
    test "$asked" = "SCPH1001.BIN acpsx.zip disksys.rom gba_bios.bin ps1_rom.bin psxonpsp660.bin scph5500.bin scph5501.bin scph9002(7502).bin "
check "romw.bin / romJP.bin are not in RetroArch/system" test ! -e "$RA_ROOT/system/romw.bin" -a ! -e "$RA_ROOT/system/romJP.bin"
check "a left part is continued"      grep -q '^psxonpsp660.bin resume=1 have=100$' "$FAKE_LOG"
check "the counter says 9 files"      grep -q '9/  9' "$WORK/run3.out"
: >"$FAKE_LOG"
download_bios_pack >"$WORK/run4.out" 2>&1
check "a second run asks for nothing" test ! -s "$FAKE_LOG"
check "and reports them kept"         grep -q '0 downloaded, 9 already there' "$LOG"

# --- a failing BIOS fetch that leaves install.sh through exit: the 1 s ticker must not outlive it ---
# The harness runs download_bios_pack as --retroarch-add does (RA_ACTION=add -> the ticker), with an EXIT trap of its
# own that prints @@end (it must still run: the guard composes), every fetch failing (fake wget: 404) and
# install_ps1_bios dying with exit 1 after the ticker has had time to print.
rm -rf "$SITE" "$WORK/stick"; mkdir -p "$SITE" "$WORK/stick/RetroArch/system"
printf '%s %s http://fake/nope.dat nope.dat\n' "$(printf 'a%.0s' $(seq 1 64))" 300 >"$manifest"
mkdir -p "$WORK/bin2"
# the failing fetch: after the ticker has printed a few markers wget fails (404) and tells the installer to stop
printf '#!/usr/bin/env bash\nsleep 2.5\nkill -TERM "$HARNESS_PID" 2>/dev/null\nexit 8\n' >"$WORK/bin2/wget"
chmod +x "$WORK/bin2/wget"
cat >"$WORK/die_harness.sh" <<HARNESS
#!/usr/bin/env bash
RA_ROOT="$WORK/stick/RetroArch"; DATA_MOUNT="$WORK/stick"; DO_BIOS=1; DRY_RUN=0; RETROARCH_MODE=full
RA_ACTION=add; RA_UNIT=files; SCRIPT_DIR="$WORK/pkg"; export SCRIPT_DIR
BG_PIDS=""; BG_PREV_EXIT=""; BG_GUARD=0
log() { :; }
warn() { :; }
sync() { :; }
ra_item() { :; }
ra_marker() { printf '@@phase tick %s %s\n' "\${1:-0}" "\${2:-0}"; }
install_ps1_bios() { exit 1; }
trap 'exit 3' TERM
. "$WORK/bg_reap.sh"; . "$WORK/bg_track.sh"; . "$WORK/bios_fetch_one.sh"; . "$WORK/download_bios_pack.sh"
PATH="$WORK/bin2:\$PATH"
trap 'echo @@end' EXIT
download_bios_pack
HARNESS
bash -c 'export HARNESS_PID=$$; exec bash "$1"' _ "$WORK/die_harness.sh" >"$WORK/die.out" 2>&1 &
harness_pid=$!
wait "$harness_pid"; harness_rc=$?
size_end="$(wc -c <"$WORK/die.out")"
sleep 2.5
check "the failing run left through the stop (exit 3)" test "$harness_rc" -eq 3
check "the ticker did print while it ran"            test "$(grep -c '^@@phase tick' "$WORK/die.out")" -ge 2
check "the earlier EXIT trap still ran (@@end last)" test "$(tail -n 1 "$WORK/die.out")" = "@@end"
check "no marker line after the end"                 test "$(wc -c <"$WORK/die.out")" -eq "$size_end"
check "no child of the installer is left"            test -z "$(pgrep -P "$harness_pid" 2>/dev/null)"
check "no ticker process outlives it"                test -z "$(pgrep -f "$WORK/die_harness.sh" 2>/dev/null)"

[ -n "${DEBUG_BIOS_TEST:-}" ] && { cat "$WORK/die.out"; cat "$FAKE_LOG"; cat "$LOG"; }
[ "$fail" -eq 0 ] && echo "PASS" || echo "FAILED"
exit "$fail"
