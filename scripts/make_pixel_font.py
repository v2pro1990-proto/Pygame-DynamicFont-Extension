"""Builds dynamic_font/assets/fonts/DynamicFontPixel.dfbmp, the bitmap font that
ships with the package, from JetBrains Mono (SIL Open Font License 1.1).

    python scripts/make_pixel_font.py [--source JetBrainsMono-Regular.ttf] [--px 16]

Every character is rasterized by FreeType at --px pixels in 1-bit mode (no
anti-aliasing: one pixel is one bit), then placed in one fixed cell that is
big enough for the ink of every character in the set (so stacked Vietnamese
tone marks are never cut) with the font's baseline. The pen moves by the
font's own advance, so the gap is 0 (the side bearings already space the
characters). Output: a .dfbmp v3 file — see dynamic_font/c_bitmapfont.h.

The result is a derivative of JetBrains Mono and stays under the SIL Open
Font License 1.1 (dynamic_font/licenses/DynamicFontPixel-OFL.txt).
"""
import argparse
import os
import struct

os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
os.environ["PYGAME_HIDE_SUPPORT_PROMPT"] = "1"
import pygame
import pygame.freetype

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "dynamic_font", "assets", "fonts", "DynamicFontPixel.dfbmp")

VIETNAMESE = ("àáảãạăằắẳẵặâầấẩẫậđèéẻẽẹêềếểễệìíỉĩịòóỏõọôồốổỗộơờớởỡợùúủũụưừứửữựỳýỷỹỵ")
CHARSET = ([chr(c) for c in range(0x20, 0x7F)]          # printable ASCII (incl. space)
           + list(VIETNAMESE.upper()) + list(VIETNAMESE)
           + list("°±×÷€£¥©®·•…–—‘’“”«»¿¡§¶"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", default=os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Fonts",
                                                     "JetBrainsMono-Regular.ttf"))
    ap.add_argument("--px", type=int, default=16)
    ap.add_argument("--out", default=OUT)
    args = ap.parse_args()

    pygame.init(); pygame.freetype.init()
    f = pygame.freetype.Font(args.source, args.px)
    f.antialiased = False          # 1-bit: one pixel = one bit
    f.origin = True
    advance = int(round(f.get_metrics("M")[0][4]))

    # Ink of every character relative to the pen origin, to size the cell.
    glyphs = []
    for ch in CHARSET:
        m = f.get_metrics(ch)[0]
        if m is None:
            raise SystemExit(f"{args.source} has no glyph for {ch!r}")
        surf, rect = f.render(ch, (255, 255, 255), (0, 0, 0))   # rect: x = left bearing, y = top above baseline
        glyphs.append((ch, surf, rect))
    left = min(0, min(r.x for _, _, r in glyphs))
    right = max(advance, max(r.x + r.w for _, _, r in glyphs))
    top = max(r.y for _, _, r in glyphs)                        # rows above the baseline
    bottom = max(r.h - r.y for _, _, r in glyphs)               # rows below it
    cell_w, cell_h, baseline = right - left, top + bottom, top

    table, bits = bytearray(), bytearray()
    for ch, surf, rect in glyphs:
        cell = pygame.Surface((cell_w, cell_h)); cell.fill((0, 0, 0))
        cell.blit(surf, (rect.x - left, baseline - rect.y))
        packed = bytearray((cell_w * cell_h + 7) // 8)
        for y in range(cell_h):
            for x in range(cell_w):
                if cell.get_at((x, y))[0] >= 128:
                    i = y * cell_w + x
                    packed[i >> 3] |= 0x80 >> (i & 7)
        table += struct.pack("<I", ord(ch))
        bits += packed
    # Characters already sit `advance` apart inside the cell (left bearing
    # included), but the cell may be wider than the advance: the gap field
    # can't be negative, so the pen moves one cell per character.
    gap = 0
    data = b"DFBM" + struct.pack("<HIHHHH", 3, len(glyphs), cell_w, cell_h, baseline, gap) + table + bits
    with open(args.out, "wb") as fh:
        fh.write(data)
    print(f"{args.out}: {len(glyphs)} glyphs, cell {cell_w}x{cell_h}, baseline {baseline}, "
          f"advance {advance}, {len(data)} bytes")


if __name__ == "__main__":
    main()
