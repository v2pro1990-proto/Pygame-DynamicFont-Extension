"""Makes the v1.2.4 CHANGELOG demo images (00_banner.png ... 06_bitmap_font.png).

Every image is a "card": the code on the left, and on the right the output
of that same code, rendered by DynamicFont itself. Nothing is drawn by hand
except the card frame, labels and the LCD / dialog-box backgrounds. The code
panel is drawn by DynamicFont too (JetBrains Mono, one color tag per token).

    python make_demos.py [--engine DIR] [--out DIR]

--engine DIR   use the dynamic_font found in DIR instead of the installed one.
--out DIR      where to save the images (default: next to this script).

The bitmap-font card uses dynamic_font.PIXEL_FONT, the .dfbmp font that ships
with the package.

Made on Windows 10 with Segoe UI, Georgia and JetBrains Mono installed; other
fonts give other (but equally real) results.
"""
import argparse
import os
import re
import sys

ap = argparse.ArgumentParser()
ap.add_argument("--engine"); ap.add_argument("--out", default=os.path.dirname(os.path.abspath(__file__)))
args = ap.parse_args()
if args.engine:
    sys.path.insert(0, args.engine)
os.makedirs(args.out, exist_ok=True)

os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
os.environ["PYGAME_HIDE_SUPPORT_PROMPT"] = "1"
import pygame
import pygame.freetype
pygame.init(); pygame.display.set_mode((8, 8)); pygame.freetype.init()
import dynamic_font as df
from dynamic_font import gradient

# ---------------------------------------------------------------- theme
BG, CARD, EDGE = (13, 15, 20), (22, 25, 33), (44, 49, 61)
CODE_BG, OUT_BG = (17, 20, 27), (9, 11, 16)
TITLE, MUTED, WHITE = (230, 233, 240), (120, 128, 145), (240, 240, 240)
SYN = {"kw": (198, 120, 221), "str": (152, 195, 121), "num": (209, 154, 102),
       "com": (92, 99, 112), "fn": (97, 175, 239), "const": (229, 192, 123), "txt": (171, 178, 191)}
KW = {"import", "from", "as", "def", "for", "in", "return", "True", "False", "None"}
TOKEN = re.compile(r'(#.*)|("(?:[^"\\]|\\.)*")|(\b\d+\b)|([A-Za-z_]\w*)(?=\()|([A-Za-z_]\w*)|(\s+)|(.)')
LANTERN = [(255, 94, 58), (255, 196, 0)]
GOLD = (255, 196, 0)


def ui_font(file_name, sys_name, size):
    """Card labels (plain pygame.freetype, not part of any demo)."""
    path = os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Fonts", file_name)
    return pygame.freetype.Font(path, size) if os.path.isfile(path) else pygame.freetype.SysFont(sys_name, size)


UIB = ui_font("seguisb.ttf", "segoeuisemibold", 18)
UI = ui_font("segoeui.ttf", "segoeui", 14)
font = df.DynamicFont("Segoe UI")
code_font = df.DynamicFont("JetBrains Mono")

# ------------------------------------------------------------ code panel
ZW = "\u200b"   # zero-width space: dropped by the tag parser AFTER it looks for tag syntax


def show_literally(t):
    """Breaks tag / palette syntax in code text with a zero-width space, so the
    engine draws "<size(44)={99}>" instead of obeying it."""
    return t.replace("={", "=" + ZW + "{").replace("}>", "}" + ZW + ">").replace("^", "^" + ZW)


def code_surface(code, width):
    """Syntax-highlighted code, drawn by DynamicFont: each token wrapped in a
    color tag (so CJK, emoji and Arabic in the code show up too)."""
    lines = code.strip("\n").split("\n")
    lh = 27
    surf = pygame.Surface((width, len(lines) * lh + 36)); surf.fill(CODE_BG)
    for i, line in enumerate(lines):
        if not line.strip():
            continue
        parts = []
        for m in TOKEN.finditer(line):
            t = m.group(0)
            if m.group(1): c = SYN["com"]
            elif m.group(2): c = SYN["str"]
            elif m.group(3): c = SYN["num"]
            elif m.group(4): c = SYN["fn"]
            elif m.group(5): c = SYN["kw"] if t in KW else (SYN["const"] if t.isupper() and len(t) > 1 else SYN["txt"])
            else: c = SYN["txt"]
            if m.group(2) and any(0x0590 <= ord(ch) <= 0x08FF for ch in t):
                t = "\u2066" + t + "\u2069"   # isolate right-to-left strings: the line stays left-to-right
            parts.append(t if not t.strip() else "<color((%d,%d,%d))={%s}>" % (*c, show_literally(t)))
        surf.blit(code_font.render("".join(parts), 17, SYN["txt"], use_primary_space=True), (22, 16 + i * lh))
    return surf


