"""The right-to-left numbers in the v1.2.4 CHANGELOG ("v1.2.3 got 3 of 8
right, v1.2.4 gets all 8"): measured, not eyeballed.

    python measure_bidi.py [--engine DIR]

Each word of a test sentence gets its own ^X palette color (supported by both
versions); the rendered Surface is then scanned for where each color's pixels
are, which gives the words' left-to-right order on screen. That order is
compared with the order the Unicode Bidirectional Algorithm (UAX #9) gives.
"""
import argparse
import os
import sys

ap = argparse.ArgumentParser()
ap.add_argument("--engine")
args = ap.parse_args()
if args.engine:
    sys.path.insert(0, args.engine)
os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
os.environ["PYGAME_HIDE_SUPPORT_PROMPT"] = "1"
import pygame
pygame.init(); pygame.display.set_mode((8, 8))
import dynamic_font as df

here = os.path.dirname(os.path.abspath(__file__))
fb = os.path.join(here, "..", "..", "dynamic_font", "assets", "fonts", "fallback")
f = df.DynamicFont("Arial", fallback_name=os.path.join(fb, "NotoSansCJK-Regular.ttc"), fallback_dir=fb)
# The ^X palette (a flat module in v1.2.3, dynamic_font._core in the package).
_palette = getattr(df, "RICH_PALETTE", None) or getattr(getattr(df, "_core", None), "RICH_PALETTE")
PAL = [tuple(_palette[k]) for k in "123456"]

# (name, words, separators between words, expected visual order of the words, left to right)
CASES = [
    ("LTR + RTL word", ["Hello", "שלום", "world"], [" ", " "], [0, 1, 2]),
    ("Arabic + number", ["السعر", "100", "دولار"], [" ", " "], [2, 1, 0]),
    ("RTL-first paragraph", ["مرحبا", "world"], [" "], [1, 0]),
    ("Hebrew in parens", ["Text", "שלום", "עולם", "end"], [" (", " ", ") "], [0, 2, 1, 3]),
    ("RTL sentence + '!'", ["שלום", "עולם", "!"], [" ", ""], [2, 1, 0]),
    ("LTR with RTL phrase", ["He", "said", "مرحبا", "بك", "today"], [" ", " ", " ", " "], [0, 1, 3, 2, 4]),
    ("Arabic, Latin inside", ["قال", "Hello", "World", "أمس"], [" ", " ", " "], [3, 1, 2, 0]),
    ("Khmer (left-to-right)", ["ភាសាខ្មែរ", "សួស្តី"], [" "], [0, 1]),
]

ok = 0
print(df.get_engine_version())
for name, words, seps, want in CASES:
    text = "".join(f"^{k + 1}{w}" + (seps[k] if k < len(seps) else "") for k, w in enumerate(words))
    s = f.render(text, 28, (255, 255, 255))
    xs = []
    for k in range(len(words)):
        pts = [x for x in range(s.get_width()) for y in range(s.get_height())
               if tuple(s.get_at((x, y)))[:3] == PAL[k] and s.get_at((x, y)).a > 200]
        xs.append(sum(pts) / len(pts) if pts else None)
    got = None if None in xs else sorted(range(len(words)), key=lambda k: xs[k])
    ok += got == want
    print(f"  {name:22s} expected {want}  got {got}  {'OK' if got == want else 'WRONG'}")
print(f"correct: {ok}/{len(CASES)}")
