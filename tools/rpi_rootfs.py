#!/usr/bin/env python3
"""Helpers for tools/make_rpi_image.sh's root pre-install (PLATFORM-23).

The image build takes the Raspberry Pi OS root out of the ext4 image as a plain directory (debugfs rdump, no
mount, no loop device), installs into it under qemu-user, and packs it back (mke2fs -d). rdump is lossy where
Linux permissions are concerned, so this file does the three things the shell cannot:

  offsets IMG                         the two partitions' byte offsets and sizes, read from the MBR
  fixmodes IMG ROOT_OFF ROOTDIR       put back what rdump drops: setuid/setgid/sticky bits (sudo, passwd, /tmp)
                                      and hard links, read from the image's own inodes (debugfs `ls -p`)
  mbr-resize IMG PART SECTORS         set a partition's size in the MBR (the root, grown for the pre-install)

Run as root (rdump restored the owners, and so does this).
"""
import argparse
import os
import re
import stat
import struct
import subprocess
import sys
import tempfile


def partitions(img):
    """[(start_byte, size_bytes)] of the four MBR slots."""
    with open(img, "rb") as f:
        f.seek(0x1BE)
        table = f.read(64)
    out = []
    for i in range(4):
        start, count = struct.unpack_from("<II", table, i * 16 + 8)
        out.append((start * 512, count * 512))
    return out


def cmd_offsets(args):
    parts = partitions(args.img)
    if parts[0][0] == 0 or parts[1][0] == 0:
        sys.exit("rpi_rootfs: %s has no second partition - is this a Raspberry Pi OS image?" % args.img)
    print(parts[0][0], parts[0][1], parts[1][0], parts[1][1])


def cmd_mbr_resize(args):
    slot = args.part - 1
    if not 0 <= slot < 4:
        sys.exit("rpi_rootfs: the MBR has partitions 1-4")
    with open(args.img, "r+b") as f:
        f.seek(0x1BE + slot * 16 + 12)
        f.write(struct.pack("<I", args.sectors))
    print("partition %d: %d sectors (%d MiB)" % (args.part, args.sectors, args.sectors * 512 // 1048576))


# "/<inode>/<mode, 6 octal digits>/<uid>/<gid>/<name>/<size>/" - debugfs `ls -p`
LS_P = re.compile(r"^/(\d+)/(\d{6})/(\d+)/(\d+)/([^/]*)/(\d*)/$")


def parse_ls_p(text):
    """Yield (directory, inode, mode, uid, gid, name) from a debugfs -f run of `ls -p <dir>` commands."""
    cur = None
    for line in text.splitlines():
        if line.startswith("debugfs: ls -p "):
            cur = line[len("debugfs: ls -p "):].strip().strip('"')
            continue
        m = LS_P.match(line)
        if m and cur is not None:
            ino, mode, uid, gid, name, _size = m.groups()
            if name in (".", ".."):
                continue
            yield cur, int(ino), int(mode, 8), int(uid), int(gid), name


def cmd_fixmodes(args):
    root = os.path.abspath(args.rootdir)
    dirs = ["/"]
    for here, subdirs, _files in os.walk(root):
        for d in subdirs:
            full = os.path.join(here, d)
            if os.path.islink(full):
                continue
            rel = "/" + os.path.relpath(full, root).replace(os.sep, "/")
            if '"' in rel:
                print("rpi_rootfs: skipping a directory with a quote in its name: %s" % rel, file=sys.stderr)
                continue
            dirs.append(rel)
    with tempfile.NamedTemporaryFile("w", suffix=".cmd", delete=False, encoding="utf-8") as cmd:
        for d in dirs:
            cmd.write('ls -p "%s"\n' % d)
        cmd_path = cmd.name
    try:
        res = subprocess.run(["debugfs", "-f", cmd_path, "%s?offset=%d" % (args.img, args.root_off)],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True)
    finally:
        os.unlink(cmd_path)
    text = res.stdout.decode("utf-8", "surrogateescape")

    seen_inode = {}
    fixed_modes = fixed_owners = linked = 0
    for directory, ino, mode, uid, gid, name in parse_ls_p(text):
        path = os.path.join(root, directory.lstrip("/"), name)
        if not os.path.lexists(path):
            continue                       # a file the image had and the pre-install removed
        if stat.S_ISLNK(mode):
            continue
        cur = os.lstat(path)
        if stat.S_ISLNK(cur.st_mode) or stat.S_IFMT(cur.st_mode) != stat.S_IFMT(mode):
            continue                       # replaced by something else since (a package took the name)
        if stat.S_ISREG(mode):
            first = seen_inode.get(ino)
            if first is None:
                seen_inode[ino] = path
            elif cur.st_ino != os.lstat(first).st_ino:
                os.unlink(path)            # rdump wrote a copy of a hard-linked file: link it again
                os.link(first, path)
                linked += 1
                continue
        if (cur.st_uid, cur.st_gid) != (uid, gid):
            os.lchown(path, uid, gid)      # before the chmod: chown clears setuid
            fixed_owners += 1
        want = stat.S_IMODE(mode)
        if stat.S_IMODE(os.lstat(path).st_mode) != want:
            os.chmod(path, want)
            fixed_modes += 1
    print("fixmodes: %d directories read, %d modes restored (setuid/setgid/sticky), %d owners, %d hard links"
          % (len(dirs), fixed_modes, fixed_owners, linked))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("offsets")
    p.add_argument("img")
    p.set_defaults(fn=cmd_offsets)
    p = sub.add_parser("fixmodes")
    p.add_argument("img")
    p.add_argument("root_off", type=int)
    p.add_argument("rootdir")
    p.set_defaults(fn=cmd_fixmodes)
    p = sub.add_parser("mbr-resize")
    p.add_argument("img")
    p.add_argument("part", type=int)
    p.add_argument("sectors", type=int)
    p.set_defaults(fn=cmd_mbr_resize)
    args = ap.parse_args(argv)
    args.fn(args)


if __name__ == "__main__":
    main()
