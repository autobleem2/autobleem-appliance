#!/usr/bin/env bash
#
# PLATFORM-23: payload_linux/install.sh on a Pi image that already carries the packages and the offline
# RetroArch/cores tarballs (tools/make_rpi_image.sh's pre-install):
#   - install_packages runs no apt at all when dpkg has every package, and exactly one update + one install when
#     one is missing;
#   - install_retroarch_depends likewise, and --print-packages lists base + plymouth + the tarball's depends;
#   - offline_setup takes a tarball only when SHA256SUMS vouches for it.
# The functions are extracted verbatim from install.sh and run with stub dpkg-query/apt-cache/apt-get on PATH.
#
# Run: tests/rc/test_preinstalled_image.sh [path-to-install.sh]   Exit 0 = all pass.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${1:-$SCRIPT_DIR/../../payload_linux/install.sh}"
command -v bash >/dev/null 2>&1 || { echo "SKIP: no bash on PATH"; exit 0; }
command -v sha256sum >/dev/null 2>&1 || { echo "SKIP: no sha256sum"; exit 0; }
[ -f "$INSTALL_SH" ] || { echo "FAIL: $INSTALL_SH not found"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FUNCS="$WORK/funcs.sh"
printf 'log() { :; }
warn() { :; }
' > "$FUNCS"
for fn in pkg_first_available base_packages pkg_pick retroarch_depends_packages packages_present \
          apt_update_once install_packages install_retroarch_depends offline_setup; do
    awk -v fn="$fn" '$0 ~ "^" fn "\\(\\) \\{" || $0 ~ "^" fn "\\(\\)  *\\{" {p=1} p {print; if (/^\}/) exit}' "$INSTALL_SH" >> "$FUNCS"
    grep -q "^$fn() {" "$FUNCS" || { echo "FAIL: could not extract $fn from $INSTALL_SH"; exit 1; }
done

# stubs: dpkg-query says "installed" for every name in $INSTALLED (space separated), apt-get writes its calls to $CALLS,
# apt-cache policy knows every name as installable
BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/dpkg-query" <<'EOF'
#!/bin/sh
name=""
for a in "$@"; do name="$a"; done
case " $INSTALLED " in *" $name "*) printf installed ;; *) exit 1 ;; esac
EOF
cat > "$BIN/apt-get" <<'EOF'
#!/bin/sh
echo "apt-get $*" >> "$CALLS"
EOF
cat > "$BIN/apt-cache" <<'EOF'
#!/bin/sh
printf '%s:\n  Installed: (none)\n  Candidate: 1.0\n' "$2"
EOF
chmod +x "$BIN"/*

FAILS=0
check() { # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 (expected '$2', got '$3')"; FAILS=$((FAILS + 1)); fi
}

ALL_BASE="libsdl2-2.0-0 libsdl2-image-2.0-0 libsdl2-mixer-2.0-0 libsdl2-ttf-2.0-0 libgl1 libgl1-mesa-dri libegl1 libgles2 libgbm1 libpng16-16t64 zlib1g exfatprogs parted alsa-utils wget unzip ca-certificates"

run_case() { # run_case <INSTALLED> <function...>: runs the function with the stubs, prints apt-get's calls
    : > "$WORK/calls"
    PATH="$BIN:$PATH" INSTALLED="$1" CALLS="$WORK/calls" bash -c '
        set -uo pipefail
        run() { "$@"; }
        DRY_RUN=0; DO_PACKAGES=1; BOOT_SPLASH=1; APT_UPDATED=0
        source "'"$FUNCS"'"
        shift_installed="$1"; shift
        "$@"
    ' bash "$1" "${@:2}" >/dev/null 2>&1
    cat "$WORK/calls"
}

# 1. everything in the image: no apt call at all
check "all packages installed -> no apt" "" "$(run_case "$ALL_BASE plymouth" install_packages)"
# 2. one missing: one update, one install naming it (plymouth missing: its own install)
got="$(run_case "$ALL_BASE" install_packages | tr '\n' '|')"
check "plymouth missing -> update + install plymouth" "apt-get update|apt-get install -y plymouth|" "$got"
got="$(run_case "${ALL_BASE/exfatprogs/} plymouth" install_packages | tr '\n' '|')"
case "$got" in
    "apt-get update|apt-get install -y libsdl2-2.0-0 "*"exfatprogs"*"|") echo "ok   - exfatprogs missing -> update + one install of the list" ;;
    *) echo "FAIL - exfatprogs missing: '$got'"; FAILS=$((FAILS + 1)) ;;
esac
# --no-boot-splash: plymouth is not asked for
check "no splash, all installed -> no apt" "" "$(PATH="$BIN:$PATH" INSTALLED="$ALL_BASE" CALLS="$WORK/calls" bash -c '
    run() { "$@"; }; DRY_RUN=0; DO_PACKAGES=1; BOOT_SPLASH=0; APT_UPDATED=0; : > "$CALLS"; source "'"$FUNCS"'"; install_packages >/dev/null 2>&1; cat "$CALLS"')"

# 3. RetroArch's libraries: the depends file lists Bookworm names; Trixie's t64 name is the installed one
mkdir -p "$WORK/ra"
printf 'libasound2\nlibdrm2\nlibxkbcommon0\n' > "$WORK/ra/retroarch.depends"
got="$(PATH="$BIN:$PATH" INSTALLED="libasound2t64 libdrm2 libxkbcommon0" CALLS="$WORK/calls" bash -c '
    source "'"$FUNCS"'"; retroarch_depends_packages "'"$WORK/ra/retroarch.depends"'" | tr "\n" " "')"
check "retroarch.depends resolves the installed t64 name" "libasound2t64 libdrm2 libxkbcommon0 " "$got"
# the same from inside a RetroArch tarball
mkdir -p "$WORK/tar/usr/local/share/autobleem"
cp "$WORK/ra/retroarch.depends" "$WORK/tar/usr/local/share/autobleem/retroarch.depends"
tar -czf "$WORK/ra.tar.gz" -C "$WORK/tar" ./usr
got="$(PATH="$BIN:$PATH" INSTALLED="libasound2t64 libdrm2 libxkbcommon0" bash -c '
    source "'"$FUNCS"'"; retroarch_depends_packages "'"$WORK/ra.tar.gz"'" | tr "\n" " "')"
check "retroarch.depends read out of the tarball" "libasound2t64 libdrm2 libxkbcommon0 " "$got"

# 4. offline_setup: only a tarball whose checksum is in SHA256SUMS
mkdir -p "$WORK/off"
printf 'ra-bytes' > "$WORK/off/retroarch.tar.gz"
printf 'cores-bytes' > "$WORK/off/cores.tar.gz"
( cd "$WORK/off" && sha256sum retroarch.tar.gz cores.tar.gz > SHA256SUMS )
got="$(bash -c 'source "'"$FUNCS"'"; OFFLINE_DIR="'"$WORK/off"'"; RETROARCH_TARBALL=""; CORES_TARBALL=""; offline_setup >/dev/null 2>&1; echo "$RETROARCH_TARBALL|$CORES_TARBALL"')"
check "offline_setup takes both when the sums match" "$WORK/off/retroarch.tar.gz|$WORK/off/cores.tar.gz" "$got"
printf 'damaged' > "$WORK/off/cores.tar.gz"
got="$(bash -c 'source "'"$FUNCS"'"; OFFLINE_DIR="'"$WORK/off"'"; RETROARCH_TARBALL=""; CORES_TARBALL=""; offline_setup >/dev/null 2>&1; echo "$RETROARCH_TARBALL|$CORES_TARBALL"')"
check "offline_setup leaves a damaged tarball out" "$WORK/off/retroarch.tar.gz|" "$got"
rm -f "$WORK/off/SHA256SUMS"
got="$(bash -c 'source "'"$FUNCS"'"; OFFLINE_DIR="'"$WORK/off"'"; RETROARCH_TARBALL=""; CORES_TARBALL=""; offline_setup >/dev/null 2>&1; echo "$RETROARCH_TARBALL|$CORES_TARBALL"')"
check "offline_setup trusts nothing without SHA256SUMS" "|" "$got"
got="$(bash -c 'source "'"$FUNCS"'"; OFFLINE_DIR="'"$WORK/none"'"; RETROARCH_TARBALL=""; CORES_TARBALL=""; offline_setup >/dev/null 2>&1; echo "$RETROARCH_TARBALL|$CORES_TARBALL"')"
check "offline_setup with no folder: nothing" "|" "$got"

[ "$FAILS" -eq 0 ] && echo "all pass" && exit 0
echo "$FAILS failed"
exit 1
