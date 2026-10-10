#!/usr/bin/env bash
#
# Build a Raspberry Pi Imager-flashable AutoBleem image: an official Raspberry Pi OS Lite image (armhf or
# arm64) with an AutoBleem package tarball and a first-boot service injected. Raspberry Pi Imager's own OS
# customisation (hostname, user, WiFi, SSH, locale) still works (it replaces the user-data written here), and the
# image's own first-boot mechanism (cloud-init, the user wizard) is left to run - answered by write_first_user_files;
# autobleem-firstboot.service runs after it, on the first or second boot (see
# payload_linux/system/autobleem-firstboot.sh), and installs AutoBleem onto the exFAT data partition install.sh
# creates, exactly as a manual "tar xzf ... && sudo bash install.sh" would.
#
# The pre-install (PLATFORM-23, the owner, 2026-10-07): with proot and qemu-user available (--preinstall auto,
# the default) the image's root is also worked on at build time, so the first boot has far less to do:
#   * the distribution packages install.sh wants (its --print-packages list: SDL2, Mesa, plymouth, RetroArch's
#     libraries, ...) are installed - apt does not run on the first boot;
#   * plymouth with the AutoBleem theme, and the initramfs of every kernel rebuilt with it - the splash shows
#     from the first power-on, not from the second boot;
#   * cmdline.txt/config.txt for a quiet boot with the splash (no kernel log, no rainbow square), and
#     getty@tty1 masked - there is no login prompt on the card's own screen, before or after the first boot;
#   * with --retroarch-tarball/--cores-tarball (or --fetch-offline) RetroArch and its cores are staged inside
#     (/opt/autobleem-image/offline) and install.sh --offline unpacks them: nothing of them is downloaded.
# How: the ext4 root is dumped to a directory with debugfs (no mount, no loop device, no privileges), run under
# proot with qemu-user doing the foreign architecture (no binfmt_misc, no --privileged: tools/rpi_rootfs.py has
# the rest), then packed back with mke2fs -d into a root partition grown to fit. Without proot/qemu (or not as
# root) the build is the old injection-only one, and the first boot does the work as before.
#
# Two ways to edit the image, same result (2026-09-20): --rootless writes the ext4 root with debugfs
# (e2fsprogs) and the FAT boot partition with mcopy (mtools), nothing mounted, no root - what the build
# server runs inside the Docker image; --mount loop-mounts it and needs root (the Pi 400 way, the
# original). Nothing here is Pi-specific or cross-compiles: it is plain image manipulation.
#
#   docker/run.sh tools/make_rpi_image.sh --arch armhf --package dist/rpi/autobleem-rpi.tar.gz \
#       --work build_rpi_image --out build_rpi_image/out            # the server, after ci/build.sh rpi
#   sudo ./tools/make_rpi_image.sh --arch arm64 --package /path/to/autobleem-rpi-arm64.tar.gz   # a Pi
#
# Build the package first (ci/build.sh rpi rpi64 in the Docker image, or on the PC: ./make_rpi.sh &&
# ./tools/make_rpi_package.sh --arch armhf, likewise make_rpi64.sh / --arch arm64) and point --package at
# it. About 7 minutes per image on the 2-core server, most of it xz.
#
# Output: <out>/autobleem-<version>-rpi-<arch>.img.xz (the version is the package's VERSION file, written by
# tools/make_rpi_package.sh from the build's version.h; --version overrides it), plus <out>/rpi_imager_repo.json (a copy of
# tools/rpi_imager_repo.json with this run's size/hash fields, url and icon filled in - what
# autobleem-repo's tools/repo_publish.sh image turns into the site's rpi-imager/os_list.json).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

#*******************************
# defaults
#*******************************
ARCH=""                 # armhf | arm64 (required)
PACKAGE=""               # path to autobleem-rpi(.tar.gz|-arm64.tar.gz) (required)
BASE_IMG=""              # --base: a URL or local .img.xz; default is the architecture's official "latest"
WORK_DIR=""              # --work: scratch space (downloaded/decompressed image, loop mount point)
OUT_DIR=""               # --out: where the finished .img.xz and repo.json land (default: same as WORK_DIR)
MODE=""                  # --mount | --rootless: how the image is edited (default: mount as root, rootless otherwise)
XZ_LEVEL="${AB_XZ_LEVEL:-4}"   # xz preset for the output: 4 took 7 min where 6 took 12 on the server, for ~2% more size
KEEP_RAW=0               # --keep-raw: don't delete the decompressed .img after recompressing
VERSION=""               # --version: what to name the image after; default: the package's VERSION file
REPO_URL="${AB_REPO_URL:-https://autobleem.retromenele.pl}"   # --repo: where autobleem-repo's tools/repo_publish.sh image puts it
PREINSTALL=auto          # --preinstall auto|yes|no: install the packages, the splash and the initramfs into the root (see above)
PROOT_BIN="${AB_PROOT:-}"        # --proot: proot >= 5.5.0 (the packaged 5.4 does not translate statx, which qemu-user 7+ forwards)
QEMU_BIN=""              # --qemu: qemu-arm-static / qemu-aarch64-static (default: the one on PATH)
RA_TARBALL=""            # --retroarch-tarball: RetroArch for this architecture, staged in the image (offline install)
CORES_TARBALL=""         # --cores-tarball: the cores + assets tarball, staged the same way
FETCH_OFFLINE=0          # --fetch-offline: download both from the download repository (--repo), sha256-checked
ROOT_FREE_MIB=300        # --root-free-mib: free space left in the root partition the pre-install makes
PREINSTALLED=0           # 1 once preinstall_root() ran: the boot edits and the offline staging key on it
OFFLINE_FILES=()         # the staged files' local paths, in the order they are written
EXTRA_OFFLINE=()         # "local path:name" of the cover databases and the sample pack (--fetch-offline fills it)
FIRST_USER="autobleem"   # --user: the account the first boot creates (the base image ships none)
FIRST_PASS="autobleem"   # --password: its password (a documented default, like the PC image's)
DRY_RUN=0

#*******************************
# output helpers
#*******************************
log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '    would run: %s\n' "$*"
    else
        "$@"
    fi
}