def card(name, title, subtitle, code, out_w, out_h, draw, code_w=760):
    """Saves one card: title bar, code panel (left), output panel (right) drawn by draw(surface)."""
    pad = 28
    cs = code_surface(code, code_w)
    body_h = max(cs.get_height(), out_h)
    W = pad * 2 + code_w + out_w + 2
    H = pad * 2 + 52 + body_h
    img = pygame.Surface((W, H)); img.fill(BG)
    rect = pygame.Rect(pad, pad, W - pad * 2, H - pad * 2)
    pygame.draw.rect(img, CARD, rect, border_radius=12)
    for i, col in enumerate(((255, 95, 87), (254, 188, 46), (40, 200, 64))):
        pygame.draw.circle(img, col, (rect.x + 22 + i * 20, rect.y + 26), 6)
    UIB.render_to(img, (rect.x + 90, rect.y + 16), title, TITLE)
    UI.render_to(img, (rect.x + 100 + UIB.get_rect(title).width, rect.y + 20), subtitle, MUTED)
    pygame.draw.line(img, EDGE, (rect.x, rect.y + 52), (rect.right - 1, rect.y + 52))
    code_panel = pygame.Surface((code_w, body_h)); code_panel.fill(CODE_BG); code_panel.blit(cs, (0, 0))
    img.blit(code_panel, (rect.x + 1, rect.y + 53))
    pygame.draw.line(img, EDGE, (rect.x + 1 + code_w, rect.y + 53), (rect.x + 1 + code_w, rect.bottom - 2))
    outp = pygame.Surface((out_w - 1, body_h)); outp.fill(OUT_BG)
    draw(outp)
    img.blit(outp, (rect.x + 2 + code_w, rect.y + 53))
    corner = pygame.Surface((W, H), pygame.SRCALPHA); corner.fill((*BG, 255))   # round the corners over the panels
    pygame.draw.rect(corner, (0, 0, 0, 0), rect, border_radius=12)
    img.blit(corner, (0, 0))
    pygame.draw.rect(img, EDGE, rect, 1, border_radius=12)
    pygame.image.save(img, os.path.join(args.out, name))
    print("saved", name, img.get_size())


def label(s, text, pos):
    UI.render_to(s, pos, text, MUTED)


# ------------------------------------------------------------ 0. banner
def banner():
    W, H = 1458, 360
    img = pygame.Surface((W, H)); img.fill(BG)
    rect = pygame.Rect(28, 28, W - 56, H - 56)
    panel = pygame.Surface(rect.size, pygame.SRCALPHA)
    for y in range(rect.h):
        k = y / rect.h
        pygame.draw.line(panel, (int(20 + 30 * k), int(18 + 10 * k), int(40 - 10 * k), 255), (0, y), (rect.w, y))
    mask = pygame.Surface(rect.size, pygame.SRCALPHA)
    pygame.draw.rect(mask, (255, 255, 255, 255), mask.get_rect(), border_radius=14)
    panel.blit(mask, (0, 0), special_flags=pygame.BLEND_RGBA_MIN)
    img.blit(panel, rect.topleft)
    pygame.draw.rect(img, EDGE, rect, 1, border_radius=14)
    for r, a in ((110, 14), (92, 30), (74, 255)):   # the moon
        glow = pygame.Surface((r * 2, r * 2), pygame.SRCALPHA)
        pygame.draw.circle(glow, (255, 214, 120, a), (r, r), r)
        img.blit(glow, (rect.right - 200 - r, rect.y + 150 - r))
    img.blit(font.render("DynamicFont v1.2.4", 64, gradient(LANTERN, 20, layer=gradient.em(3), mirror=True)),
             (rect.x + 48, rect.y + 26))
    img.blit(font.render("<[size=40]/bold={Mid-Autumn Update}> 🏮🥮", 30, (255, 236, 200)), (rect.x + 50, rect.y + 122))
    img.blit(font.render("Gradients · Inline tags · BiDi · Multi-line · <tnum={Tabular}> digits · Bitmap fonts · "
                         "Embedded HarfBuzz", 20, (200, 190, 175)), (rect.x + 52, rect.y + 200))
    pixel = df.DynamicFont(df.PIXEL_FONT)
    img.blit(pixel.render("Chúc mừng Trung thu - 15/8", 40, (255, 170, 80)), (rect.x + 52, rect.y + 236))
    pygame.image.save(img, os.path.join(args.out, "00_banner.png"))
    print("saved 00_banner.png", img.get_size())


