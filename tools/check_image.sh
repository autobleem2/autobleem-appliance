#!/usr/bin/env bash
# check_image.sh <image.img.xz|image.img> [--arch armhf|arm64] [--sdk N] - read-only check of a built Pi image.
#
# The image must carry everything install.sh would download but the PS1 BIOS and the RetroArch BIOS pack, so
# the first boot needs no network for it (tools/make_rpi_image.sh --preinstall yes --fetch-offline):
#   /opt/autobleem-image/offline/{retroarch.tar.gz,cores.tar.gz,coversU.db,coversP.db,coversJ.db,samples.tar.gz,SHA256SUMS}
#       all present, each matching its SHA256SUMS line;
#   the package (/opt/autobleem-image/autobleem-rpi.tar.gz) with extensions/store, extensions/pscbios,
#       processors/unzip, processors/pe (every Linux package carries both);
#   every extensions/*/bin/<key>/*.so carries 'sdk=N' equal to the launcher's (AB_SDK_ABI: read from the stamp in
#       the package's autobleem-gui; --sdk N when that binary is packed/unreadable - CI passes the autobleem-core
#       pin's number; both given and different is a problem too);
#   /etc/systemd/journald.conf.d/autobleem-persistent.conf.
# One "FAIL: ..." line per problem on stdout, exit 1 when there is any; "OK: ..." and exit 0 otherwise. Exit 2 on
# a usage error or a tool/image that cannot be read. Nothing in the image is changed: debugfs reads (no -w) the
# root partition at the offset sfdisk reports for the partition table's second entry (no parted needed).
set -uo pipefail
PATH="$PATH:/usr/sbin:/sbin"     # debugfs and sfdisk live there, and a plain user's PATH lacks it

usage() { echo "usage: $0 <image.img.xz|image.img> [--arch armhf|arm64] [--sdk N]" >&2; exit 2; }

IMAGE=""; ARCH=""; SDK=""
while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH="${2:-}"; shift 2 || usage ;;
        --sdk)  SDK="${2:-}"; shift 2 || usage ;;
        -h|--help) usage ;;
        -*) usage ;;
        *) [ -z "$IMAGE" ] || usage; IMAGE="$1"; shift ;;
    esac
done
[ -f "$IMAGE" ] || { echo "check_image.sh: no such image: ${IMAGE:-<none>}" >&2; usage; }
if [ -z "$ARCH" ]; then
    case "$(basename "$IMAGE")" in *arm64*) ARCH=arm64 ;; *) ARCH=armhf ;; esac
fi
case "$ARCH" in armhf|arm64) ;; *) echo "check_image.sh: --arch takes armhf or arm64" >&2; usage ;; esac
[ -z "$SDK" ] || [[ "$SDK" =~ ^[0-9]+$ ]] || { echo "check_image.sh: --sdk takes a number" >&2; usage; }
for t in debugfs sfdisk sha256sum tar grep; do
    command -v "$t" >/dev/null 2>&1 || { echo "check_image.sh: missing tool: $t" >&2; exit 2; }
done

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
problems=0
problem() { problems=$((problems + 1)); echo "FAIL: $*"; }

raw="$IMAGE"
case "$IMAGE" in
    *.xz)
        command -v xz >/dev/null 2>&1 || { echo "check_image.sh: missing tool: xz" >&2; exit 2; }
        raw="$work/image.img"
        xz -dc "$IMAGE" >"$raw" || { echo "check_image.sh: cannot decompress $IMAGE" >&2; exit 2; }
        ;;
esac

# the root partition: the partition table's second entry, its start sector times the sector size
dump="$(sfdisk -d "$raw" 2>/dev/null)" || { echo "check_image.sh: no partition table in $IMAGE" >&2; exit 2; }
secsz="$(sed -n 's/^sector-size: *//p' <<<"$dump" | head -1)"; secsz="${secsz:-512}"
start="$(grep -E '^[^ ]*2 *: ' <<<"$dump" | head -1 | sed -n 's/.*start= *\([0-9]*\).*/\1/p')"
[ -n "$start" ] && [ "$start" -gt 0 ] 2>/dev/null || { echo "check_image.sh: no second partition in $IMAGE" >&2; exit 2; }
fs="$raw?offset=$((start * secsz))"