usage() {
    cat <<'EOF'
Usage: sudo ./tools/make_rpi_image.sh --arch armhf|arm64 --package PATH [options]

  --arch armhf|arm64   which AutoBleem package this is (required)
  --package PATH       the autobleem-rpi(.tar.gz|-arm64.tar.gz) built by tools/make_rpi_package.sh (required)
  --base URL|PATH      the base Raspberry Pi OS Lite image (.img.xz). Default: the architecture's official
                       "latest" Lite image (downloaded fresh, sha256-verified against its published .sha256).
                       A local path is used as-is, not verified.
  --work DIR           scratch directory: download, decompress and loop-mount happen here
                       (default: ./build_rpi_image)
  --out DIR            where the finished .img.xz and repo.json land (default: same as --work)
  --keep-raw           keep the decompressed .img after recompressing (default: deleted to save space)
  --rootless           edit the image without mounting it: debugfs (e2fsprogs) writes the ext4 root, mcopy
                       (mtools) the FAT boot partition - no root, no loop device, works in a container
                       (the build server: docker/run.sh tools/make_rpi_image.sh ...). The default when not
                       root and both tools are there.
  --mount              the loop-mount way (needs root); the default when run with sudo
  --xz-level N         xz preset for the output, 0-9 (default 4, or AB_XZ_LEVEL: 7 min against 12 for 6 on the
                       build server, for about 2% more size)
  --repo URL           the download repository the image will be published to - what the Imager JSON's
                       url and icon fields point at (default: AB_REPO_URL or AutoBleem's; the JSON is
                       laid out as autobleem-repo's tools/repo_publish.sh image puts things: rpi-imager/images/<version>/)
  --version V          name the image autobleem-V-rpi-<arch>.img.xz (default: the VERSION file inside the
                       package, which tools/make_rpi_package.sh writes from the build's version.h)
  --preinstall MODE    auto (default): pre-install the packages, the boot splash and the initramfs when proot and
                       qemu-user are available and this runs as root in --rootless mode; yes: the same, and an
                       error when they are not; no: injection only, the first boot installs everything
  --proot PATH         the proot binary (default: AB_PROOT, else proot on PATH). Needs 5.5.0 or newer
  --qemu PATH          qemu-arm-static (armhf) / qemu-aarch64-static (arm64) (default: the one on PATH)
  --retroarch-tarball FILE   RetroArch for this architecture (the site's rpi/retroarch/ tarball), staged in the
                       image for install.sh --offline
  --cores-tarball FILE the cores + assets tarball (the site's rpi/cores/ tarball), staged the same way
  --fetch-offline      download both from the download repository (--repo), checked against its sha256, plus the
                       cover databases (db/covers{U,P,J}.db) and the sample pack (samples/latest.json); all staged
                       in /opt/autobleem-image/offline with a SHA256SUMS (everything install.sh downloads but BIOS)
  --root-free-mib N    free space left in the pre-install's root partition (default 300; the first boot grows it)
  --user NAME          the account created on the first boot (default autobleem): the base image has no user, and
                       its user wizard would ask for keyboard + user on the screen forever (a plain writer gives it
                       no Imager customisation)
  --password PW        that account's password (default autobleem)
  --dry-run            print what would happen and change nothing (no download, no mount, no root needed)
  -h, --help           this text

Needs root (sudo) for the loop-mount way; the rootless way needs only debugfs and mcopy.
EOF
}

#*******************************
# parse_args
#*******************************
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --arch)     ARCH="${2:?--arch needs armhf or arm64}"; shift 2 ;;
            --package)  PACKAGE="${2:?--package needs a path}"; shift 2 ;;
            --base)     BASE_IMG="${2:?--base needs a URL or path}"; shift 2 ;;
            --work)     WORK_DIR="${2:?--work needs a directory}"; shift 2 ;;
            --out)      OUT_DIR="${2:?--out needs a directory}"; shift 2 ;;
            --mount)    MODE=mount; shift ;;
            --rootless) MODE=rootless; shift ;;
            --xz-level) XZ_LEVEL="${2:?--xz-level needs 0-9}"; shift 2 ;;
            --keep-raw) KEEP_RAW=1; shift ;;
            --version)  VERSION="${2:?--version needs a value}"; shift 2 ;;
            --repo)     REPO_URL="${2:?--repo needs a URL}"; shift 2 ;;
            --user)     FIRST_USER="${2:?--user needs a name}"; shift 2 ;;
            --password) FIRST_PASS="${2:?--password needs a value}"; shift 2 ;;
            --preinstall) PREINSTALL="${2:?--preinstall needs auto, yes or no}"; shift 2 ;;
            --proot)    PROOT_BIN="${2:?--proot needs a path}"; shift 2 ;;
            --qemu)     QEMU_BIN="${2:?--qemu needs a path}"; shift 2 ;;
            --retroarch-tarball) RA_TARBALL="${2:?--retroarch-tarball needs a file}"; shift 2 ;;
            --cores-tarball)     CORES_TARBALL="${2:?--cores-tarball needs a file}"; shift 2 ;;
            --fetch-offline)     FETCH_OFFLINE=1; shift ;;
            --root-free-mib)     ROOT_FREE_MIB="${2:?--root-free-mib needs a number}"; shift 2 ;;
            --dry-run)  DRY_RUN=1; shift ;;
            -h|--help)  usage; exit 0 ;;
            *)          usage; die "unknown option: $1" ;;
        esac
    done
}

#*******************************
# preflight
#*******************************
preflight() {
    case "$ARCH" in
        armhf|arm64) ;;
        "") die "--arch is required (armhf or arm64)" ;;
        *)  die "--arch takes armhf or arm64 (got '$ARCH')" ;;
    esac
    [ -n "$PACKAGE" ] || die "--package is required - the tarball tools/make_rpi_package.sh built"
    [ -f "$PACKAGE" ] || die "no such file: $PACKAGE"

    [ -n "$WORK_DIR" ] || WORK_DIR="$REPO_DIR/build_rpi_image"
    [ -n "$OUT_DIR" ] || OUT_DIR="$WORK_DIR"

    if [ -z "$MODE" ]; then
        if [ "$(id -u)" -eq 0 ]; then
            MODE=mount
        elif command -v debugfs >/dev/null 2>&1 && command -v mcopy >/dev/null 2>&1; then
            MODE=rootless
        elif [ "$DRY_RUN" -eq 0 ]; then
            die "run this with sudo (losetup/mount need root), or install e2fsprogs + mtools for --rootless"
        fi
    fi
    if [ "$MODE" = mount ] && [ "$DRY_RUN" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
        die "--mount needs root (losetup/mount) - sudo, or --rootless"
    fi
    log "Editing the image by: ${MODE:-mount} (--mount / --rootless)"

    # xz/sha256sum/tar/python3 are used even in a dry run (well, would be - the dry-run path skips calling
    # them too, but they're ordinary PATH tools for any user, unlike the mount family below, so checking
    # them always is harmless and catches a genuinely missing tool early either way. losetup/mount/umount/
    # mountpoint/udevadm typically live in /sbin, which is on root's PATH (sudo's secure_path) but not a
    # plain user's - checking for them under a plain --dry-run would fail even though dry-run never calls
    # them, so they're only required for a real run.
    local tool
    for tool in xz sha256sum tar python3; do
        command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
    done
    if [ "$DRY_RUN" -eq 0 ] && [ "$MODE" = mount ]; then
        for tool in losetup udevadm mount umount mountpoint; do
            command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
        done
    elif [ "$DRY_RUN" -eq 0 ]; then
        for tool in debugfs mcopy; do
            command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool (e2fsprogs / mtools, for --rootless)"
        done
    fi
    if [ -z "$BASE_IMG" ] || [[ "$BASE_IMG" == http://* || "$BASE_IMG" == https://* ]]; then
        command -v wget >/dev/null 2>&1 || die "missing required tool: wget (downloading the base image)"
    fi
    [ "$FETCH_OFFLINE" -eq 0 ] || command -v wget >/dev/null 2>&1 || die "missing required tool: wget (--fetch-offline)"
    for tool in "$RA_TARBALL" "$CORES_TARBALL"; do
        [ -z "$tool" ] || [ -f "$tool" ] || die "no such file: $tool"
    done
    decide_preinstall

    log "Architecture: $ARCH"
    log "Package: $PACKAGE"
    if [ -z "$VERSION" ]; then
        # the top-level entry of the tarball is autobleem-rpi/ (tools/make_rpi_package.sh)
        VERSION="$(tar -xzOf "$PACKAGE" autobleem-rpi/VERSION 2>/dev/null | head -1 | tr -d '[:space:]')"
    fi
    if [ -n "$VERSION" ]; then
        log "Version: $VERSION"
    else
        warn "the package has no VERSION file and no --version was given - the image will be named without one"
    fi
    OUT_IMG="$OUT_DIR/autobleem-${VERSION:+$VERSION-}rpi-$ARCH.img.xz"
    log "Work directory: $WORK_DIR"
    log "Output directory: $OUT_DIR"
    run mkdir -p "$WORK_DIR" "$OUT_DIR"

    # Room to work in, checked now rather than found out an hour later: the base image compressed (~0.6 GB)
    # and decompressed (~3.1 GB) sit in the work directory together while the output (~0.7 GB) is written -
    # an 8 GB Pi root with RetroArch's source tree and the apt cache on it ran out at the very last step.
    # On a Pi, --work/--out on the data partition is the natural place.
    if [ "$DRY_RUN" -eq 0 ]; then
        local need_work_mib=5000 need_out_mib=800 free_mib
        if [ "$PREINSTALL" = yes ]; then
            # the root as a directory (~2.6 GB), the grown image (~4 GB), the base image, and the offline files
            # (cores ~0.4-0.8 GB) in the image and the output
            need_work_mib=11000; need_out_mib=2500        # (+ the cover databases ~290 MB, the sample pack)
        fi
        free_mib="$(df -Pm "$WORK_DIR" | awk 'NR == 2 { print $4 }')"
        if [ "$(df -P "$WORK_DIR" | awk 'NR == 2 { print $1 }')" = "$(df -P "$OUT_DIR" | awk 'NR == 2 { print $1 }')" ]; then
            need_work_mib=$((need_work_mib + need_out_mib))
        else
            local free_out_mib
            free_out_mib="$(df -Pm "$OUT_DIR" | awk 'NR == 2 { print $4 }')"
            [ "$free_out_mib" -ge "$need_out_mib" ] \
                || die "only ${free_out_mib} MiB free under $OUT_DIR - the image needs about ${need_out_mib} MiB there (--out elsewhere?)"
        fi
        [ "$free_mib" -ge "$need_work_mib" ] \
            || die "only ${free_mib} MiB free under $WORK_DIR - this needs about ${need_work_mib} MiB (the base image, its
    decompressed copy and the output). --work somewhere roomier, e.g. the data partition on a Pi."
    fi
}

#*******************************
# default_base_url
#*******************************
# Raspberry Pi Foundation's stable "latest" redirect for each architecture's Lite image - verified live
# 2026-09-19 (resolves to a dated raspios_lite_<arch>/images/... .img.xz, each with a same-named .sha256
# sidecar next to it). If this ever stops resolving, pass --base with a direct URL or local file instead.
default_base_url() {
    case "$ARCH" in
        armhf) echo "https://downloads.raspberrypi.com/raspios_lite_armhf_latest" ;;
        arm64) echo "https://downloads.raspberrypi.com/raspios_lite_arm64_latest" ;;
    esac
}

