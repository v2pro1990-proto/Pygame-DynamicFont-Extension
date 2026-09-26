"""Smoke test for an installed dynamic_font wheel (any platform, no display).

    python scripts/smoke_test.py [--out smoke.png]

Prints the machine, the Python and the wheel tag that pip picked, renders
every major feature (scripts, right-to-left text, emoji, inline tags, tabular
digits, multi-line text, palette edits, the bundled pixel font) with the
fonts that ship in the wheel, checks each result, and saves all of them in
one image to look at. Exits non-zero if anything fails.
Used by .github/workflows/test_arm.yml on ARM machines.
"""
import argparse
import os
import platform
import sys
import sysconfig

os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
os.environ["PYGAME_HIDE_SUPPORT_PROMPT"] = "1"
import pygame
pygame.init()
import dynamic_font as df

ap = argparse.ArgumentParser()
ap.add_argument("--out", default="smoke.png")
args = ap.parse_args()

pkg = os.path.dirname(os.path.abspath(df.__file__))
wheel_tag = "?"
try:
    from importlib import metadata
    dist = metadata.distribution("dynamic-font")
    wheel_file = dist.read_text("WHEEL") or ""
    wheel_tag = ", ".join(l.split(":", 1)[1].strip() for l in wheel_file.splitlines() if l.startswith("Tag:"))
except Exception as e:   # metadata is informational only
    wheel_tag = f"unknown ({e})"
print(f"machine    : {platform.machine()} ({platform.system()} {platform.release()})")
print(f"python     : {sys.version.split()[0]} {sysconfig.get_platform()}")
print(f"pygame     : {pygame.version.ver}")
print(f"wheel      : {wheel_tag}")
print(f"engine     : {df.get_engine_version()}   HarfBuzz {df.get_harfbuzz_version()}")

FB = os.path.join(pkg, "assets", "fonts", "fallback")
font = df.DynamicFont(os.path.join(FB, "NotoSansCJK-Regular.ttc"))   # bundled: Latin, Vietnamese, CJK
default = df.DynamicFont()                                            # zero-config: system primary if present
pixel = df.DynamicFont(df.PIXEL_FONT)
WHITE, ORANGE = (240, 240, 240), (255, 136, 0)

failures = []
shots = []


def ink(s):
    return s.get_bounding_rect(min_alpha=1)


def check(name, surf, cond=True, why=""):
    ok = surf.get_width() > 1 and surf.get_height() > 1 and ink(surf).width > 0 and cond
    print(f"  {'ok  ' if ok else 'FAIL'} {name:12} {surf.get_width()}x{surf.get_height()} {why}")
    if not ok:
        failures.append(name)
    shots.append((name, surf))


check("latin", font.render("Hello, DynamicFont!", 28, WHITE))
check("vietnamese", font.render("Tết Trung thu — ẪỄỖ ẩ ờ", 28, WHITE))
check("cjk", font.render("中秋節快樂 · 月見 · 추석", 28, WHITE))
check("arabic", font.render("مرحبا بالعالم 123", 28, WHITE))
check("hebrew", font.render("שלום עולם", 28, WHITE))
check("hindi", font.render("नमस्ते दुनिया", 28, WHITE))
check("thai", font.render("สวัสดีชาวโลก", 28, WHITE))
emoji = font.render("🌕🏮🥮😀👍", 28)
colored = any(abs(c[0] - c[1]) > 40 or abs(c[1] - c[2]) > 40
              for c in (emoji.get_at((x, y)) for x in range(0, emoji.get_width(), 2)
                        for y in range(0, emoji.get_height(), 2)) if c[3] > 200)
check("emoji", emoji, colored, "(color)" if colored else "(no color pixels!)")
check("tags", font.render("HP <[color=(255,136,0)]/bold={120}> / 200, a < b", 28, WHITE))
t1, t8 = font.render("<tnum={1111}>", 28, WHITE), font.render("<tnum={8888}>", 28, WHITE)
check("tnum", t1, t1.get_width() == t8.get_width(), f"1111={t1.get_width()} 8888={t8.get_width()}")
one = font.render("a", 28, WHITE)
multi = font.render("Line one\nLine two\nLine three", 28, WHITE)
check("multiline", multi, multi.get_height() > 2 * one.get_height())
before = pygame.image.tobytes(font.render("^1Palette", 28, WHITE), "RGBA")
df.RICH_PALETTE["1"] = ORANGE
after_s = font.render("^1Palette", 28, WHITE)
check("palette", after_s, pygame.image.tobytes(after_s, "RGBA") != before, "(recolored after edit)")
p1, p3 = pixel.render("Score: 12345", 20, WHITE), pixel.render("Score: 12345", 60, WHITE)
check("pixel_font", p3, p3.get_height() == 3 * p1.get_height(), f"1x h={p1.get_height()} 3x h={p3.get_height()}")
check("zero_config", default.render("Default font ẫ 😀", 28, WHITE))
check("dynamic", font.render("FPS: 60 ẫ", 28, WHITE, dynamic=True))
info = font.get_debug_info("aب")
print(f"  debug      {[(d.get('char'), d.get('script'), d.get('render_path')) for d in info]}")
tools = [f for f in ("dfbmp_builder.html", "dfbmp_viewer.html") if not os.path.isfile(os.path.join(pkg, "tools", f))]
if tools:
    failures.append("tools")
    print("  FAIL tools missing:", tools)

W = max(s.get_width() for _, s in shots) + 20
H = sum(s.get_height() + 6 for _, s in shots) + 20
sheet = pygame.Surface((W, H))
sheet.fill((24, 26, 32))
y = 10
for _, s in shots:
    sheet.blit(s, (10, y))
    y += s.get_height() + 6
pygame.image.save(sheet, args.out)
print(f"saved {args.out}")
if failures:
    print("FAILED:", ", ".join(failures))
    sys.exit(1)
print("ALL OK")