dbg() { debugfs -R "$1" "$fs" 2>/dev/null; }
exists() { dbg "stat $1" | grep -q '^Inode:'; }
dbg_sha() { dbg "cat $1" | sha256sum | cut -d' ' -f1; }
dbg_ok() { exists /; }
dbg_ok || { echo "check_image.sh: cannot read the root filesystem of $IMAGE (offset $((start * secsz)))" >&2; exit 2; }

OFF=/opt/autobleem-image/offline
PKG=/opt/autobleem-image/autobleem-rpi.tar.gz
FILES=(retroarch.tar.gz cores.tar.gz coversU.db coversP.db coversJ.db samples.tar.gz)

# 1. the offline payload against its SHA256SUMS
if ! exists "$OFF/SHA256SUMS"; then
    problem "$OFF/SHA256SUMS is missing"
    sums=""
else
    sums="$(dbg "cat $OFF/SHA256SUMS")"
fi
for f in "${FILES[@]}"; do
    if ! exists "$OFF/$f"; then problem "$OFF/$f is missing"; continue; fi
    want="$(sed -n "s/^\([0-9a-f]\{64\}\)  *\*\{0,1\}$f\$/\1/p" <<<"$sums" | head -1)"
    if [ -z "$want" ]; then problem "$OFF/SHA256SUMS has no line for $f"; continue; fi
    got="$(dbg_sha "$OFF/$f")"
    [ "$got" = "$want" ] || problem "$OFF/$f: sha256 $got does not match SHA256SUMS ($want)"
done

# 2. the package: bundled extensions and processors, the SDK stamps
if ! exists "$PKG"; then
    problem "$PKG is missing"
else
    pkg="$work/pkg.tar.gz"; tree="$work/pkg"; mkdir -p "$tree"
    dbg "cat $PKG" >"$pkg"
    if ! tar -tzf "$pkg" >"$work/pkg.list" 2>/dev/null; then
        problem "$PKG is not a readable tar.gz"
    else
        need=(extensions/store extensions/pscbios processors/unzip processors/pe)
        for d in "${need[@]}"; do
            grep -Eq "(^|/)$d/" "$work/pkg.list" || problem "the package has no $d/"
        done
        tar -xzf "$pkg" -C "$tree" --wildcards '*extensions/*/bin/*' '*bin/autobleem/autobleem-gui' 2>/dev/null || true
        launcher="$(find "$tree" -type f -name autobleem-gui | head -1)"
        abi=""
        if [ -n "$launcher" ]; then
            abi="$(grep -aoE 'sdk=[0-9]+;cxx=' "$launcher" | head -1 | sed 's/^sdk=\([0-9]*\);.*/\1/')"
        fi
        if [ -n "$abi" ] && [ -n "$SDK" ] && [ "$abi" != "$SDK" ]; then
            problem "the launcher's SDK ABI is $abi, --sdk says $SDK"
        fi
        [ -n "$abi" ] || abi="$SDK"
        if [ -z "$abi" ]; then
            problem "no SDK ABI to compare the extensions with (the launcher's stamp is not readable: pass --sdk N)"
        else
            n=0
            while IFS= read -r so; do
                n=$((n + 1))
                rel="${so#"$tree"/}"
                stamp="$(grep -aoE 'sdk=[0-9]+' "$so" | head -1)"
                if [ -z "$stamp" ]; then problem "$rel carries no sdk= stamp"
                elif [ "$stamp" != "sdk=$abi" ]; then problem "$rel carries $stamp, the launcher is sdk=$abi"; fi
            done < <(find "$tree" -type f -path '*extensions/*/bin/*/*' -name '*.so' | sort)
            [ "$n" -gt 0 ] || problem "the package has no extensions/*/bin/<key>/*.so to carry the SDK stamp"
        fi
    fi
fi

# 3. the persistent journal
exists /etc/systemd/journald.conf.d/autobleem-persistent.conf \
    || problem "/etc/systemd/journald.conf.d/autobleem-persistent.conf is missing"

if [ "$problems" -eq 0 ]; then
    echo "OK: $(basename "$IMAGE") ($ARCH) carries the offline payload, the bundled extensions and processors, matching SDK stamps"
    exit 0
fi
exit 1
