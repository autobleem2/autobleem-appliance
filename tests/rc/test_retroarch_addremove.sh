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
out=""; resume=0; url=""; head=0
while [ $# -gt 0 ]; do
    case "$1" in -o) out="$2"; shift ;; -C) resume=1; shift ;; -*I*) head=1 ;; -*) ;; *) url="$1" ;; esac
    shift
done
src="$FAKE_SITE/${url#http://fake/}"
have=0; [ -f "$out" ] && have="$(wc -c <"$out")"
echo "${url#http://fake/} resume=$resume have=$have head=$head" >>"$FAKE_LOG"
[ -z "${FAKE_FAIL:-}" ] || exit "$FAKE_FAIL"
[ -f "$src" ] || exit 22
if [ "$head" = 1 ]; then                      # a HEAD request: the headers, with no Content-Length when FAKE_NOLEN
    printf 'HTTP/1.1 200 OK\r\n'
    [ -n "${FAKE_NOLEN:-}" ] || printf 'Content-Length: %s\r\n' "$(wc -c <"$src")"
    printf '\r\n'; exit 0
fi
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
mk_ra() { # mk_ra VERSION [DEPENDS: package names, one per line]
    local d="$WORK/ra-$1"
    mkdir -p "$d/usr/local/bin" "$d/usr/local/share/autobleem" "$d/etc"
    printf '#!/bin/sh\necho retroarch %s\n' "$1" >"$d/usr/local/bin/retroarch"; chmod +x "$d/usr/local/bin/retroarch"
    printf '%s\n' "$1" >"$d/usr/local/share/autobleem/retroarch.version"
    printf '%s' "${2:-}" >"$d/usr/local/share/autobleem/retroarch.depends"
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
check "the part was continued (curl -C - at 100)"    grep -q '^files/cores-pack.tar.gz resume=1 have=100 head=0$' "$FAKE_LOG"
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
cp "$WORK/o7" "$WORK/o7a"
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
check "it is rewritten while a phase runs, with the unit, the package and its place" grep -Eq '^phase 3/7\|download-cores\|[0-9]+\|[0-9]+\|bytes\|cores-pack\.tar\.gz\|1\|1$' "$PROG"
kill -TERM "$wpid"; wait "$wpid"; rc=$?
check "SIGTERM: exit 3 and end|stopped"              test "$rc" -eq 3 -a "$(cat "$PROG")" = "end|stopped"
check "SIGTERM: the .part stays for the resume"      test "$(cat "$SCRATCH"/cores-*.part | wc -c)" -eq 100
check "SIGTERM: the program was not laid"            test ! -e "$RA_BIN"
: >"$FAKE_LOG"
bash "$WRAP" install --progress "$PROG" "${EXTRA[@]}"; rc=$?
checkx "the second install resumes with a range and finishes" 'test "$rc" -eq 0 -a "$(cat "$PROG")" = "end|ok" && grep -q "cores-pack.tar.gz resume=1 have=100 head=0\$" "$FAKE_LOG"'

bash "$WRAP" install --bios --progress "$PROG" "${EXTRA[@]}"; rc=$?
check "wrapper install --bios: ok, the pack is there" test "$rc" -eq 0 -a -f "$STICK/RetroArch/system/b2.dat"
bash "$WRAP" nonsense --progress "$PROG" 2>/dev/null; rc=$?
check "wrapper: a wrong command is a usage error (2)" test "$rc" -eq 2

# 10. the extended phase line: @@phase i/n key done total unit item item_i item_n
phases() { grep '^@@phase' "$1"; }
# a field of the phase lines of one key: field KEY N (the last such line)
fld() { grep "^@@phase [0-9]*/[0-9]* $2 " "$1" | tail -1 | awk -v n="$3" '{ print $n }'; }
[ -z "${DEBUG_RA_TEST:-}" ] || { phases "$WORK/o4"; phases "$WORK/o7"; }
nines=1; zero=1
for o in o4 o6 o7 o8; do
    [ -z "$(phases "$WORK/$o" | awk 'NF != 9' )" ] || nines=0
    [ -z "$(phases "$WORK/$o" | awk '$5 + 0 <= 0')" ] || zero=0
done
check "every @@phase line has the 9 fields"          test "$nines" -eq 1
check "no phase line has a total of 0"               test "$zero" -eq 1
checkx "old consumers: the first five fields still parse" 'phases "$WORK/o4" | while read -r _ i_n key d t _rest; do case "$i_n$key$d$t" in "") exit 1 ;; esac; [ "$t" -ge 1 ] || exit 1; done'
check "download-cores: bytes, the package, 1 of 1, the size from the index" test "$(fld "$WORK/o4" download-cores 6)|$(fld "$WORK/o4" download-cores 7)|$(fld "$WORK/o4" download-cores 8)|$(fld "$WORK/o4" download-cores 9)|$(fld "$WORK/o4" download-cores 4)" = "bytes|cores-pack.tar.gz|1|1|$(wc -c <"$SITE/files/cores-pack.tar.gz")"
check "the done count of a finished download is its total" test "$(fld "$WORK/o4" download-cores 4)" = "$(fld "$WORK/o4" download-cores 5)"
check "download-retroarch names ra-1.0.tar.gz or is cached" test "$(fld "$WORK/o4" download-retroarch 7)" = ra-1.0.tar.gz
check "unpack: bytes of the cores tarball"           test "$(fld "$WORK/o4" unpack 6)|$(fld "$WORK/o4" unpack 4)" = "bytes|$(wc -c <"$SITE/files/cores-pack.tar.gz")"
check "merge-config: 3 items"                        test "$(fld "$WORK/o4" merge-config 6)|$(fld "$WORK/o4" merge-config 5)|$(fld "$WORK/o4" merge-config 9)|$(fld "$WORK/o4" merge-config 7)" = "items|3|3|state-keys"
check "install-binary: items = the files of the tarball" test "$(fld "$WORK/o4" install-binary 6)|$(fld "$WORK/o4" install-binary 4)|$(fld "$WORK/o4" install-binary 7)" = "items|$(tar -tzf "$SITE/files/ra-1.0.tar.gz" | wc -l)|retroarch"
check "check-space: items, 2 steps"                  test "$(fld "$WORK/o4" check-space 6)|$(fld "$WORK/o4" check-space 5)" = "items|2"
check "download-libs with no packages: 1 of 1 items"  test "$(fld "$WORK/o4" download-libs 6)|$(fld "$WORK/o4" download-libs 4)|$(fld "$WORK/o4" download-libs 5)" = "items|1|1"
check "--bios: download-bios counts files (2 of 2)"  test "$(fld "$WORK/o6" download-bios 6)|$(fld "$WORK/o6" download-bios 4)|$(fld "$WORK/o6" download-bios 5)|$(fld "$WORK/o6" download-bios 7)" = "files|2|2|biospack"
check "remove-files: items, the program and 11 folders" test "$(fld "$WORK/o7a" remove-files 6)|$(fld "$WORK/o7a" remove-files 5)|$(fld "$WORK/o7a" remove-files 4)" = "items|12|12"
checkx "remove-files names the folders it goes through" 'phases "$WORK/o7a" | grep -q " remove-files [0-9]* 12 items cores 2 12$" && phases "$WORK/o7a" | grep -q " remove-files [0-9]* 12 items cheats 6 12$"'

# no size in the index: a HEAD gives it; the server giving none either: items, one package
printf '{"i386": {"url": "http://fake/files/cores-pack.tar.gz", "sha256": "%s", "date": "2026-10-12"}}\n' \
    "$(sha256sum "$SITE/files/cores-pack.tar.gz" | cut -d' ' -f1)" >"$SITE/pc/cores/latest.json"
: >"$FAKE_LOG"
run_ra --retroarch-add >"$WORK/o10a" 2>&1; rc=$?
check "no size in the index: succeeds, a HEAD was asked" test "$rc" -eq 0 && grep -q 'cores-pack.tar.gz resume=0 have=0 head=1' "$FAKE_LOG"
check "the HEAD's Content-Length is the total"       test "$(fld "$WORK/o10a" download-cores 6)|$(fld "$WORK/o10a" download-cores 5)" = "bytes|$(wc -c <"$SITE/files/cores-pack.tar.gz")"
FAKE_NOLEN=1 run_ra --retroarch-add >"$WORK/o10b" 2>&1; rc=$?
check "no size anywhere: unit items, 1 package"      test "$rc" -eq 0 -a "$(fld "$WORK/o10b" download-cores 6)|$(fld "$WORK/o10b" download-cores 4)|$(fld "$WORK/o10b" download-cores 5)|$(fld "$WORK/o10b" download-cores 9)" = "items|1|1|1"
check "that run never wrote a total of 0"            test -z "$(phases "$WORK/o10b" | awk '$5 + 0 <= 0')"
run_ra --retroarch-remove >/dev/null 2>&1

# download-libs counts packages and names the current one (fake dpkg-query and apt-get)
export FAKE_DPKG="$WORK/dpkg"; mkdir -p "$FAKE_DPKG"; touch "$FAKE_DPKG/libpresent"
cat >"$WORK/bin/dpkg-query" <<'FAKEDPKG'
#!/usr/bin/env bash
for a; do p="$a"; done
[ -f "$FAKE_DPKG/$p" ] && echo installed
exit 0
FAKEDPKG
cat >"$WORK/bin/apt-get" <<'FAKEAPT'
#!/usr/bin/env bash
[ "$1" = install ] && touch "$FAKE_DPKG/${@: -1}"
echo "apt-get $*" >>"$FAKE_LOG"
exit 0
FAKEAPT
chmod +x "$WORK/bin/dpkg-query" "$WORK/bin/apt-get"
mk_ra 3.0 $'libpresent\nlibone\nlibtwo\n'
printf '{"i386": {"url": "http://fake/files/cores-pack.tar.gz", "sha256": "%s", "size": %s, "date": "2026-10-12"}}\n' \
    "$(sha256sum "$SITE/files/cores-pack.tar.gz" | cut -d' ' -f1)" "$(wc -c <"$SITE/files/cores-pack.tar.gz")" >"$SITE/pc/cores/latest.json"
: >"$FAKE_LOG"
bash "$PKG/install.sh" --platform pcusb --repo http://fake --mount "$STICK" --retroarch-add >"$WORK/o10c" 2>&1; rc=$?
check "libraries: succeeds, only the missing ones go to apt-get" test "$rc" -eq 0 -a "$(grep -c '^apt-get install' "$FAKE_LOG")" -eq 2 -a -f "$FAKE_DPKG/libone" -a -f "$FAKE_DPKG/libtwo"
checkx "download-libs: items, 3 packages, each one named" 'phases "$WORK/o10c" | grep -q " download-libs 0 3 items libpresent 1 3$" && phases "$WORK/o10c" | grep -q " download-libs 1 3 items libone 2 3$" && phases "$WORK/o10c" | grep -q " download-libs 2 3 items libtwo 3 3$" && phases "$WORK/o10c" | grep -q " download-libs 3 3 items "'
check "libraries run did not write a total of 0"     test -z "$(phases "$WORK/o10c" | awk '$5 + 0 <= 0')"
run_ra --retroarch-remove >/dev/null 2>&1

# the wrapper, old and new: a four-field line from an older install.sh passes as four fields
OLD="$WORK/old-install.sh"
printf '#!/usr/bin/env bash\necho "@@phase 2/7 download-cores 3 9"\nsleep 3\necho "@@end ok"\n' >"$OLD"
AB_RA_INSTALLER="$OLD" bash "$WRAP" install --progress "$PROG" -- >/dev/null 2>&1 &
opid=$!; sleep 1.5
check "wrapper: an old four-field @@phase stays four fields" test "$(cat "$PROG")" = "phase 2/7|download-cores|3|9"
wait "$opid"
printf '#!/usr/bin/env bash\necho "@@phase 2/7 unpack 3 9 items - 1 1"\nsleep 3\necho "@@end ok"\n' >"$OLD"
AB_RA_INSTALLER="$OLD" bash "$WRAP" install --progress "$PROG" -- >/dev/null 2>&1 &
opid=$!; sleep 1.5
check "wrapper: no package is an empty item field"   test "$(cat "$PROG")" = "phase 2/7|unpack|3|9|items||1|1"
wait "$opid"

# 11. a remove that was cut short: finished by the next remove, and by the next add
halfdone() { # a power cut after the program and the cores folder were taken away
    mv "$STICK/RetroArch/cores" "$STICK/RetroArch/cores.removing"
    rm -f "$RA_BIN"
}
run_ra --retroarch-add >/dev/null 2>&1
halfdone
run_ra --retroarch-remove >"$WORK/o11a" 2>&1; rc=$?
checkx "half-done remove: the next remove finishes it" 'test "$rc" -eq 0 -a ! -e "$STICK/RetroArch/cores.removing" -a ! -e "$STICK/RetroArch/assets" -a ! -e "$STAMP" -a ! -e "$RA_BIN" && test -z "$(find "$STICK" -name "*.removing")"'
check "half-done remove: the user's data is still there" test -f "$STICK/RetroArch/roms/psx/g.cue" -a -f "$STICK/RetroArch/saves/s.srm"
run_ra --retroarch-add >/dev/null 2>&1
halfdone
run_ra --retroarch-add >"$WORK/o11b" 2>&1; rc=$?
checkx "half-done remove: the next add finishes it and installs" 'test "$rc" -eq 0 -a -x "$RA_BIN" -a -f "$STICK/RetroArch/cores/a_libretro.so" && test -z "$(find "$STICK" -name "*.removing")"'
# SIGTERM during a remove: it is carried through, not left half done
AB_RA_STEP_DELAY=0.4 bash "$WRAP" remove --progress "$PROG" "${EXTRA[@]}" &
rpid=$!
seen=0
for _ in $(seq 1 40); do
    if grep -Eq '^phase 1/1\|remove-files\|[3-9]\|12\|items' "$PROG" 2>/dev/null; then seen=1; break; fi
    sleep 0.25
done
check "remove: the progress file shows its folders going" test "$seen" -eq 1
kill -TERM "$rpid"; wait "$rpid"; rc=$?
checkx "remove + SIGTERM: finishes cleanly (exit 0, end|ok), nothing half done" 'test "$rc" -eq 0 -a "$(cat "$PROG")" = "end|ok" -a ! -e "$RA_BIN" -a ! -e "$STICK/RetroArch/cheats" -a ! -e "$STICK/RetroArch/cores" && test -z "$(find "$STICK" -name "*.removing")"'
check "remove + SIGTERM: the user's data is kept"    test -f "$STICK/RetroArch/roms/psx/g.cue"

[ "$fail" -eq 0 ] && echo "PASS" || echo "FAILED"
exit "$fail"