#*******************************
# resolve_base_image
#*******************************
# sets BASE_IMG_XZ to a local, verified (when downloaded) .img.xz path, and BASE_RELEASE_DATE to whatever
# date the file name carries (Raspberry Pi OS image file names are "<YYYY-MM-DD>-raspios-<codename>-<arch>-lite.img.xz").
resolve_base_image() {
    local src="$BASE_IMG"
    [ -n "$src" ] || src="$(default_base_url)"

    if [[ "$src" != http://* && "$src" != https://* ]]; then
        [ -f "$src" ] || die "no such file: $src"
        log "Using local base image: $src (not sha256-verified - only downloaded images are)"
        BASE_IMG_XZ="$src"
        BASE_RELEASE_DATE="$(basename "$src" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)"
        return 0
    fi

    log "Resolving $src"
    local final_url
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '    would resolve the redirect and download the base image + its .sha256\n'
        BASE_IMG_XZ="$WORK_DIR/base-$ARCH.img.xz"
        BASE_RELEASE_DATE="__unknown_in_dry_run__"
        return 0
    fi
    # NOT -q: some wget builds suppress --server-response's header dump under -q too, silently breaking
    # this (found live on the Pi 400's wget 1.25 - -q ate the header lines, final_url came back empty, and
    # the fallback below then downloaded and named the file after the alias URL instead of the real dated
    # one, which made the .sha256 check fail with a filename mismatch: the sidecar names the dated file,
    # not the alias). The extra chatter this prints is captured into a variable, never shown.
    #
    # Two different lines can carry the redirect target, and neither is what an early version of this
    # script assumed (also found live, the hard way): --server-response echoes the raw HTTP header, which
    # can be sent by the server in any case ("  location: <url>", two-space indented, lowercase, on this
    # server) - and wget's own "I'm following this" message is a separate line ("Location: <url>
    # [following]", capitalised, flush left, no indent). Match either, case-insensitively, regardless of
    # leading whitespace; $2 is the URL in both formats since awk's default field splitting ignores
    # leading whitespace anyway.
    final_url="$(wget --max-redirect=5 --server-response "$src" -O /dev/null 2>&1 \
        | awk 'tolower($0) ~ /^[[:space:]]*location:/ {u=$2} END{print u}')"
    # the loop above keeps the last one, which is the final, dated URL we actually want to name the file after
    if [ -z "$final_url" ]; then
        final_url="$src" # not a redirect after all - use it as given
    fi
    local fname
    fname="$(basename "$final_url")"
    BASE_IMG_XZ="$WORK_DIR/$fname"
    BASE_RELEASE_DATE="$(echo "$fname" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)"

    log "Downloading $final_url"
    wget -c -O "$BASE_IMG_XZ" "$final_url" || die "download failed"

    log "Downloading and checking $fname.sha256"
    if wget -q -O "$WORK_DIR/$fname.sha256" "$final_url.sha256"; then
        ( cd "$WORK_DIR" && sha256sum -c "$fname.sha256" ) || die "sha256 mismatch on $fname - re-download or check --base"
        log "sha256 OK"
    else
        warn "no .sha256 published next to $fname - continuing unverified"
    fi
}

#*******************************
# decompress_base_image
#*******************************
decompress_base_image() {
    RAW_IMG="$WORK_DIR/${ARCH}.img"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '    would decompress %s -> %s\n' "$BASE_IMG_XZ" "$RAW_IMG"
        return 0
    fi
    # a WORK_DIR that survives between runs (a persistent host cache, not a fresh temp dir) may already
    # have this exact base decompressed - skip the (otherwise unconditional) re-decompress when RAW_IMG is
    # newer than BASE_IMG_XZ, the same "trust it, don't re-verify" precedent --base already uses for a local
    # compressed file. A freshly (re)downloaded/replaced BASE_IMG_XZ is newer than any old RAW_IMG, so this
    # still decompresses whenever the base actually changed.
    if [ -s "$RAW_IMG" ] && [ "$RAW_IMG" -nt "$BASE_IMG_XZ" ]; then
        log "Reusing the already-decompressed $(basename "$RAW_IMG") (newer than $(basename "$BASE_IMG_XZ"))"
        return 0
    fi
    log "Decompressing $(basename "$BASE_IMG_XZ")"
    rm -f "$RAW_IMG"
    xz -T0 -dk -c "$BASE_IMG_XZ" >"$RAW_IMG"
}

#*******************************
# mount_image / unmount_image
#*******************************
# Both partitions are mounted: the payload goes under /opt on the root filesystem (the FAT boot partition
# is small and shared with the kernel/firmware - see autobleem-main/docs/rpi-image-and-update-plan.md), and the boot
# partition gets two small edits: cmdline.txt loses the word "resize" (see inject_boot_files) and gains
# autobleem.txt (the first-boot options, editable from any PC).
LOOP_DEV=""
ROOT_MNT=""
BOOT_MNT=""

BOOT_OFF=""   # rootless mode: byte offsets of the two partitions inside the raw image
ROOT_OFF=""

# the MBR's partition table, read by hand (16-byte entries at 0x1be: the LBA start is bytes 8-11): no
# sfdisk, no root - a Raspberry Pi OS image is always MBR with the boot partition first and the root second
partition_offsets() {
    python3 - "$RAW_IMG" <<'PY'
import struct, sys
with open(sys.argv[1], "rb") as f:
    f.seek(0x1be)
    table = f.read(64)
starts = [struct.unpack_from("<I", table, i * 16 + 8)[0] * 512 for i in range(2)]
print(starts[0], starts[1])
PY
}

mount_image() {
    if [ "$DRY_RUN" -eq 1 ]; then
        if [ "$MODE" = rootless ]; then
            printf '    would read the partition table of %s and edit its two partitions in place\n' "$RAW_IMG"
        else
            printf '    would losetup -fP %s and mount its root (2nd) partition\n' "$RAW_IMG"
        fi
        return 0
    fi
    if [ "$MODE" = rootless ]; then
        read -r BOOT_OFF ROOT_OFF < <(partition_offsets)
        [ "${ROOT_OFF:-0}" -gt 0 ] || die "no second partition in $RAW_IMG - is this a Raspberry Pi OS image?"
        log "Partitions of $RAW_IMG: boot at $BOOT_OFF, root at $ROOT_OFF (rootless - not mounted)"
        debugfs -R "ls -l /etc" "$RAW_IMG?offset=$ROOT_OFF" >/dev/null 2>&1 \
            || die "debugfs cannot read the root filesystem at offset $ROOT_OFF"
        return 0
    fi
    log "Mounting $RAW_IMG"
    LOOP_DEV="$(losetup -fP --show "$RAW_IMG")"
    udevadm settle
    [ -b "${LOOP_DEV}p2" ] || die "no ${LOOP_DEV}p2 - is this really a Raspberry Pi OS image (boot + root)?"
    ROOT_MNT="$WORK_DIR/root-mnt"
    BOOT_MNT="$WORK_DIR/boot-mnt"
    mkdir -p "$ROOT_MNT" "$BOOT_MNT"
    mount "${LOOP_DEV}p2" "$ROOT_MNT"
    mount "${LOOP_DEV}p1" "$BOOT_MNT"
}

unmount_image() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    [ "$MODE" = rootless ] && return 0
    local m
    for m in "$BOOT_MNT" "$ROOT_MNT"; do
        if [ -n "$m" ] && mountpoint -q "$m" 2>/dev/null; then
            sync
            umount "$m" || warn "umount $m failed"
        fi
    done
    if [ -n "$LOOP_DEV" ]; then
        losetup -d "$LOOP_DEV" 2>/dev/null || warn "losetup -d $LOOP_DEV failed"
    fi
    LOOP_DEV=""
    ROOT_MNT=""
    BOOT_MNT=""
}

# unmount/detach on any exit (success, error, or an interrupted run) so a failed build never leaves a loop
# device or a stray mount behind for the next run to trip over
trap unmount_image EXIT

#*******************************
# decide_preinstall
#*******************************
# --preinstall auto: yes when everything it needs is here, no - with the reason - when not (the build then is
# the old injection-only one and keeps working on a machine without proot/qemu, e.g. CI before its image has them).
decide_preinstall() {
    case "$PREINSTALL" in auto|yes|no) ;; *) die "--preinstall takes auto, yes or no (got '$PREINSTALL')" ;; esac
    [ "$PREINSTALL" != no ] || return 0
    local why=""
    [ -n "$PROOT_BIN" ] || PROOT_BIN="$(command -v proot 2>/dev/null || true)"
    if [ -z "$QEMU_BIN" ]; then
        case "$ARCH" in
            armhf) QEMU_BIN="$(command -v qemu-arm-static 2>/dev/null || true)" ;;
            arm64) QEMU_BIN="$(command -v qemu-aarch64-static 2>/dev/null || true)" ;;
        esac
    fi
    if [ "${MODE:-mount}" != rootless ]; then
        why="it is done in --rootless mode only"
    elif [ "$(id -u)" -ne 0 ]; then
        why="it must run as root (the root's owners are restored from the image - the build container is root)"
    elif [ -z "$PROOT_BIN" ] || [ ! -x "$PROOT_BIN" ]; then
        why="no proot (5.5.0 or newer): --proot PATH or AB_PROOT"
    elif [ -z "$QEMU_BIN" ] || [ ! -x "$QEMU_BIN" ]; then
        why="no qemu-user-static for $ARCH (--qemu PATH)"
    elif ! command -v mke2fs >/dev/null 2>&1; then
        why="no mke2fs (e2fsprogs)"
    fi
    if [ -n "$why" ]; then
        [ "$PREINSTALL" != yes ] || die "--preinstall yes, but $why"
        warn "no pre-install: $why - building the old way (the first boot installs the packages and builds the initramfs)"
        PREINSTALL=no
        return 0
    fi
    PREINSTALL=yes
    log "Pre-install: yes (proot $PROOT_BIN, qemu $QEMU_BIN)"
}

