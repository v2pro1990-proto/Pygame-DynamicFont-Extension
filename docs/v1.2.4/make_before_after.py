"""Makes 07_fixes_before_after.png: the same input rendered by v1.2.3 and by
v1.2.4, side by side, for the bug fixes that change what gets drawn.

    python make_before_after.py --old DIR [--new DIR] [--out DIR]

--old DIR   a folder containing the v1.2.3 dynamic_font (e.g. a v1.2.3.x wheel
            unzipped there, or its site-packages).
--new DIR   the v1.2.4 dynamic_font (default: the installed one).

Each engine renders every case in its own Python process (two versions of
the same module can't be imported side by side); this process then lays the
PNGs out in the card. Both use the same fonts: Segoe UI with the fallback
fonts bundled in the v1.2.4 package.
"""
import argparse
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))

# name -> (text, render() keyword arguments)
CASES = {
    "lt_sign":  ("Giá < 5đ <bold={rẻ}>, a < b", {}),
    "bidi1":    ("السعر 100 دولار", {}),
    "bidi11":   ("قال Hello World أمس", {}),
    "khmer":    ("ភាសាខ្មែរ សួស្តី", {}),
    "kern_dyn": ("AVATAR Toyota WAVE", {"dynamic": True}),
    "kern_sta": ("AVATAR Toyota WAVE", {}),
    # rendered with ^x = grey, then ^x changed to orange and rendered again (see render_cases)
    "palette":  ("^xLantern ^1festival", {}),
}
ROWS = [
    ("lt_sign", "A '<' in the text swallowed everything up to the next tag", '"Giá < 5đ <bold={rẻ}>, a < b"'),
    ("bidi1", "Right-to-left sentences were laid out left-to-right", '"السعر 100 دولار"   (price 100 dollars)'),
    ("bidi11", "Latin words inside Arabic text ended up in the wrong place", '"قال Hello World أمس"'),
    ("khmer", "Khmer (a left-to-right script) was drawn right-to-left", '"ភាសាខ្មែរ សួស្តី"'),
    ("kern_dyn", "dynamic=True lost kerning (AV, To, WA): wider than the same static text",
     '"AVATAR Toyota WAVE", dynamic=True'),
    ("palette", "Changing a ^X palette color didn't recolor text rendered before the change",
     'grey ^x rendered, then RICH_PALETTE["x"] = ORANGE'),
]