banner()


# ------------------------------------------------------------ 1. gradients
def d_gradient(s):
    rows = [("gradient(LANTERN)", gradient(LANTERN)),
            ("gradient(LANTERN, gradient.UP)", gradient(LANTERN, gradient.UP)),
            ("layer=3, mirror=True", gradient(LANTERN, layer=3, mirror=True)),
            ("45°, layer=gradient.em(2), mirror=True", gradient(LANTERN, 45, layer=gradient.em(2), mirror=True))]
    y = 26
    for lab, g in rows:
        label(s, lab, (32, y))
        s.blit(font.render("Mid-Autumn Festival", 48, g), (30, y + 14)); y += 96


card("01_gradient.png", "Gradient text", "gradient( colors, angle, layer=..., mirror=... )", '''
from dynamic_font import gradient

LANTERN = [(255, 94, 58), (255, 196, 0)]

font.render("Mid-Autumn Festival", 48,
            gradient(LANTERN))
font.render("Mid-Autumn Festival", 48,
            gradient(LANTERN, gradient.UP))
font.render("Mid-Autumn Festival", 48,
            gradient(LANTERN, layer=3, mirror=True))
font.render("Mid-Autumn Festival", 48,
            gradient(LANTERN, 45, layer=gradient.em(2),
                     mirror=True))
''', 640, 410, d_gradient)


# ---------------------------------------------------------- 2. inline tags
def d_tags(s):
    fire = gradient([(255, 60, 60), (255, 200, 0)])   # found by name inside the tag below
    rows = ["Level <size(44)={99}> reached!",
            "HP <color(GOLD)={120}> / 200",
            "<[size=40];[color=fire]/bold={JACKPOT}> x3",
            "^1Red ^2Green <color((80,170,255))={^1Blue}> ^1Red"]
    y = 20
    for r in rows:
        t = font.render(r, 28, WHITE)
        s.blit(t, (30, y)); y += t.get_height() + 4


card("02_inline_tags.png", "Rich Text v2 — inline tags", "size · color by value, variable or gradient · groups", '''
GOLD = (255, 196, 0)
fire = gradient([(255, 60, 60), (255, 200, 0)])

font.render("Level <size(44)={99}> reached!", 28, WHITE)
font.render("HP <color(GOLD)={120}> / 200", 28, WHITE)
font.render("<[size=40];[color=fire]/bold={JACKPOT}> x3",
            28, WHITE)
# a color tag overrides ^X codes inside it
font.render("^1Red ^2Green <color((80,170,255))={^1Blue}> ^1Red",
            28, WHITE)
''', 640, 400, d_tags)


# ------------------------------------------------------------ 3. tnum
def d_tnum(s):
    geo = df.DynamicFont("Georgia")
    label(s, "plain digits", (40, 22)); label(s, "<tnum={...}>", (340, 22))
    y = 50
    edges = [[], []]
    for v in ("111", "247", "505", "888", "999"):
        a = geo.render(f"{v} pts", 34, (230, 230, 230))
        b = geo.render(f"<tnum={{{v}}}> pts", 34, GOLD)
        s.blit(a, (40, y)); s.blit(b, (340, y)); y += 52
        edges[0].append(40 + a.get_width()); edges[1].append(340 + b.get_width())
    # a mark at each row's right edge: ragged for plain digits, one straight line with tnum
    for col, xs in enumerate(edges):
        for i, x in enumerate(xs):
            pygame.draw.line(s, (255, 196, 0) if col else (240, 110, 100), (x + 6, 62 + i * 52), (x + 6, 94 + i * 52), 2)


