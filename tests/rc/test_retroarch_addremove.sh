#!/usr/bin/env bash
#
# PLATFORM-24: payload_linux/install.sh --retroarch-add / --retroarch-remove and the launcher's runner
# payload_linux/system/autobleem-retroarch (the progress file of the contract).
#
# The real install.sh and the real wrapper run against a temp data partition and a temp "/usr/local" (AB_FS_ROOT), with
# a fake curl (a folder as the download site: -C - honoured, a connection cut once, a hang for the SIGTERM test, a
# network that is down) and a fake wget (the BIOS pack) - no network, no root, no BIOS file anywhere.
#
# Run: tests/rc/test_retroarch_addremove.sh      Exit 0 = all behave. Needs bash, tar, python3, sha256sum; skips otherwise.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="$HERE/../../payload_linux"
for tool in bash tar python3 sha256sum mktemp mkfifo; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: no $tool on PATH"; exit 0; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail=0
check() { # check "what" cmd...
    local what="$1"; shift
    if "$@"; then echo "ok   - $what"; else echo "FAIL - $what"; fail=1; fi
}

checkx() { # checkx "what" 'shell expression'  (evaluated here, for the checks that join several tests)
    if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi
}

PKG="$WORK/pkg"; SITE="$WORK/site"; STICK="$WORK/stick"; FSROOT="$WORK/root"
mkdir -p "$PKG/system" "$WORK/bin" "$SITE/files" "$SITE/pc/retroarch" "$SITE/pc/cores" "$STICK" "$FSROOT"
cp "$PAYLOAD/install.sh" "$PKG/install.sh"
cp "$PAYLOAD/system/autobleem-retroarch" "$PKG/system/autobleem-retroarch"
export FAKE_SITE="$SITE" FAKE_LOG="$WORK/curl.log" AB_FS_ROOT="$FSROOT" AB_ARCH=i386 AB_RA_MIN_MIB=1
export AB_DATA_MOUNT="$STICK" AB_RA_INSTALLER="$PKG/install.sh"
: >"$FAKE_LOG"

# --- the fake curl and wget ---
cat >"$WORK/bin/curl" <<'FAKECURL'
#!/usr/bin/env bash
out=""; resume=0; url=""
while [ $# -gt 0 ]; do
    case "$1" in -o) out="$2"; shift ;; -C) resume=1; shift ;; -*) ;; *) url="$1" ;; esac
    shift
done
src="$FAKE_SITE/${url#http://fake/}"
have=0; [ -f "$out" ] && have="$(wc -c <"$out")"
echo "${url#http://fake/} resume=$resume have=$have" >>"$FAKE_LOG"
[ -z "${FAKE_FAIL:-}" ] || exit "$FAKE_FAIL"
[ -f "$src" ] || exit 22
case "$url" in
    */cores-*)
        if [ -n "${FAKE_CUT:-}" ] && [ ! -f "$FAKE_SITE/.cut-done" ]; then     # the connection drops after 100 bytes, once
            touch "$FAKE_SITE/.cut-done"
            tail -c +$((have + 1)) "$src" | head -c 100 >>"$out"
            exit 18
        fi
        if [ -n "${FAKE_HANG:-}" ]; then                                       # 100 bytes, then nothing until killed
            tail -c +$((have + 1)) "$src" | head -c 100 >>"$out"
            exec sleep 30
        fi ;;
esac
if [ "$resume" = 1 ] && [ "$have" -gt 0 ]; then tail -c +$((have + 1)) "$src" >>"$out"; else cat "$src" >"$out"; fi
FAKECURL
cat >"$WORK/bin/wget" <<'FAKEWGET'
#!/usr/bin/env bash
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -O) out="$2"; shift ;; -*) ;; *) url="$1" ;; esac; shift; done
cp "$FAKE_SITE/files/${url##*/}" "$out"
FAKEWGET
chmod +x "$WORK/bin/curl" "$WORK/bin/wget"
export PATH="$WORK/bin:$PATH"