#*******************************
# fetch_offline / prepare_offline
#*******************************
# --fetch-offline: the download repository's newest RetroArch and cores tarballs for this architecture
# (<repo>/rpi/retroarch/latest.json and <repo>/rpi/cores/latest.json - what install.sh reads on a Pi), checked
# against the sha256 they publish, kept in <work>/offline-<arch>/ between runs.
fetch_offline() {
    [ "$FETCH_OFFLINE" -eq 1 ] || return 0
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '    would download the RetroArch and cores tarballs for %s from %s\n' "$ARCH" "$REPO_URL"
        printf '    would download the cover databases (coversU.db coversP.db coversJ.db) and the sample pack (samples/latest.json) from %s\n' "$REPO_URL"
        return 0
    fi
    local dir="$WORK_DIR/offline-$ARCH" what url sha dest
    mkdir -p "$dir"
    for what in retroarch cores; do
        dest="$dir/$what.tar.gz"
        if [ "$what" = retroarch ] && [ -n "$RA_TARBALL" ]; then continue; fi
        if [ "$what" = cores ] && [ -n "$CORES_TARBALL" ]; then continue; fi
        log "Offline: asking $REPO_URL for the $what tarball of $ARCH"
        wget -q -O "$dir/$what-latest.json" "$REPO_URL/rpi/$what/latest.json" \
            || die "cannot reach $REPO_URL/rpi/$what/latest.json (--fetch-offline)"
        read -r url sha < <(python3 - "$dir/$what-latest.json" "$ARCH" <<'PY'
import json, sys
a = json.load(open(sys.argv[1])).get(sys.argv[2]) or {}
print(a.get("url", ""), a.get("sha256", ""))
PY
        )
        [ -n "$url" ] && [ -n "$sha" ] || die "$REPO_URL has no $what tarball for $ARCH"
        if [ -f "$dest" ] && [ "$(sha256sum "$dest" | cut -d' ' -f1)" = "$sha" ]; then
            log "Offline: $what tarball already in $dir"
        else
            log "Offline: downloading $url"
            wget -nv -O "$dest.part" "$url" || die "download of $url failed"
            [ "$(sha256sum "$dest.part" | cut -d' ' -f1)" = "$sha" ] || die "sha256 mismatch on $url"
            mv -f "$dest.part" "$dest"
        fi
        if [ "$what" = retroarch ]; then RA_TARBALL="$dest"; else CORES_TARBALL="$dest"; fi
    done
    fetch_offline_extras "$dir"
}