card("03_tnum.png", "Tabular digits", "<tnum={...}> · [tnum] — counters that don't jiggle, in any font", '''
geo = df.DynamicFont("Georgia")

for score in (111, 247, 505, 888, 999):
    geo.render(f"{score} pts", 34, WHITE)
    # every digit the same width: "pts" never moves
    geo.render(f"<tnum={{{score}}}> pts", 34, GOLD)
''', 640, 330, d_tnum)


# ------------------------------------------------------------- 4. BiDi
def d_bidi(s):
    rows = [("Hello مرحبا 2026 world", "auto"), ("السعر 100 دولار", "auto"),
            ("Text (שלום עולם) end", "auto"), ("مرحبا world", "ltr")]
    y = 26
    for t, d in rows:
        label(s, f'direction="{d}"', (32, y))
        s.blit(font.render(t, 32, WHITE, direction=d), (30, y + 16)); y += 82


card("04_bidi.png", "Unicode BiDi (UAX #9)", "Arabic · Hebrew · numbers · brackets — laid out like the OS does", '''
font.render("Hello مرحبا 2026 world", 32, WHITE)
font.render("السعر 100 دولار", 32, WHITE)
font.render("Text (שלום עולם) end", 32, WHITE)
font.render("مرحبا world", 32, WHITE, direction="ltr")
''', 640, 350, d_bidi)


# -------------------------------------------------------- 5. multi-line
def d_multiline(s):
    box = pygame.Rect(26, 26, s.get_width() - 52, 150)
    pygame.draw.rect(s, (28, 22, 18), box, border_radius=10)
    pygame.draw.rect(s, (255, 150, 60), box, 2, border_radius=10)
    dialog = ("<[size=30]/bold={Chú Cuội}>\n"
              "Trung thu năm nay trăng tròn\n"
              "và sáng lắm! Rước đèn lúc <tnum={19:00}> 🏮🥮")
    s.blit(font.render(dialog, 26, WHITE), (box.x + 22, box.y + 14))
    s.blit(font.render("Tết Trung Thu\nMid-Autumn\n中秋節", 40, gradient(LANTERN, gradient.DOWN)), (40, 200))


card("05_multiline.png", "Multi-line text", "\\n starts a new line · tags and gradients span lines", '''
dialog = ("<[size=30]/bold={Chú Cuội}>\\n"
          "Trung thu năm nay trăng tròn\\n"
          "và sáng lắm! Rước đèn lúc <tnum={19:00}> 🏮🥮")
font.render(dialog, 26, WHITE)

# one gradient sweeps across the whole block
font.render("Tết Trung Thu\\nMid-Autumn\\n中秋節", 40,
            gradient(LANTERN, gradient.DOWN))
''', 640, 400, d_multiline)


# -------------------------------------------------------- 6. .dfbmp
def d_bitmap(s):
    lcd = pygame.Rect(26, 26, s.get_width() - 52, 146)   # calculator-screen background
    pygame.draw.rect(s, (160, 178, 142), lcd, border_radius=8)
    pygame.draw.rect(s, (90, 100, 80), lcd, 3, border_radius=8)
    INK = (28, 34, 26)
    pixel = df.DynamicFont(df.PIXEL_FONT)
    y = lcd.y + 10
    for sz in (20, 40, 60):
        s.blit(pixel.render("Trung Thu 2026", sz, INK), (lcd.x + 20, y)); y += sz - sz // 7
    s.blit(pixel.render("Chúc mừng Trung thu 🥮 中秋", 20, (255, 150, 60)), (30, 196))
    s.blit(pixel.render("Gradient <tnum={2026}>", 40, gradient(LANTERN)), (30, 236))


card("06_bitmap_font.png", "Bitmap fonts (.dfbmp)", "1 bit = 1 pixel · whole-number scales only · a pixel font ships with the package", '''
import dynamic_font as df

pixel = df.DynamicFont(df.PIXEL_FONT)       # built in: 10x20 cell
pixel.render("Trung Thu 2026", 20, INK)     # 1x
pixel.render("Trung Thu 2026", 40, INK)     # 2x  (1 bit = 2x2 px)
pixel.render("Trung Thu 2026", 60, INK)     # 3x  (1 bit = 3x3 px)

# characters the font lacks come from the fallback fonts
pixel.render("Chúc mừng Trung thu 🥮 中秋", 20, ORANGE)
# colors, gradients and tags work as with any font
pixel.render("Gradient <tnum={2026}>", 40, gradient(LANTERN))
''', 720, 330, d_bitmap)
