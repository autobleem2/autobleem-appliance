#!/usr/bin/env python3
"""Red Hat Mono (SIL OFL) -> PSF2 console fonts for the first-boot installer's screen
(payload_linux/system/autobleem-install-ui.py draws text from PSF fonts only: a fresh Raspberry Pi OS Lite
has no FreeType).

One file per cell size and weight, in payload_linux/system/install-ui/fonts/:
    RedHatMono-<px>.psf            Medium (500), the text
    RedHatMono-SemiBold-<px>.psf   SemiBold (600), the big titles
with the cells 8x16, 9x20, 11x24 and 14x32 (px = the cell height, what find_font asks for). Glyphs are 1-bit,
the font drawn at 0.74 of the cell height with its baseline at 0.78, each character centred in its cell.
Glyph N is code point N for 0-255 (so the installer's fallback to glyph "?" works), then Latin Extended-A and a
few punctuation marks; a Unicode table maps the rest. Characters the font lacks stay out of the table.

    python tools/make_install_fonts.py --ttf "RedHatMono[wght].ttf" [--out payload_linux/system/install-ui/fonts]

The variable font and its OFL.txt: https://github.com/google/fonts/tree/main/ofl/redhatmono. Needs Pillow and
fontTools on the machine that runs this (never on the installer's target); the generated .psf files are
committed, so a build needs neither.
"""
import argparse
import os
import struct

from fontTools.ttLib import TTFont
from PIL import Image, ImageDraw, ImageFont

CELLS = {16: 8, 20: 9, 24: 11, 32: 14}          # cell height -> cell width
WEIGHTS = (("RedHatMono-%d.psf", 500), ("RedHatMono-SemiBold-%d.psf", 600))
EXTRA = [chr(c) for c in range(0x100, 0x180)] + list("–—‘’“”•…←↑→↓▲▼✓")
SIZE_OF_CELL, BASELINE = 0.74, 0.78
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.join(HERE, "..", "payload_linux", "system", "install-ui", "fonts")


def psf2(ttf, cmap, height, width, weight):
    font = ImageFont.truetype(ttf, round(height * SIZE_OF_CELL))
    font.set_variation_by_axes([weight])
    chars = [chr(c) if (0x20 <= c < 0x7F or c >= 0xA0) and c in cmap else "" for c in range(256)]
    chars += [c for c in EXTRA if ord(c) in cmap]
    per_row = (width + 7) // 8
    data = bytearray()
    for ch in chars:
        cell = Image.new("1", (width, height), 0)
        if ch and ch != " ":
            draw = ImageDraw.Draw(cell)
            draw.fontmode = "1"
            draw.text((width / 2, round(height * BASELINE)), ch, font=font, fill=1, anchor="ms")
        pixels = cell.load()
        for y in range(height):
            v = 0
            for x in range(width):
                v = (v << 1) | (1 if pixels[x, y] else 0)
            data += (v << (per_row * 8 - width)).to_bytes(per_row, "big")
    table = bytearray()
    for ch in chars:
        table += ch.encode("utf-8") if ch else b""
        table.append(0xFF)
    head = struct.pack("<8I", 0x864AB572, 0, 32, 1, len(chars), per_row * height, height, width)
    return head + data + table


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ttf", required=True, help="RedHatMono[wght].ttf")
    ap.add_argument("--out", default=DEFAULT_OUT)
    args = ap.parse_args()
    cmap = TTFont(args.ttf).getBestCmap()
    os.makedirs(args.out, exist_ok=True)
    for height, width in CELLS.items():
        for name, weight in WEIGHTS:
            path = os.path.join(args.out, name % height)
            with open(path, "wb") as f:
                f.write(psf2(args.ttf, cmap, height, width, weight))
            print("%s  %dx%d" % (os.path.basename(path), width, height))


if __name__ == "__main__":
    main()