# --- the download site: two RetroArch builds, a cores pack, a two-file BIOS pack ---
mk_ra() { # mk_ra VERSION
    local d="$WORK/ra-$1"
    mkdir -p "$d/usr/local/bin" "$d/usr/local/share/autobleem" "$d/etc"
    printf '#!/bin/sh\necho retroarch %s\n' "$1" >"$d/usr/local/bin/retroarch"; chmod +x "$d/usr/local/bin/retroarch"
    printf '%s\n' "$1" >"$d/usr/local/share/autobleem/retroarch.version"
    : >"$d/usr/local/share/autobleem/retroarch.depends"
    echo 'default config' >"$d/etc/retroarch.cfg"
    head -c 4000 /dev/urandom >"$d/usr/local/share/autobleem/pad.bin"
    tar -C "$d" -czf "$SITE/files/ra-$1.tar.gz" .
    printf '{"version": "%s", "i386": {"url": "http://fake/files/ra-%s.tar.gz", "sha256": "%s", "size": %s}}\n' "$1" "$1" \
        "$(sha256sum "$SITE/files/ra-$1.tar.gz" | cut -d' ' -f1)" "$(wc -c <"$SITE/files/ra-$1.tar.gz")" >"$SITE/pc/retroarch/latest.json"
}
mk_ra 1.0
d="$WORK/cores-src"
mkdir -p "$d/cores" "$d/info" "$d/assets/menu" "$d/autoconfig" "$d/database/rdb" "$d/cheats" "$d/overlays" "$d/shaders"
head -c 4000 /dev/urandom >"$d/cores/a_libretro.so"; echo i >"$d/info/a.info"; echo p >"$d/assets/menu/x.png"
echo a >"$d/autoconfig/p.cfg"; echo r >"$d/database/rdb/x.rdb"; echo c >"$d/cheats/c.cht"; echo o >"$d/overlays/o.cfg"; echo s >"$d/shaders/s.glsl"
tar -C "$d" -czf "$SITE/files/cores-pack.tar.gz" .
printf '{"i386": {"url": "http://fake/files/cores-pack.tar.gz", "sha256": "%s", "size": %s, "date": "2026-10-12"}}\n' \
    "$(sha256sum "$SITE/files/cores-pack.tar.gz" | cut -d' ' -f1)" "$(wc -c <"$SITE/files/cores-pack.tar.gz")" >"$SITE/pc/cores/latest.json"
echo "bios one" >"$SITE/files/b1.dat"; echo "bios two" >"$SITE/files/b2.dat"
: >"$PKG/system/biospack-i386.txt"
for f in b1 b2; do
    printf '%s 9 http://fake/files/%s.dat %s.dat\n' "$(sha256sum "$SITE/files/$f.dat" | cut -d' ' -f1)" "$f" "$f" >>"$PKG/system/biospack-i386.txt"
done

# --- a stick with a user's things on it ---
mkdir -p "$STICK/RetroArch/roms/psx" "$STICK/RetroArch/saves" "$STICK/RetroArch/savestates" "$STICK/RetroArch/playlists" \
    "$STICK/RetroArch/thumbnails" "$STICK/RetroArch/config" "$STICK/RetroArch/screenshots" "$STICK/RetroArch/system" \
    "$STICK/RetroArch/downloads" "$STICK/RetroArch/records" "$STICK/Autobleem/lib" "$STICK/Apps/x" "$STICK/Games/g" "$STICK/System/Bios"
for f in RetroArch/roms/psx/g.cue RetroArch/saves/s.srm RetroArch/savestates/x.state RetroArch/playlists/p.lpl \
         RetroArch/thumbnails/t.png RetroArch/config/c.cfg RetroArch/screenshots/s.png RetroArch/system/own.bin \
         RetroArch/downloads/d.bin RetroArch/records/r.mp4 Autobleem/lib/x.so Apps/x/a Games/g/g.bin System/Bios/romw.bin; do
    echo "$f" >"$STICK/$f"
done
printf 'custom_key = "mine"\nvideo_fullscreen = "false"\n' >"$STICK/RetroArch/retroarch.cfg"