def render_cases(engine_dir, out_dir, fallback_dir):
    """Runs in the child process: renders every case with the engine in engine_dir."""
    sys.path.insert(0, engine_dir)
    os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
    os.environ["PYGAME_HIDE_SUPPORT_PROMPT"] = "1"
    import pygame
    pygame.init(); pygame.display.set_mode((8, 8))
    import dynamic_font as df
    f = df.DynamicFont("Segoe UI", fallback_name=os.path.join(fallback_dir, "NotoSansCJK-Regular.ttc"),
                       fallback_dir=fallback_dir)
    # The ^X palette: a module attribute in v1.2.3's flat module, dynamic_font._core's in the package.
    palette = getattr(df, "RICH_PALETTE", None)
    if palette is None:
        palette = df._core.RICH_PALETTE
    for name, (text, kw) in CASES.items():
        if name == "palette":
            palette["x"] = (130, 130, 130)                   # grey
            f.render(text, 30, (240, 240, 240), **kw)        # drawn (and cached) once...
            palette["x"] = (255, 150, 40)                    # ...then ^x becomes orange
        pygame.image.save(f.render(text, 30, (240, 240, 240), **kw), os.path.join(out_dir, name + ".png"))
    print(df.get_engine_version(), "->", out_dir)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--old", required=True); ap.add_argument("--new")
    ap.add_argument("--out", default=HERE)
    ap.add_argument("--_render", nargs=3, help=argparse.SUPPRESS)
    args = ap.parse_args()
    if args._render:
        render_cases(*args._render)
        return

    if args.new:
        sys.path.insert(0, args.new)
    os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
    os.environ["PYGAME_HIDE_SUPPORT_PROMPT"] = "1"
    import pygame
    import pygame.freetype
    pygame.init(); pygame.display.set_mode((8, 8)); pygame.freetype.init()
    import dynamic_font as df
    new_dir = args.new or os.path.dirname(os.path.dirname(os.path.abspath(df.__file__)))
    fallback_dir = os.path.join(os.path.dirname(os.path.abspath(df.__file__)), "assets", "fonts", "fallback")

    tmp = tempfile.mkdtemp()
    dirs = {}
    for tag, engine in (("old", args.old), ("new", new_dir)):
        dirs[tag] = os.path.join(tmp, tag); os.makedirs(dirs[tag])
        subprocess.run([sys.executable, os.path.abspath(__file__), "--old", args.old,
                        "--_render", engine, dirs[tag], fallback_dir], check=True)

    # ---- the card
    BG, CARD, EDGE = (13, 15, 20), (22, 25, 33), (44, 49, 61)
    ROW_A, ROW_B = (17, 20, 27), (14, 16, 22)
    TITLE, MUTED, TEXT = (230, 233, 240), (120, 128, 145), (200, 205, 215)
    OLD_C, NEW_C = (240, 110, 100), (110, 210, 130)
    fonts = os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Fonts")
    def ui(file_name, sys_name, size):
        path = os.path.join(fonts, file_name)
        return pygame.freetype.Font(path, size) if os.path.isfile(path) else pygame.freetype.SysFont(sys_name, size)
    UIB, UIB2, UI = ui("seguisb.ttf", "segoeuisemibold", 18), ui("seguisb.ttf", "segoeuisemibold", 15), ui("segoeui.ttf", "segoeui", 14)
    code_font = df.DynamicFont("JetBrains Mono", fallback_name=os.path.join(fallback_dir, "NotoSansCJK-Regular.ttc"),
                               fallback_dir=fallback_dir)
    ZW = "\u200b"

    def code_text(t):
        """Code shown literally (tag syntax broken with a zero-width space), right-to-left strings isolated."""
        t = t.replace("={", "=" + ZW + "{").replace("}>", "}" + ZW + ">")
        if any(0x0590 <= ord(c) <= 0x08FF for c in t):
            t = "\u2066" + t + "\u2069"
        return code_font.render(t, 13, MUTED, use_primary_space=True)

    LABEL_W, COL_W, ROW_H, PAD = 430, 420, 104, 28
    W = PAD * 2 + LABEL_W + COL_W * 2
    H = PAD * 2 + 52 + 40 + ROW_H * len(ROWS)
    img = pygame.Surface((W, H)); img.fill(BG)
    rect = pygame.Rect(PAD, PAD, W - PAD * 2, H - PAD * 2)
    pygame.draw.rect(img, CARD, rect, border_radius=12)
    for i, col in enumerate(((255, 95, 87), (254, 188, 46), (40, 200, 64))):
        pygame.draw.circle(img, col, (rect.x + 22 + i * 20, rect.y + 26), 6)
    UIB.render_to(img, (rect.x + 90, rect.y + 16), "Visual bug fixes", TITLE)
    UI.render_to(img, (rect.x + 100 + UIB.get_rect("Visual bug fixes").width, rect.y + 20),
                 "same input, same fonts — rendered by v1.2.3 and by v1.2.4", MUTED)
    pygame.draw.line(img, EDGE, (rect.x, rect.y + 52), (rect.right - 1, rect.y + 52))
    hy = rect.y + 52
    x_old, x_new = rect.x + LABEL_W, rect.x + LABEL_W + COL_W
    pygame.draw.rect(img, (18, 21, 28), (rect.x + 1, hy + 1, rect.w - 2, 39))
    UIB2.render_to(img, (rect.x + 22, hy + 12), "Bug", MUTED)
    UIB2.render_to(img, (x_old + 22, hy + 12), "v1.2.3 — before", OLD_C)
    UIB2.render_to(img, (x_new + 22, hy + 12), "v1.2.4 — after", NEW_C)
    for i, (name, desc, code) in enumerate(ROWS):
        y = hy + 40 + i * ROW_H
        pygame.draw.rect(img, ROW_A if i % 2 == 0 else ROW_B, (rect.x + 1, y, rect.w - 2, ROW_H))
        words, line, ly = desc.split(), "", y + 18   # description, wrapped
        for w in words:
            t = (line + " " + w).strip()
            if UI.get_rect(t).width > LABEL_W - 44:
                UI.render_to(img, (rect.x + 22, ly), line, TEXT); ly += 20; line = w
            else:
                line = t
        UI.render_to(img, (rect.x + 22, ly), line, TEXT)
        img.blit(code_text(code), (rect.x + 22, ly + 22))
        for x0, tag in ((x_old, "old"), (x_new, "new")):
            s = pygame.image.load(os.path.join(dirs[tag], name + ".png")).convert_alpha()
            img.blit(s, (x0 + 22, y + (ROW_H - s.get_height()) // 2 + 4))
            if name == "kern_dyn":
                static_w = pygame.image.load(os.path.join(dirs[tag], "kern_sta.png")).get_width()
                UI.render_to(img, (x0 + 24, y + ROW_H - 22),
                             f"width {s.get_width()} px   (same text, static: {static_w} px)", MUTED)
    for x in (x_old, x_new):
        pygame.draw.line(img, EDGE, (x, hy), (x, rect.bottom - 2))
    pygame.draw.line(img, EDGE, (rect.x, hy + 40), (rect.right - 1, hy + 40))
    corner = pygame.Surface((W, H), pygame.SRCALPHA); corner.fill((*BG, 255))
    pygame.draw.rect(corner, (0, 0, 0, 0), rect, border_radius=12)
    img.blit(corner, (0, 0))
    pygame.draw.rect(img, EDGE, rect, 1, border_radius=12)
    pygame.image.save(img, os.path.join(args.out, "07_fixes_before_after.png"))
    print("saved 07_fixes_before_after.png", img.get_size())


if __name__ == "__main__":
    main()