# the cover databases (db/<name> + db/<name>.sha256) and the sample pack (samples/latest.json -> url + sha256),
# the rest of what install.sh downloads (but the BIOS files); same cache dir, sha256-checked
fetch_offline_extras() {
    local dir="$1" name sha dest url
    EXTRA_OFFLINE=()
    for name in coversU.db coversP.db coversJ.db; do
        dest="$dir/$name"
        wget -q -O "$dir/$name.sha256" "$REPO_URL/db/$name.sha256" || die "cannot reach $REPO_URL/db/$name.sha256 (--fetch-offline)"
        sha="$(cut -d' ' -f1 <"$dir/$name.sha256")"
        [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "$REPO_URL/db/$name.sha256 holds no sha256"
        if [ -f "$dest" ] && [ "$(sha256sum "$dest" | cut -d' ' -f1)" = "$sha" ]; then
            log "Offline: $name already in $dir"
        else
            log "Offline: downloading $REPO_URL/db/$name"
            wget -nv -O "$dest.part" "$REPO_URL/db/$name" || die "download of $REPO_URL/db/$name failed"
            [ "$(sha256sum "$dest.part" | cut -d' ' -f1)" = "$sha" ] || die "sha256 mismatch on $REPO_URL/db/$name"
            mv -f "$dest.part" "$dest"
        fi
        EXTRA_OFFLINE+=("$dest:$name")
    done
    dest="$dir/samples.tar.gz"
    wget -q -O "$dir/samples-latest.json" "$REPO_URL/samples/latest.json" || die "cannot reach $REPO_URL/samples/latest.json (--fetch-offline)"
    read -r url sha < <(python3 - "$dir/samples-latest.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("url", ""), d.get("sha256", ""))
PY
    )
    [ -n "$url" ] && [ -n "$sha" ] || die "$REPO_URL has no sample pack"
    if [ -f "$dest" ] && [ "$(sha256sum "$dest" | cut -d' ' -f1)" = "$sha" ]; then
        log "Offline: samples.tar.gz already in $dir"
    else
        log "Offline: downloading $url"
        wget -nv -O "$dest.part" "$url" || die "download of $url failed"
        [ "$(sha256sum "$dest.part" | cut -d' ' -f1)" = "$sha" ] || die "sha256 mismatch on $url"
        mv -f "$dest.part" "$dest"
    fi
    EXTRA_OFFLINE+=("$dest:samples.tar.gz")
}

# OFFLINE_FILES = "local path:name in the image" for each staged tarball, and OFFLINE_SUMS = the SHA256SUMS the
# image carries beside them (install.sh --offline checks each file against it before it trusts it)
prepare_offline() {
    OFFLINE_FILES=()
    OFFLINE_SUMS=""
    [ -n "$RA_TARBALL" ] || [ -n "$CORES_TARBALL" ] || [ ${#EXTRA_OFFLINE[@]} -gt 0 ] || [ "$FETCH_OFFLINE" -eq 1 ] || return 0
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '    would stage the RetroArch / cores tarballs in /opt/autobleem-image/offline\n'
        if [ "$FETCH_OFFLINE" -eq 1 ]; then
            printf '    would stage coversU.db coversP.db coversJ.db samples.tar.gz in /opt/autobleem-image/offline (+ SHA256SUMS)\n'
        fi
        return 0
    fi
    if [ "$PREINSTALL" != yes ]; then
        warn "the offline tarballs need the pre-install's grown root (a stock root has no room for them) - not staged"
        return 0
    fi
    OFFLINE_SUMS="$WORK_DIR/offline-SHA256SUMS"
    : >"$OFFLINE_SUMS"
    local pair
    for pair in "$RA_TARBALL:retroarch.tar.gz" "$CORES_TARBALL:cores.tar.gz" "${EXTRA_OFFLINE[@]+"${EXTRA_OFFLINE[@]}"}"; do
        [ -n "${pair%%:*}" ] || continue
        OFFLINE_FILES+=("$pair")
        printf '%s  %s\n' "$(sha256sum "${pair%%:*}" | cut -d' ' -f1)" "${pair#*:}" >>"$OFFLINE_SUMS"
    done
    log "Offline payload: $(cat "$OFFLINE_SUMS" | wc -l) file(s) staged in the image, $(du -ch "${OFFLINE_FILES[@]%%:*}" | tail -1 | cut -f1)"
}

#*******************************
# preinstall_root
#*******************************
ROOTFS=""
OFFLINE_SUMS=""

# run a command in the image's root, as (fake) root, with qemu-user doing the foreign architecture. proot
# 5.5.0+ translates every path syscall (statx included); nothing here needs binfmt_misc or privileges.
chroot_run() {
    env DEBIAN_FRONTEND=noninteractive LC_ALL=C LANG=C HOME=/root \
        "$PROOT_BIN" -0 -r "$ROOTFS" -q "$QEMU_BIN" -b /proc -b /sys -b /dev -w / "$@"
}

preinstall_root() {
    [ "$PREINSTALL" = yes ] || return 0
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '    would dump the root to a directory, install the packages + plymouth theme + initramfs under proot/qemu, and pack it back\n'
        return 0
    fi
    local t0=$SECONDS t
    ROOTFS="$WORK_DIR/rootfs-$ARCH"

    log "Pre-install 1/6: dumping the root filesystem to a directory"
    rm -rf "$ROOTFS"
    mkdir -p "$ROOTFS"
    debugfs -R "rdump / $ROOTFS" "$RAW_IMG?offset=$ROOT_OFF" 2>&1 | grep -v '^debugfs 1\.' || true
    [ -x "$ROOTFS/usr/bin/dpkg" ] || die "the root of $RAW_IMG could not be dumped to $ROOTFS"
    rm -rf "$ROOTFS/lost+found"
    # rdump drops the setuid/setgid/sticky bits and hard links: put them back from the image's own inodes
    python3 "$SCRIPT_DIR/rpi_rootfs.py" fixmodes "$RAW_IMG" "$ROOT_OFF" "$ROOTFS" || die "restoring the modes failed"
    # the firmware partition's files where the kernel hooks expect them (update-initramfs copies the new
    # initramfs there); they go back to the FAT partition after
    mkdir -p "$ROOTFS/boot/firmware"
    mcopy -s -n -i "$RAW_IMG@@$BOOT_OFF" '::*' "$ROOTFS/boot/firmware/" || die "reading the boot partition failed"

    log "Pre-install 2/6: preparing the chroot"
    # DNS: the container's. (the image's resolv.conf is NetworkManager's, a link that points nowhere here)
    [ -e "$ROOTFS/etc/resolv.conf" ] || [ -L "$ROOTFS/etc/resolv.conf" ] && mv "$ROOTFS/etc/resolv.conf" "$ROOTFS/etc/resolv.conf.ab-orig"
    cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
    # apt's _apt sandbox needs real uid changes, which proot only pretends; no service may start in a chroot;
    # mkinitramfs finds no root device to size the module set for (MODULES=dep fails), so it takes all modules
    # for this build only; and the initramfs is built once at the end, not by every package's postinst
    printf 'APT::Sandbox::User "root";\n' >"$ROOTFS/etc/apt/apt.conf.d/99ab-chroot"
    printf '#!/bin/sh\nexit 101\n' >"$ROOTFS/usr/sbin/policy-rc.d"
    chmod 0755 "$ROOTFS/usr/sbin/policy-rc.d"
    printf 'MODULES=most\n' >"$ROOTFS/etc/initramfs-tools/conf.d/99ab-chroot"
    sed -i 's/^update_initramfs=.*/update_initramfs=no/' "$ROOTFS/etc/initramfs-tools/update-initramfs.conf"
    # a proot that cannot translate statx (5.4.x) sees the CONTAINER's files for every stat: refuse it now
    chroot_run /usr/bin/stat -c %n /usr/bin/dpkg >/dev/null 2>&1 \
        || die "proot/qemu cannot run the image's root (stat of /usr/bin/dpkg failed) - proot 5.5.0 or newer is needed ($PROOT_BIN)"

    log "Pre-install 3/6: apt-get update"
    t=$SECONDS
    chroot_run apt-get update >"$WORK_DIR/preinstall-apt-update.log" 2>&1 \
        || { tail -20 "$WORK_DIR/preinstall-apt-update.log"; die "apt-get update failed inside the image's root (no network?)"; }
    log "  $((SECONDS - t)) s"

    log "Pre-install 4/6: installing the packages install.sh wants"
    t=$SECONDS
    local stagedir="$ROOTFS/tmp/ab-install" pkgs
    mkdir -p "$stagedir"
    install -m 0755 "$REPO_DIR/payload_linux/install.sh" "$stagedir/install.sh"
    [ -z "$RA_TARBALL" ] || cp "$RA_TARBALL" "$stagedir/retroarch.tar.gz"
    pkgs="$(chroot_run bash /tmp/ab-install/install.sh --platform rpi --print-packages \
                ${RA_TARBALL:+--retroarch-tarball /tmp/ab-install/retroarch.tar.gz} 2>/dev/null \
            | grep -E '^[a-z0-9][a-z0-9+.:-]+$' | sort -u | tr '\n' ' ')"
    [ "$(wc -w <<<"$pkgs")" -ge 12 ] || die "install.sh --print-packages gave a short list inside the root: '$pkgs'"
    log "  $(wc -w <<<"$pkgs") named packages: $pkgs"
    [ -n "$RA_TARBALL" ] || warn "no --retroarch-tarball: RetroArch's libraries are not pre-installed (the first boot installs them)"
    # shellcheck disable=SC2086
    chroot_run apt-get install -y -o Dpkg::Options::=--force-unsafe-io -o Dpkg::Options::=--force-confold $pkgs \
        >"$WORK_DIR/preinstall-apt-install.log" 2>&1 \
        || { tail -40 "$WORK_DIR/preinstall-apt-install.log"; die "apt-get install failed inside the image's root"; }
    log "  $(grep -c '^Setting up ' "$WORK_DIR/preinstall-apt-install.log") packages configured in $((SECONDS - t)) s (log: $WORK_DIR/preinstall-apt-install.log)"

    log "Pre-install 5/6: the plymouth theme and the initramfs of every kernel"
    t=$SECONDS
    install -d -m 0755 "$ROOTFS/usr/share/plymouth/themes/autobleem"
    install -m 0644 "$REPO_DIR/payload_linux/system/plymouth/autobleem.plymouth" \
        "$REPO_DIR/payload_linux/system/plymouth/autobleem.script" \
        "$REPO_DIR/payload_linux/system/plymouth/splash.png" "$ROOTFS/usr/share/plymouth/themes/autobleem/"
    chroot_run plymouth-set-default-theme autobleem || die "plymouth-set-default-theme failed inside the image's root"
    sed -i 's/^update_initramfs=.*/update_initramfs=yes/' "$ROOTFS/etc/initramfs-tools/update-initramfs.conf"
    # one update-initramfs per kernel (the image carries one per board family - v6, v7, v8, 2712 - and a card
    # gets moved between boards), side by side: emulated, each takes minutes
    local kv kernels=() pids=() i
    for kv in "$ROOTFS"/lib/modules/*/; do
        kv="$(basename "$kv")"
        [ -f "$ROOTFS/boot/initrd.img-$kv" ] && kernels+=("$kv")
    done
    [ ${#kernels[@]} -gt 0 ] || die "no kernel with an initramfs in the image's root"
    for kv in "${kernels[@]}"; do
        chroot_run update-initramfs -u -k "$kv" >"$WORK_DIR/preinstall-initramfs-$kv.log" 2>&1 &
        pids+=($!)
    done
    for i in "${!pids[@]}"; do
        wait "${pids[$i]}" || { tail -20 "$WORK_DIR/preinstall-initramfs-${kernels[$i]}.log"; die "update-initramfs failed for ${kernels[$i]}"; }
    done
    grep -q '^Theme=autobleem' "$ROOTFS/etc/plymouth/plymouthd.conf" || die "the plymouth theme is not selected"
    log "  ${#kernels[@]} initramfs rebuilt in $((SECONDS - t)) s: ${kernels[*]}"
    # the new initramfs files go back onto the FAT partition (where the firmware loads them from)
    local f n=0
    for f in "$ROOTFS"/boot/firmware/initramfs*; do
        [ -f "$f" ] || continue
        mcopy -o -i "$RAW_IMG@@$BOOT_OFF" "$f" "::$(basename "$f")" || die "writing $(basename "$f") to the boot partition failed"
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] || die "update-initramfs left no initramfs on the boot partition"

    log "Pre-install 6/6: tidying the root and packing it back"
    rm -f "$ROOTFS/etc/apt/apt.conf.d/99ab-chroot" "$ROOTFS/usr/sbin/policy-rc.d" \
          "$ROOTFS/etc/initramfs-tools/conf.d/99ab-chroot" "$ROOTFS/etc/resolv.conf"
    [ ! -e "$ROOTFS/etc/resolv.conf.ab-orig" ] && [ ! -L "$ROOTFS/etc/resolv.conf.ab-orig" ] \
        || mv "$ROOTFS/etc/resolv.conf.ab-orig" "$ROOTFS/etc/resolv.conf"
    rm -rf "$ROOTFS/tmp/ab-install" "$ROOTFS/var/cache/apt/archives"/*.deb "$ROOTFS/var/cache/apt"/*.bin
    rm -rf "$ROOTFS/boot/firmware"
    mkdir -p "$ROOTFS/boot/firmware" "$ROOTFS/etc/autobleem"
    { printf 'pre-installed %s by tools/make_rpi_image.sh (%s)\n' "$(date -u +%FT%TZ)" "$ARCH"; printf '%s\n' $pkgs; } \
        >"$ROOTFS/etc/autobleem/image-preinstalled"
    pack_root
    rm -rf "$ROOTFS"
    PREINSTALLED=1
    log "Pre-install done in $((SECONDS - t0)) s"
}

# the directory back into the image: a new ext4 root, the same label and UUID and the features the base image's
# has, as large as it needs plus room (the offline files, the package, ROOT_FREE_MIB), written at the root
# partition's offset after the old root's bytes are dropped (never leave them in the new one's free space: the
# image compresses with them as noise); the MBR's second entry gets the new size
pack_root() {
    local used_kib extra_mib fs_mib uuid label stats pair
    stats="$(debugfs -R stats "$RAW_IMG?offset=$ROOT_OFF" 2>/dev/null)"
    uuid="$(sed -n 's/^Filesystem UUID: *//p' <<<"$stats" | head -1)"
    label="$(sed -n 's/^Filesystem volume name: *//p' <<<"$stats" | head -1)"
    [ -n "$uuid" ] || die "cannot read the root filesystem's UUID from $RAW_IMG"
    [ "$label" != "<none>" ] || label=rootfs
    used_kib="$(du -sk "$ROOTFS" | cut -f1)"
    extra_mib=$(( ($(stat -c %s "$PACKAGE") / 1048576) + 80 ))      # the package, the first-boot files
    for pair in "${OFFLINE_FILES[@]+"${OFFLINE_FILES[@]}"}"; do
        extra_mib=$((extra_mib + $(stat -c %s "${pair%%:*}") / 1048576 + 1))
    done
    fs_mib=$(( used_kib / 1024 * 108 / 100 + 160 + extra_mib + ROOT_FREE_MIB ))
    log "  the root: ${used_kib} KiB used, +${extra_mib} MiB to inject, ${ROOT_FREE_MIB} MiB free -> a ${fs_mib} MiB partition"
    truncate -s "$ROOT_OFF" "$RAW_IMG"
    truncate -s $((ROOT_OFF + fs_mib * 1048576)) "$RAW_IMG"
    # the base image's features (no 64bit, no huge_file) so the Pi's kernel and e2fsprogs treat it as before
    mke2fs -q -F -t ext4 -O ^64bit,^huge_file -L "$label" -U "$uuid" -E "root_owner=0:0,offset=$ROOT_OFF" \
        -d "$ROOTFS" "$RAW_IMG" "${fs_mib}M" || die "mke2fs -d failed packing the root"
    python3 "$SCRIPT_DIR/rpi_rootfs.py" mbr-resize "$RAW_IMG" 2 $((fs_mib * 2048)) || die "resizing the root partition entry failed"
    e2fsck -fn "$RAW_IMG?offset=$ROOT_OFF" >"$WORK_DIR/preinstall-e2fsck.log" 2>&1 \
        || { tail -20 "$WORK_DIR/preinstall-e2fsck.log"; die "the packed root does not pass e2fsck"; }
    stats="$(debugfs -R stats "$RAW_IMG?offset=$ROOT_OFF" 2>/dev/null)"
    log "  packed root: $(sed -n 's/^Free blocks: *//p' <<<"$stats" | head -1) free 4K blocks of $(sed -n 's/^Block count: *//p' <<<"$stats" | head -1), e2fsck clean"
}

#*******************************
# inject_payload
#*******************************
inject_payload() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '    would copy %s and the firstboot service/script into the image, and enable the service\n' "$PACKAGE"
        printf '    would write /etc/systemd/journald.conf.d/autobleem-persistent.conf (Storage=persistent) and create /var/log/journal\n'
        return 0
    fi
    log "Injecting the AutoBleem package and first-boot service"
    if [ "$MODE" = rootless ]; then
        inject_payload_rootless
        return 0
    fi
    local image_dir="$ROOT_MNT/opt/autobleem-image"
    mkdir -p "$image_dir"
    cp "$PACKAGE" "$image_dir/autobleem-rpi.tar.gz"
    if [ ${#OFFLINE_FILES[@]} -gt 0 ]; then
        mkdir -p "$image_dir/offline"
        local pair
        for pair in "${OFFLINE_FILES[@]}"; do cp "${pair%%:*}" "$image_dir/offline/${pair#*:}"; done
        cp "$OFFLINE_SUMS" "$image_dir/offline/SHA256SUMS"
    fi
    install -m 0755 "$REPO_DIR/payload_linux/system/autobleem-firstboot.sh" "$image_dir/autobleem-firstboot.sh"
    # the first boot's screen: the installer's output as a logo, two bars and a box (see the script)
    install -m 0644 "$REPO_DIR/payload_linux/system/autobleem-install-ui.py" "$image_dir/autobleem-install-ui.py"
    mkdir -p "$image_dir/install-ui"
    cp -r "$REPO_DIR/payload_linux/system/install-ui/." "$image_dir/install-ui/"
    chmod -R u=rwX,go=rX "$image_dir/install-ui"
    install -m 0644 "$REPO_DIR/payload_linux/system/autobleem-firstboot.service" \
        "$ROOT_MNT/etc/systemd/system/autobleem-firstboot.service"

    # "systemctl enable" for a plain WantedBy=multi-user.target unit is just this symlink - done by hand
    # rather than chrooting to run systemctl itself, which is exactly the "no qemu/chroot" simplification
    # injection-only buys: this works identically for an armhf image built on an aarch64 host or vice versa,
    # because nothing from the image is ever executed at build time.
    mkdir -p "$ROOT_MNT/etc/systemd/system/multi-user.target.wants"
    ln -sf ../autobleem-firstboot.service \
        "$ROOT_MNT/etc/systemd/system/multi-user.target.wants/autobleem-firstboot.service"
    # ssh on from the first boot (the owner's rule, 2026-09-20): the launcher owns tty1 and the keyboard
    # once installed, so there is no console to enable it from afterwards. The same symlink "systemctl
    # enable ssh" makes; the host keys are made by Raspberry Pi OS's own regenerate_ssh_host_keys.service.
    ln -sf /lib/systemd/system/ssh.service "$ROOT_MNT/etc/systemd/system/multi-user.target.wants/ssh.service"
    # no login prompt on tty1, before or after the first boot: the launcher owns that screen, and a first boot that
    # failed keeps its message on tty8 (autobleem-firstboot.sh) - tty2..6 still have a login (Alt+F2)
    ln -sf /dev/null "$ROOT_MNT/etc/systemd/system/getty@tty1.service"
    # the user wizard is masked: write_first_user_files makes the account with cloud-init, and the wizard would only
    # rename it to itself and restart for ever ("usermod: no changes")
    ln -sf /dev/null "$ROOT_MNT/etc/systemd/system/userconfig.service"
    mkdir -p "$ROOT_MNT/etc/systemd/system/userconfig.service.d"
    install -m 0644 "$REPO_DIR/payload_linux/system/autobleem-userconfig.conf" \
        "$ROOT_MNT/etc/systemd/system/userconfig.service.d/autobleem.conf"
    # persistent journal from the very first boot (PLATFORM-23: the first boot of 2026-10-09 could not be analysed,
    # its journal lived in RAM and was gone); /var/log/journal has to exist for Storage=persistent to take
    # effect before the first flush
    install -D -m 0644 "$REPO_DIR/payload_linux/system/autobleem-journald.conf" \
        "$ROOT_MNT/etc/systemd/journald.conf.d/autobleem-persistent.conf"
    install -d -m 0755 -o root -g root "$ROOT_MNT/var/log/journal"
}

# the same five writes through debugfs, on the unmounted root filesystem. `write` gives the new file the
# local file's uid/gid/mode - ours, not root's - so every one is set explicitly (mode is the full st_mode).
inject_payload_rootless() {
    local fs="$RAW_IMG?offset=$ROOT_OFF" want got
    # (the banner, "Allocated inode" chatter and "already exists" on a mkdir of a directory the base image
    # has are noise; anything else debugfs says is shown)
    dfs() {
        debugfs -w -R "$1" "$fs" 2>&1 \
            | grep -vE '^debugfs 1\.|^Allocated inode|directory already exists|^$' || true
    }
    put() { # put LOCAL IMAGEPATH MODE
        dfs "rm $2" >/dev/null   # a rerun over the same raw image would fail on an existing file
        dfs "write $1 $2"
        dfs "sif $2 uid 0"
        dfs "sif $2 gid 0"
        dfs "sif $2 mode $3"
    }
    dfs "mkdir /opt/autobleem-image"
    put "$PACKAGE" /opt/autobleem-image/autobleem-rpi.tar.gz 0100644
    put "$REPO_DIR/payload_linux/system/autobleem-firstboot.sh" /opt/autobleem-image/autobleem-firstboot.sh 0100755
    put "$REPO_DIR/payload_linux/system/autobleem-install-ui.py" /opt/autobleem-image/autobleem-install-ui.py 0100644
    # the screen's logos and fonts (payload_linux/system/install-ui/, one level of fonts/ below it)
    dfs "mkdir /opt/autobleem-image/install-ui"
    dfs "mkdir /opt/autobleem-image/install-ui/fonts"
    local ui_dir="$REPO_DIR/payload_linux/system/install-ui" ui_file
    for ui_file in "$ui_dir"/*.png "$ui_dir"/fonts/*; do
        put "$ui_file" "/opt/autobleem-image/install-ui/${ui_file#"$ui_dir"/}" 0100644
    done
    put "$REPO_DIR/payload_linux/system/autobleem-firstboot.service" /etc/systemd/system/autobleem-firstboot.service 0100644
    dfs "mkdir /etc/systemd/system/multi-user.target.wants"
    dfs "rm /etc/systemd/system/multi-user.target.wants/autobleem-firstboot.service" >/dev/null
    dfs "symlink /etc/systemd/system/multi-user.target.wants/autobleem-firstboot.service ../autobleem-firstboot.service"
    # ssh enabled (see inject_payload)
    dfs "rm /etc/systemd/system/multi-user.target.wants/ssh.service" >/dev/null
    dfs "symlink /etc/systemd/system/multi-user.target.wants/ssh.service /lib/systemd/system/ssh.service"
    # no login prompt on tty1 (see inject_payload), and the user-creation wizard waits for the splash to be gone
    dfs "rm /etc/systemd/system/getty@tty1.service" >/dev/null
    dfs "symlink /etc/systemd/system/getty@tty1.service /dev/null"
    dfs "rm /etc/systemd/system/userconfig.service" >/dev/null
    dfs "symlink /etc/systemd/system/userconfig.service /dev/null"
    dfs "mkdir /etc/systemd/system/userconfig.service.d"
    put "$REPO_DIR/payload_linux/system/autobleem-userconfig.conf" /etc/systemd/system/userconfig.service.d/autobleem.conf 0100644
    # persistent journal from the first boot (see inject_payload)
    dfs "mkdir /etc/systemd/journald.conf.d"
    put "$REPO_DIR/payload_linux/system/autobleem-journald.conf" /etc/systemd/journald.conf.d/autobleem-persistent.conf 0100644
    dfs "mkdir /var/log/journal"
    dfs "sif /var/log/journal uid 0"
    dfs "sif /var/log/journal gid 0"
    dfs "sif /var/log/journal mode 040755"
    # RetroArch and the cores, for install.sh --offline (only on a pre-installed image: its root has the room)
    if [ ${#OFFLINE_FILES[@]} -gt 0 ]; then
        dfs "mkdir /opt/autobleem-image/offline"
        local pair
        for pair in "${OFFLINE_FILES[@]}"; do
            put "${pair%%:*}" "/opt/autobleem-image/offline/${pair#*:}" 0100644
        done
        put "$OFFLINE_SUMS" /opt/autobleem-image/offline/SHA256SUMS 0100644
        for pair in "${OFFLINE_FILES[@]}"; do
            want="$(stat -c %s "${pair%%:*}")"
            got="$(debugfs -R "stat /opt/autobleem-image/offline/${pair#*:}" "$fs" 2>/dev/null | sed -n 's/.*Size: \([0-9]*\).*/\1/p' | head -1)"
            [ "$want" = "$got" ] || die "${pair#*:} inside the image is $got bytes, the file is $want"
        done
    fi
    # what went in, as the image will see it
    debugfs -R "ls -l /opt/autobleem-image" "$fs" 2>/dev/null | grep -v '^debugfs' | sed 's/^/    /'
    debugfs -R "ls -l /etc/systemd/system/multi-user.target.wants" "$fs" 2>/dev/null | grep -E 'autobleem|ssh' | sed 's/^/    /'
    # every file went in whole
    want="$(stat -c %s "$PACKAGE")"
    got="$(debugfs -R "stat /opt/autobleem-image/autobleem-rpi.tar.gz" "$fs" 2>/dev/null | sed -n 's/.*Size: \([0-9]*\).*/\1/p' | head -1)"
    [ "$want" = "$got" ] || die "the package inside the image is $got bytes, the file is $want"
}

#*******************************
# write_first_user_files
#*******************************
# The base image has no user (uid 1000) and its user wizard (userconfig.service -> userconf-pi, on tty8) asks for a
# keyboard and a user on the screen, and with no uid 1000 to rename it loops on "Which user would you like to rename"
# forever (the owner's Pi 400, 2026-10-09; a card written with a plain writer has no Imager customisation to avoid
# it). Answering it with a userconf.txt does not work either: cloud-init has created the account by then, the wizard
# "renames" it to the same name and `usermod: no changes` makes the service fail and restart for ever (same day).
# So the image creates the user itself with cloud-init (user-data: the account with sudo, the keyboard, the locale)
# and masks the wizard (inject_payload). Raspberry Pi Imager's customisation, when used, replaces user-data as it
# always did, and needs no wizard either. $1 = the directory.
write_first_user_files() {
    local dir="$1" hash
    printf '%s' "$FIRST_USER" | grep -Eq '^[a-z][a-z0-9-]{0,31}$' \
        || die "--user '$FIRST_USER' is not a valid account name (lower-case letters, digits, hyphens; starts with a letter)"
    [ "$FIRST_USER" != root ] || die "--user cannot be root"
    [ -n "$FIRST_PASS" ] || die "--password cannot be empty"
    command -v openssl >/dev/null 2>&1 || die "missing required tool: openssl (the password hash)"
    hash="$(openssl passwd -6 -salt "$(openssl rand -hex 8)" "$FIRST_PASS")" || die "openssl passwd failed"
    cat >"$dir/user-data" <<UDEOF
#cloud-config
# Written by tools/make_rpi_image.sh: the first user, the keyboard and the locale, so the first boot asks nothing.
# Change the password after the first login (passwd). A Raspberry Pi Imager customisation replaces this file.
users:
  - name: $FIRST_USER
    gecos: AutoBleem
    groups: [adm, dialout, cdrom, audio, users, sudo, video, games, plugdev, input, gpio, spi, i2c, netdev, render, lpadmin]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: $hash
ssh_pwauth: true
keyboard:
  model: pc105
  layout: gb
locale: en_GB.UTF-8
UDEOF
}

#*******************************
# inject_boot_files
#*******************************
# Two edits on the FAT boot partition. cmdline.txt loses the word "resize": that is what the base image's
# initramfs keys on to grow the root partition over the whole card on the first boot
# (/usr/share/initramfs-tools/scripts/local-premount/resize_early, and set_partuuid next to it), and a
# root that fills the card leaves install.sh no room for the exFAT data partition - instead install.sh
# grows the root to a bounded size itself (--grow-root, from autobleem.txt's root_gib) and takes the rest.
# Plus the first user (write_first_user_files: user-data). network-config/meta-data stay as the base
# image ships them; Raspberry Pi Imager's OS customisation, when used, still replaces user-data.
inject_boot_files() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '    would drop "resize" from cmdline.txt and add autobleem.txt + ssh + user-data on the boot partition\n'
        return 0
    fi
    if [ "$PREINSTALLED" -eq 1 ]; then
        log "Editing the boot partition: cmdline.txt without 'resize' and with the quiet splash boot, config.txt without the rainbow square, plus autobleem.txt and ssh"
    else
        log "Editing the boot partition: cmdline.txt without 'resize', plus autobleem.txt and ssh"
    fi
    local cmdline kept="" word
    if [ "$MODE" = rootless ]; then
        # mtools reads and writes the FAT partition in place: <image>@@<byte offset>
        cmdline="$WORK_DIR/cmdline.txt"
        mcopy -o -i "$RAW_IMG@@$BOOT_OFF" ::cmdline.txt "$cmdline" \
            || die "no cmdline.txt on the boot partition - not a Raspberry Pi OS image?"
    else
        cmdline="$BOOT_MNT/cmdline.txt"
        [ -f "$cmdline" ] || die "no cmdline.txt on the boot partition - not a Raspberry Pi OS image?"
    fi
    for word in $(tr -d '\n' <"$cmdline"); do
        [ "$word" = resize ] && continue
        kept="$kept${kept:+ }$word"
    done
    if [ "$PREINSTALLED" -eq 1 ]; then
        # the words install.sh's boot_cmdline_words / configure_boot_rpi set at the end of the first boot, here from
        # the first power-on (the splash is in the initramfs): no console blanking, no kernel log, no cursor, the
        # splash, and the 1080p mode the launcher draws its 1280x720 UI at 1.5x in (plymouth and the launcher then
        # share one mode - no re-sync of the TV). install.sh keeps what is there and --hdmi-mode still replaces video=
        for word in consoleblank=0 quiet loglevel=3 logo.nologo vt.global_cursor_default=0 splash \
                    plymouth.ignore-serial-consoles video=HDMI-A-1:1920x1080@60 video=HDMI-A-2:1920x1080@60; do
            case " $kept " in
                *" ${word%%=*}="*|*" $word "*) ;;
                *) kept="$kept $word" ;;
            esac
        done
    fi
    printf '%s\n' "$kept" >"$cmdline"
    if [ "$MODE" = rootless ]; then
        mcopy -o -i "$RAW_IMG@@$BOOT_OFF" "$cmdline" ::cmdline.txt || die "writing cmdline.txt failed"
        mcopy -o -i "$RAW_IMG@@$BOOT_OFF" "$REPO_DIR/payload_linux/system/autobleem.txt" ::autobleem.txt \
            || die "writing autobleem.txt failed"
        # the official "enable ssh" marker too (sshswitch.service turns it into enable --now and removes it)
        : >"$WORK_DIR/ssh"
        mcopy -o -i "$RAW_IMG@@$BOOT_OFF" "$WORK_DIR/ssh" ::ssh || die "writing ssh failed"
        write_first_user_files "$WORK_DIR"
        mcopy -o -i "$RAW_IMG@@$BOOT_OFF" "$WORK_DIR/user-data" ::user-data || die "writing user-data failed"
        rm -f "$WORK_DIR/user-data"
        if [ "$PREINSTALLED" -eq 1 ]; then
            # no rainbow square from the firmware (config.txt's business, not the kernel's)
            mcopy -o -i "$RAW_IMG@@$BOOT_OFF" ::config.txt "$WORK_DIR/config.txt" || die "no config.txt on the boot partition"
            if ! grep -q '^disable_splash=' "$WORK_DIR/config.txt"; then
                # in its own [all] section (it applies whatever [model] filter the file ends under) - the base
                # image's config.txt already ends with one
                [ "$(grep -v '^[[:space:]]*$' "$WORK_DIR/config.txt" | tail -1 | tr -d '\r')" = "[all]" ] || printf '\n[all]\n' >>"$WORK_DIR/config.txt"
                printf '# AutoBleem: no rainbow square from the firmware\ndisable_splash=1\n' >>"$WORK_DIR/config.txt"
            fi
            mcopy -o -i "$RAW_IMG@@$BOOT_OFF" "$WORK_DIR/config.txt" ::config.txt || die "writing config.txt failed"
            rm -f "$WORK_DIR/config.txt"
        fi
        rm -f "$cmdline" "$WORK_DIR/ssh"
        mdir -i "$RAW_IMG@@$BOOT_OFF" ::autobleem.txt ::cmdline.txt ::ssh ::user-data | grep -iE "autobleem|cmdline|ssh|user-data" | sed 's/^/    /'
    else
        install -m 0644 "$REPO_DIR/payload_linux/system/autobleem.txt" "$BOOT_MNT/autobleem.txt"
        : >"$BOOT_MNT/ssh"
        write_first_user_files "$BOOT_MNT"
        if [ "$PREINSTALLED" -eq 1 ] && ! grep -q '^disable_splash=' "$BOOT_MNT/config.txt"; then
            printf '\n[all]\n# AutoBleem: no rainbow square from the firmware\ndisable_splash=1\n' >>"$BOOT_MNT/config.txt"
        fi
    fi
}

#*******************************
# finalize_image
#*******************************
finalize_image() {
    local out_img="$OUT_IMG"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '    would recompress %s -> %s and hash both\n' "$RAW_IMG" "$out_img"
        EXTRACT_SIZE=0; EXTRACT_SHA256="0"; DOWNLOAD_SIZE=0; DOWNLOAD_SHA256="0"
        OUT_IMG="$out_img"
        return 0
    fi

    log "Hashing the raw image (this is 'extract_size'/'extract_sha256')"
    EXTRACT_SIZE="$(stat -c%s "$RAW_IMG")"
    EXTRACT_SHA256="$(sha256sum "$RAW_IMG" | cut -d' ' -f1)"

    log "Recompressing to $out_img (xz -T0 -$XZ_LEVEL, this can take a while)"
    rm -f "$out_img"
    if ! xz -T0 "-$XZ_LEVEL" -c "$RAW_IMG" >"$out_img"; then
        rm -f "$out_img" # never leave a truncated image that looks like a real one
        die "xz failed writing $out_img (out of space?) - the decompressed image is kept in $WORK_DIR"
    fi
    [ "$KEEP_RAW" -eq 1 ] || rm -f "$RAW_IMG"

    DOWNLOAD_SIZE="$(stat -c%s "$out_img")"
    DOWNLOAD_SHA256="$(sha256sum "$out_img" | cut -d' ' -f1)"
    OUT_IMG="$out_img"
}

#*******************************
# update_repo_json
#*******************************
# merges this run's real size/hash fields into <out>/rpi_imager_repo.json, starting from a copy of the
# checked-in template on the first run so a second `make_rpi_image.sh --arch <other>` invocation fills in
# the other architecture's entry alongside, not over, this one's.
update_repo_json() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '    would update %s/rpi_imager_repo.json for %s\n' "$OUT_DIR" "$ARCH"
        return 0
    fi
    local out_json="$OUT_DIR/rpi_imager_repo.json"
    [ -f "$out_json" ] || cp "$SCRIPT_DIR/rpi_imager_repo.json" "$out_json"

    ARCH="$ARCH" EXTRACT_SIZE="$EXTRACT_SIZE" EXTRACT_SHA256="$EXTRACT_SHA256" \
    DOWNLOAD_SIZE="$DOWNLOAD_SIZE" DOWNLOAD_SHA256="$DOWNLOAD_SHA256" \
    RELEASE_DATE="$BASE_RELEASE_DATE" VERSION="$VERSION" OUT_JSON="$out_json" \
    IMAGE_URL="$REPO_URL/rpi-imager/images/${VERSION:-unversioned}/$(basename "$OUT_IMG")" \
    ICON_URL="$REPO_URL/rpi-imager/icon.png" python3 - <<'PYEOF'
import json, os, re

path = os.environ["OUT_JSON"]
arch = os.environ["ARCH"]
name = "AutoBleem (32-bit)" if arch == "armhf" else "AutoBleem (64-bit)"

with open(path, encoding="utf-8") as f:
    data = json.load(f)

for entry in data["os_list"]:
    if entry["name"] == name:
        entry["extract_size"] = int(os.environ["EXTRACT_SIZE"])
        entry["extract_sha256"] = os.environ["EXTRACT_SHA256"]
        entry["image_download_size"] = int(os.environ["DOWNLOAD_SIZE"])
        entry["image_download_sha256"] = os.environ["DOWNLOAD_SHA256"]
        # where autobleem-repo's tools/repo_publish.sh image will put it (its repo_index.py fills these in again from what it
        # finds, so a different --repo at publish time still ends up right)
        entry["url"] = os.environ["IMAGE_URL"]
        entry["icon"] = os.environ["ICON_URL"]
        if os.environ["RELEASE_DATE"]:
            entry["release_date"] = os.environ["RELEASE_DATE"]
        if os.environ["VERSION"]:
            # the version goes in the description Imager shows under the name; a rerun replaces, not appends
            base = re.sub(r" AutoBleem [^ ]+\.$", "", entry.get("description", "").rstrip())
            entry["description"] = f"{base} AutoBleem {os.environ['VERSION']}."
        break
else:
    raise SystemExit(f"no os_list entry named {name!r} in {path}")

with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
}

#*******************************
# summary
#*******************************
summary() {
    log "Done."
    if [ "$DRY_RUN" -eq 1 ]; then
        warn "this was a --dry-run: nothing above actually happened"
        return 0
    fi
    cat <<EOF

  Image:      $OUT_IMG
  Repo JSON:  $OUT_DIR/rpi_imager_repo.json  (url/icon point at $REPO_URL; autobleem-repo's tools/repo_publish.sh image
              puts the image and this file on the site, where it becomes rpi-imager/os_list.json)

  Test it with Raspberry Pi Imager: "Use custom", point at the .img.xz directly (no customisation offered
  that way), or at the JSON via tools/rpi_imager_local_manifest.py / --repo for hostname/WiFi/SSH/user
  setup too.

EOF
}

#*******************************
# main
#*******************************
main() {
    parse_args "$@"
    preflight
    resolve_base_image
    decompress_base_image
    fetch_offline
    mount_image
    prepare_offline
    preinstall_root
    inject_payload
    inject_boot_files
    unmount_image
    finalize_image
    update_repo_json
    summary
}

main "$@"