run_ra() { bash "$PKG/install.sh" --platform pcusb --no-packages --repo http://fake --mount "$STICK" "$@"; }
keys() { grep '^@@phase' "$1" | awk '{ print $3 }' | uniq | tr '\n' ' '; }
RA_BIN="$FSROOT/usr/local/bin/retroarch"; STAMP="$FSROOT/usr/local/share/autobleem/retroarch.version"
SCRATCH="$STICK/.autobleem-tmp/ra"

# 1. the distribution's RetroArch is not ours
mkdir -p "$FSROOT/usr/bin"; printf '#!/bin/sh\n' >"$FSROOT/usr/bin/retroarch"; chmod +x "$FSROOT/usr/bin/retroarch"
run_ra --retroarch-add >"$WORK/o1" 2>&1; rc=$?
checkx "add refuses the distribution's RetroArch"    'test "$rc" -eq 1 && grep -q "^@@error apt-provided" "$WORK/o1"'
run_ra --retroarch-remove >"$WORK/o1" 2>&1; rc=$?
checkx "remove refuses it too, and touches nothing"  'test "$rc" -eq 1 -a -d "$STICK/RetroArch/downloads" && grep -q "^@@error apt-provided" "$WORK/o1"'
rm -f "$FSROOT/usr/bin/retroarch"

# 2. the network is down / the disk is full
FAKE_FAIL=7 run_ra --retroarch-add >"$WORK/o2" 2>&1; rc=$?
checkx "no network: exit 1 and no-network"           'test "$rc" -eq 1 && grep -q "^@@error no-network" "$WORK/o2"'
AB_RA_MIN_MIB=999999999 run_ra --retroarch-add >"$WORK/o2" 2>&1; rc=$?
checkx "no space: exit 1 and no-space"               'test "$rc" -eq 1 && grep -q "^@@error no-space" "$WORK/o2"'
check "a refused run leaves no program"              test ! -e "$RA_BIN"

# 3. a connection that drops: the part stays, the program is not laid
FAKE_CUT=1 run_ra --retroarch-add >"$WORK/o3" 2>&1; rc=$?
checkx "a cut download: exit 1 and download"         'test "$rc" -eq 1 && grep -q "^@@error download" "$WORK/o3"'
check "its .part is kept"                            test "$(cat "$SCRATCH"/cores-*.tar.gz.part | wc -c)" -eq 100
check "the program is laid last: not yet"            test ! -e "$RA_BIN"

# 4. the rerun continues it
: >"$FAKE_LOG"
run_ra --retroarch-add >"$WORK/o4" 2>&1; rc=$?
check "the rerun succeeds"                           test "$rc" -eq 0
check "the part was continued (curl -C - at 100)"    grep -q '^files/cores-pack.tar.gz resume=1 have=100$' "$FAKE_LOG"
check "the finished RetroArch was not fetched again" test "$(grep -c 'files/ra-1.0' "$FAKE_LOG")" -eq 0
check "phases in the contract's order, program last" test "$(keys "$WORK/o4")" = "check-space download-retroarch download-cores download-libs unpack merge-config install-binary "
check "n is 7 in every marker"                       test "$(grep '^@@phase' "$WORK/o4" | awk '{ print $2 }' | sed 's|.*/||' | sort -u)" = 7
check "ends with @@end ok"                           test "$(tail -1 "$WORK/o4")" = "@@end ok"
check "the program and its stamp are there"          test -x "$RA_BIN" -a "$(cat "$STAMP")" = 1.0
check "the cores and assets are unpacked"            test -f "$STICK/RetroArch/cores/a_libretro.so" -a -f "$STICK/RetroArch/assets/menu/x.png" -a -f "$STICK/RetroArch/shaders/s.glsl"
checkx "the user's retroarch.cfg is kept and merged" 'grep -q "custom_key = \"mine\"" "$STICK/RetroArch/retroarch.cfg" && grep -q "^savestate_auto_save = \"true\"" "$STICK/RetroArch/retroarch.cfg"'
check "the scratch folder is gone"                   test ! -e "$SCRATCH"
check "no word 'Pi' on a PC"                         test -z "$(grep -w Pi "$WORK/o1" "$WORK/o2" "$WORK/o3" "$WORK/o4" || true)"

# 5. a rerun changes nothing; a newer remote version replaces the old one
run_ra --retroarch-add >"$WORK/o5" 2>&1; rc=$?
check "an idempotent rerun succeeds"                 test "$rc" -eq 0 -a -x "$RA_BIN" -a "$(cat "$STAMP")" = 1.0
mk_ra 2.0
run_ra --retroarch-add >"$WORK/o5" 2>&1; rc=$?
check "an update replaces the version"               test "$rc" -eq 0 -a "$(cat "$STAMP")" = 2.0
check "the user's roms and saves are still there"    test -f "$STICK/RetroArch/roms/psx/g.cue" -a -f "$STICK/RetroArch/saves/s.srm"

# 6. --bios: one phase more, the pack arrives
run_ra --retroarch-add --bios >"$WORK/o6" 2>&1; rc=$?
checkx "--bios: succeeds with 8 phases incl. download-bios" 'test "$rc" -eq 0 -a "$(keys "$WORK/o6")" = "check-space download-retroarch download-cores download-libs download-bios unpack merge-config install-binary " && grep -q "/8 " "$WORK/o6"'
[ -z "${DEBUG_RA_TEST:-}" ] || cat "$WORK/o6"
check "--bios: the pack is in RetroArch/system"      test -f "$STICK/RetroArch/system/b1.dat" -a -f "$STICK/RetroArch/system/b2.dat"

# 7. remove: the program first, the listed folders gone, the rest kept; the BIOS only with --bios
run_ra --retroarch-remove >"$WORK/o7" 2>&1; rc=$?
checkx "remove succeeds, one phase remove-files"     'test "$rc" -eq 0 -a "$(keys "$WORK/o7")" = "remove-files " && grep -q "^@@phase 1/1 remove-files" "$WORK/o7" && test "$(tail -1 "$WORK/o7")" = "@@end ok"'
check "the program, stamp and file list are gone"    test ! -e "$RA_BIN" -a ! -e "$STAMP" -a ! -e "$FSROOT/usr/local/share/autobleem/retroarch.files" -a ! -e "$FSROOT/etc/retroarch.cfg"
gone=1; for x in cores info assets database cheats overlays shaders downloads records; do [ -e "$STICK/RetroArch/$x" ] && gone=0; done
check "cores info assets database cheats overlays shaders downloads records are gone" test "$gone" -eq 1
check "no .removing folder is left"                  test -z "$(find "$STICK" -name '*.removing')"
kept=1; for x in RetroArch/roms/psx/g.cue RetroArch/saves/s.srm RetroArch/savestates/x.state RetroArch/playlists/p.lpl \
                 RetroArch/thumbnails/t.png RetroArch/config/c.cfg RetroArch/screenshots/s.png RetroArch/retroarch.cfg \
                 Autobleem/lib/x.so Apps/x/a Games/g/g.bin System/Bios/romw.bin RetroArch/system/own.bin RetroArch/system/b1.dat; do
    [ -e "$STICK/$x" ] || { echo "   missing: $x"; kept=0; }
done
check "roms, saves, states, playlists, thumbnails, config, cfg, libs, apps, games and the BIOS are kept" test "$kept" -eq 1
run_ra --retroarch-remove >"$WORK/o7" 2>&1; rc=$?
check "a second remove is fine"                      test "$rc" -eq 0
run_ra --retroarch-remove --bios >"$WORK/o7" 2>&1; rc=$?
check "remove --bios also deletes the BIOS files"    test "$rc" -eq 0 -a ! -e "$STICK/RetroArch/system" -a -f "$STICK/RetroArch/roms/psx/g.cue"

# 8. install after remove re-merges retroarch.cfg
run_ra --retroarch-add >"$WORK/o8" 2>&1; rc=$?
checkx "install after remove: works, cfg re-merged"  'test "$rc" -eq 0 -a -x "$RA_BIN" && grep -q "custom_key = \"mine\"" "$STICK/RetroArch/retroarch.cfg" && grep -q "^savestates_in_content_dir = \"false\"" "$STICK/RetroArch/retroarch.cfg"'
run_ra --retroarch-remove >/dev/null 2>&1

# 9. the wrapper: the progress file of the contract
WRAP="$PKG/system/autobleem-retroarch"; PROG="$WORK/prog/progress"
EXTRA=(-- --platform pcusb --no-packages --repo http://fake)
bash "$WRAP" install --progress "$PROG" "${EXTRA[@]}"; rc=$?
check "wrapper install: exit 0, last line end|ok"    test "$rc" -eq 0 -a "$(cat "$PROG")" = "end|ok" -a "$(wc -l <"$PROG")" -eq 1
check "wrapper: the program is installed, the log is next to the file" test -x "$RA_BIN" -a -s "$PROG.log"
check "wrapper: no .tmp or fifo left"                test ! -e "$PROG.tmp" -a ! -e "$PROG.fifo"

bash "$WRAP" remove --progress "$PROG" "${EXTRA[@]}"; rc=$?
check "wrapper remove: exit 0, end|ok"              test "$rc" -eq 0 -a "$(cat "$PROG")" = "end|ok" -a ! -e "$RA_BIN"

FAKE_FAIL=7 bash "$WRAP" install --progress "$PROG" "${EXTRA[@]}"; rc=$?
check "wrapper: no network is exit 1, end|error|no-network" test "$rc" -eq 1 -a "$(cat "$PROG")" = "end|error|no-network"
printf '#!/bin/sh\n' >"$FSROOT/usr/bin/retroarch"; chmod +x "$FSROOT/usr/bin/retroarch"
bash "$WRAP" remove --progress "$PROG" "${EXTRA[@]}"; rc=$?
check "wrapper: the distribution's RetroArch is end|error|apt-provided" test "$rc" -eq 1 -a "$(cat "$PROG")" = "end|error|apt-provided"
rm -f "$FSROOT/usr/bin/retroarch"

# SIGTERM in the middle of the cores download: end|stopped, exit 3, the part stays; the rerun resumes
rm -f "$PROG"; : >"$FAKE_LOG"
FAKE_HANG=1 bash "$WRAP" install --progress "$PROG" "${EXTRA[@]}" &
wpid=$!
seen=0
for _ in $(seq 1 40); do
    if grep -q '^phase 3/7|download-cores|' "$PROG" 2>/dev/null && ls "$SCRATCH"/cores-*.part >/dev/null 2>&1; then seen=1; break; fi
    sleep 0.25
done
check "the progress file shows phase 3/7 download-cores while it runs" test "$seen" -eq 1
sleep 1.5
check "it is rewritten while a phase runs (the byte count moves or the line is fresh)" grep -q '^phase 3/7|download-cores|[0-9]*|[0-9]*$' "$PROG"
kill -TERM "$wpid"; wait "$wpid"; rc=$?
check "SIGTERM: exit 3 and end|stopped"              test "$rc" -eq 3 -a "$(cat "$PROG")" = "end|stopped"
check "SIGTERM: the .part stays for the resume"      test "$(cat "$SCRATCH"/cores-*.part | wc -c)" -eq 100
check "SIGTERM: the program was not laid"            test ! -e "$RA_BIN"
: >"$FAKE_LOG"
bash "$WRAP" install --progress "$PROG" "${EXTRA[@]}"; rc=$?
checkx "the second install resumes with a range and finishes" 'test "$rc" -eq 0 -a "$(cat "$PROG")" = "end|ok" && grep -q "cores-pack.tar.gz resume=1 have=100\$" "$FAKE_LOG"'

bash "$WRAP" install --bios --progress "$PROG" "${EXTRA[@]}"; rc=$?
check "wrapper install --bios: ok, the pack is there" test "$rc" -eq 0 -a -f "$STICK/RetroArch/system/b2.dat"
bash "$WRAP" nonsense --progress "$PROG" 2>/dev/null; rc=$?
check "wrapper: a wrong command is a usage error (2)" test "$rc" -eq 2

[ "$fail" -eq 0 ] && echo "PASS" || echo "FAILED"
exit "$fail"
