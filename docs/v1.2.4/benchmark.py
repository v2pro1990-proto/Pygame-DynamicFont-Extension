"""The performance table in the v1.2.4 CHANGELOG: median time per render()
call for a few typical cases, with one engine.

    python benchmark.py [--engine DIR]

Run it once with each version (--engine = a folder containing that version's
dynamic_font) on the same machine and compare. Numbers vary between machines;
the ratios are what matters.
"""
import argparse
import os
import sys
import time

ap = argparse.ArgumentParser()
ap.add_argument("--engine")
ap.add_argument("--n", type=int, default=2000)
args = ap.parse_args()
if args.engine:
    sys.path.insert(0, args.engine)
os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
os.environ["PYGAME_HIDE_SUPPORT_PROMPT"] = "1"
import pygame
pygame.init(); pygame.display.set_mode((8, 8))
import dynamic_font as df

# The v1.2.4 package's bundled fallback fonts, so both versions use the same fonts.
here = os.path.dirname(os.path.abspath(__file__))
fb = os.path.join(here, "..", "..", "dynamic_font", "assets", "fonts", "fallback")
f = df.DynamicFont("Segoe UI", fallback_name=os.path.join(fb, "NotoSansCJK-Regular.ttc"), fallback_dir=fb)
W = (255, 255, 255)


def median_ms(fn):
    for i in range(50):
        fn(i)
    ts = []
    for i in range(args.n):
        a = time.perf_counter(); fn(i); ts.append(time.perf_counter() - a)
    ts.sort()
    return ts[len(ts) // 2] * 1e3


cases = {
    "static text (cache hit)":        lambda i: f.render("Hello World 12345", 24, W),
    "dynamic ASCII counter":          lambda i: f.render(f"Score: {i * 37 % 100000}", 24, W, dynamic=True),
    "dynamic mixed scripts + emoji":  lambda i: f.render(f"HP {i % 200}/200 điểm 日本語 😀", 24, W, dynamic=True),
    "dynamic Arabic + number":        lambda i: f.render(f"السعر {i % 1000} دولار", 24, W, dynamic=True),
}
print(df.get_engine_version(), f"(Python {sys.version.split()[0]})")
for name, fn in cases.items():
    print(f"  {name:32s} {median_ms(fn):.4f} ms")
