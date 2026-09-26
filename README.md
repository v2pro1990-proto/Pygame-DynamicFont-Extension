# DynamicFont: Font Render Extension for Pygame

> For details on what's new in the latest version, see [CHANGELOG.md](https://github.com/v2pro1990-proto/Pygame-DynamicFont-Extension/blob/master/CHANGELOG.md).

**DynamicFont** is a professional-grade Cython extension designed to eliminate the long-standing text rendering bottlenecks in standard Pygame and Pygame-CE. By engineering a custom **Texture Atlas (Glyph Caching)** architecture, it achieves rock-solid 60 FPS rendering for highly dynamic content—such as data dashboards, real-time timers, and FPS counters—without the CPU spikes or memory leaks typical of traditional surface generation.

## The Architecture: Why is it faster?

Standard rendering methods in Pygame calculate typography and allocate new RAM for every single text update. DynamicFont fundamentally changes this paradigm:

* ** Texture Atlas Generation**: Every unique glyph is rasterized exactly *once* per size and stored as a reusable coverage bitmap in a high-speed LRU cache (`_glyph_cache`, sized by `MAX_GLYPH_CACHE`). Entries are keyed by the shaped glyph, not the character — so the cache works for every script (Vietnamese diacritics, CJK, Thai, Arabic joining forms) and one entry serves every text color.
* **️ Rasterizer-Free Dynamic Path**: For rapidly changing text, the engine skips FreeType's hinting and rasterizing entirely. HarfBuzz still shapes the whole string (so kerning is preserved), then the cached glyph bitmaps are drawn straight into the output surface.
* ** O(1) Drip Eviction**: Employs a trickle-down cache management system to prevent the infamous "Micro-stutters" caused by mass memory deallocation during gameplay.
* **️ Perfect Baseline Alignment**: The `SMOOTH_FONT` engine ensures that mixed content—including Emojis and diverse font faces—remains perfectly aligned on a consistent typographic baseline.
* ** Embedded, Not Wrapped**: FreeType is statically linked directly into the compiled extension via a custom C API layer — not through `freetype-py` or any other Python wrapper — for direct C-level glyph access with no extra Python-object overhead.

## Key Features

* **Blazing Fast**: Written in pure Cython for C-level execution efficiency.
* **TrueType Collections (.ttc)**: Full native support for indexing and extracting specific faces from `.ttc` files.
* **Smart Font Fallback**: Automatically searches system paths and local directories to support international characters (Thai, Arabic, Hindi, etc.) without crashing.
* **HarfBuzz Integration**: Complex script shaping ensures ligatures, connected scripts, and mark positioning (e.g. Vietnamese tone-mark stacks) are rendered flawlessly.
* **Unicode BiDi (UAX #9)**: Right-to-left text (Arabic, Hebrew, Syriac, Thaana, N'Ko, Adlam…) mixed with left-to-right text, numbers, punctuation and brackets is laid out by the standard Unicode Bidirectional Algorithm (via the embedded [SheenBidi](https://github.com/Tehreer/SheenBidi)); `render(..., direction="auto" | "ltr" | "rtl")` sets or forces the paragraph direction.
* **Rich Text Palette**: Built-in multi-color string support using a simple `^` prefix (e.g., `^1Red Text ^2Green Text`).
* **Bitmap Fonts (`.dfbmp`)**: Pixel fonts drawn pixel-for-pixel — one bit of the font is one screen pixel, scaled only by whole numbers so they stay sharp. A builder and a viewer come with the package.
* **Full Color Emoji Support — COLRv1 → COLRv0 → CBDT → pygame.font**: A single unified fallback chain automatically picks the best available renderer per glyph, from modern vector gradients down to legacy bitmap formats, with no visible gaps in coverage.

![Comparison of pygame.font vs DynamicFont Extension](https://raw.githubusercontent.com/v2pro1990-proto/Pygame-DynamicFont-Extension/master/docs/DynamicFont_preview.png)

## Zero-Configuration Fonts

As of v1.2.3, a plain `pip install` is enough to render international text
and color emoji with no setup at all:

* **`fallback_dir`** (when not explicitly passed): points at this package's
  own bundled [Noto](https://notofonts.github.io/) font family — Noto Sans
  plus per-script variants covering CJK, Arabic, Devanagari, Thai, and
  dozens more writing systems. These are licensed under the
  [SIL Open Font License](https://openfontlicense.org/), which explicitly
  permits bundling and redistributing fonts with other software — so
  they ship directly in the wheel, adding about 20MB to the download.
* **`emoji_path`** (when not explicitly passed): auto-detects and uses
  your OS's own installed emoji font directly — Segoe UI Emoji on Windows,
  Apple Color Emoji on macOS, Noto Color Emoji on most Linux distros —
  rather than bundling one. This sidesteps redistribution questions
  entirely for fonts (like Segoe UI Emoji) that aren't freely
  redistributable, while still finding *something* to render color emoji
  with on every major OS. If no system emoji font can be found at all, it
  falls back to this package's own bundled Noto Color Emoji.

Both are fully overridable — pass your own `fallback_dir=`/`emoji_path=`
to `DynamicFont(...)` to use different fonts instead (see Quick Start
below).

## Folder Structure
```plaintext
Pygame DynamicFont Extension/
├── dynamic_font/                     # The installable package
│   ├── __init__.py                   # Public interface (re-exports _core)
│   ├── _core.pyx                     # Source code (compiled extension)
│   ├── c_fontscanner.c / .h          # Direct FreeType-based font scanning/name lookup
│   ├── c_parser.c / .h               # Rich-text tags, script runs and BiDi ordering
│   ├── c_gradientcolor.c / .h        # Text color gradients (color table + direction math)
│   ├── colrv0_render.c / .h          # COLRv0 (multi-layer) color glyph renderer
│   ├── colrv1_render.c / .h          # COLRv1 (gradient/transform) color glyph renderer
│   ├── cbdt_render.c / .h            # CBDT (embedded PNG bitmap) color glyph renderer
│   ├── emoji_ranges.c / .h           # Unicode emoji range lookup tables
│   └── assets/fonts/                 # Bundled OFL-licensed Noto fonts (auto-used as
│       └── fallback/                 # the default international/CJK fallback — see
│                                      # "Zero-Configuration Fonts" below)
├── .github/workflows                 # CI: builds wheels for Win/Linux/macOS
├── docs
├── build_all.bat                     # Windows: builds zlib -> libpng -> FreeType (with PNG)
├── setup.py                          # Build script — cross-platform
├── pyproject.toml
├── .gitignore
└── README.md
```

## Prerequisites & Installation

### Using a prebuilt wheel (recommended)
Download the wheel that matches your platform and Python version from the [Releases](https://github.com/v2pro1990-proto/Pygame-DynamicFont-Extension/releases) page, then:
```bash
pip install dynamic_font-<version>-<platform tag>.whl
pip install pygame-ce
```

### Building from source
Only pygame (or pygame-ce) is required at runtime — FreeType and HarfBuzz are compiled into the extension itself; Cython is needed to build it:
```bash
pip install pygame-ce cython
```
* **Python 3.8–3.14 (64-bit)**
* **Pygame or Pygame-CE** (recommended): the graphics surface/display backend the rendered output is blitted onto.
* **Cython**: required to compile the extension from source.
* **SheenBidi** (Unicode BiDi + script runs, Apache-2.0): NOT a pip dependency — version 3.0.0 is vendored in `sheenbidi_src/` and compiled into the extension through its unity source (`sheenbidi_src/Source/SheenBidi.c`).
* **HarfBuzz** (text shaping: ligatures, RTL, mark positioning): NOT a pip dependency — version 14.5.0 is vendored in `harfbuzz_src/` and compiled straight into the extension through its single-file "unity" source (`harfbuzz_src/src/harfbuzz.cc`), then called through its C API directly. `dynamic_font.get_harfbuzz_version()` reports the built-in version.
* **FreeType, libpng, zlib**: NOT a pip dependency — built from source and statically linked directly into the compiled extension. See `build_all.bat` (Windows) for the full build sequence; Linux/macOS use the system FreeType via `pkg-config` instead (see `setup.py`).

> **Note:** `fontTools` and `freetype-py` are **no longer dependencies** as of v1.2.3 — font name-table reading and glyph-existence checks now go directly through the embedded FreeType C API instead.

## Quick Start

### 1. Engine Initialization

Install the wheel and you're ready to go — international text (CJK, Arabic,
Devanagari, and many more scripts) and color emoji work immediately, with
**zero font setup**. See **Zero-Configuration Fonts** below for how this works.

```python
import dynamic_font

font = dynamic_font.DynamicFont(
    primary_name="Arial",       # or a TTF/OTF/TTC file path
    fallback_name="Segoe UI",   # a specific named system font, tried before
                                 # the bundled/auto-detected fallback below
)
```

`fallback_dir` and `emoji_path` are optional — omit them (as above) to use
the bundled Noto fonts and your OS's own emoji font automatically. Pass
them explicitly only if you want to override that default:

```python
font = dynamic_font.DynamicFont(
    primary_name="Arial",
    fallback_name="Segoe UI",
    fallback_dir="path/to/your/own/fonts",   # overrides the bundled Noto set
    emoji_path="path/to/your/own/emoji.ttf", # overrides OS auto-detection
)
```

### 2. Rendering Logic

The engine optimizes its execution path automatically based on the `dynamic` flag:

* **Static UI Elements** (Labels, Menus, Dialogues): Uses string-level caching for maximum efficiency.
* **Dynamic Data Displays** (Scores, Sensors, Timers): Uses the **Zero-Allocation** glyph atlas path.

```python
import pygame

# Initialize Pygame and screen...
clock = pygame.time.Clock()

# Inside your main loop:
# Setting dynamic=True bypasses standard overhead for real-time updates
fps_surface = font.render(f"FPS: {clock.get_fps():.0f}", size=24, dynamic=True)
screen.blit(fps_surface, (10, 10))

# Static text (rendered once, cached forever)
title_surface = font.render("Main Menu", size=48, color=(255, 200, 50))
screen.blit(title_surface, (100, 100))

# Spaces use the fallback font's space width by default (uniform across
# mixed scripts). For monospace fonts, keep columns aligned with the
# primary font's own space instead:
score_surface = code_font.render("HP  100 | MP   45", size=20, use_primary_space=True)
```

### Gradient text

```python
from dynamic_font import gradient

fire     = gradient([(255, 0, 0), (255, 220, 0)], gradient.UP)    # 2 colors, bottom -> top
flag     = gradient([(255, 0, 0), (255, 255, 255), (0, 0, 255)])  # 3+ colors, left -> right (default)
diagonal = gradient([(0, 255, 200), (200, 0, 255)], 45)           # any angle, in degrees
stripes  = gradient([(255, 0, 0), (0, 0, 255)], layer=3)                # red->blue repeated 3 times
wave     = gradient([(255, 0, 0), (0, 0, 255)], layer=3, mirror=True)   # red->blue->red->blue, seamless
pattern  = gradient([(255, 0, 0), (0, 0, 255)], layer=gradient.px(60))  # red->blue every 60 px, any text length
hud      = gradient([(255, 0, 0), (0, 0, 255)], layer=gradient.em(2))   # every 2x the font size, at any size

title = font.render("GAME OVER", size=48, color=fire)   # anywhere a color is accepted
```

* Build a gradient once and reuse it — it's cached like any color.
* The angle is where the colors run, first to last, counter-clockwise: `gradient.RIGHT` = `0` (default, first color on the left), `gradient.UP` = `90`, `gradient.LEFT` = `180`, `gradient.DOWN` = `270`.
* `layer` sets how the colors repeat:
  * an int (1-256): that many sweeps stretched over the whole text, ending exactly on the last color — best for static titles;
  * `gradient.px(N)`: one sweep every N pixels, repeating as far as the text goes and anchored at its start, so dynamic text that grows keeps its existing colors in place — best for scores / HUD;
  * `gradient.em(N)`: like `px`, but N times the font size, so one gradient keeps the same rhythm at every font size.
* `mirror=True` reverses every other sweep so they join without a hard cut.
* Inline `^X` color tags still override the gradient, and color emoji keep their own colors.

### Inline tags

Change the style of part of a line with `<...={text}>` (the leading `/` in `</...` is optional; tags are case-insensitive and ignore spaces):

```python
font.render("Normal <bold={bold}> text", 24)                  # face
font.render("Level <size(40)={99}> reached!", 24)            # size only
font.render("HP <[size=40]/bold={120}> / 200", 24)           # size + face
font.render("<[aa]/size(30)={pixel}> text", 24)              # toggle anti-aliasing + size
font.render("<[aa];[size=36]/bold={BIG}> text", 24)          # anti-aliasing + size + face
font.render("Score <color((255,136,0))={120}>", 24)          # color only (a tuple)
font.render("<[aa]/color((255,136,0))={pixel}>", 24)         # anti-aliasing + color
font.render("<[color=(255,136,0)]/bold={WIN}>", 24)          # color + face
font.render("<[aa];[size=40];[color=(255,136,0)]/bold={X}>", 24)
font.render("Score: <tnum={12345}>", 24)                    # equal-width digits only
font.render("<[tnum];[size=40]/bold={12:05}>", 24)          # equal-width digits + size + face
font.render("^1Red ^2Green ^rDefault", 24)                   # palette colors (Rich Text v1)

# Colors and gradients from variables — just write the variable's name
ORANGE = (255, 136, 0)
YELLOW = pygame.Color(255, 220, 0)
fire = gradient([(255, 0, 0), (255, 220, 0)])
font.render("HP <color(ORANGE)={120}> / <color(fire)={MAX}>", 24)
font.render("<[color=YELLOW]/bold={WIN}>", 24)
```

* `[aa]`, `[size=N]`, `[color=...]` and `[tnum]` can come in any order (separated by `;`), before the optional `/` and the face name.
* `tnum` gives every digit 0-9 the same width, so a changing score, timer or HP value doesn't make the text around it shift. It uses the font's own tabular digits when it has them, and works with any other font too.
* Text of different sizes on one line shares a common baseline; the line grows to fit the largest text.
* A color tag overrides `^X` palette codes for the text it covers; a `^X` inside it takes effect after the tag closes. It also overrides a gradient passed as `render()`'s `color`.
* A color is a tuple `(R, G, B)` or the name of a variable holding a tuple, a `pygame.Color` or a gradient (dotted names like `theme.gold` / `self.hp_color` work too). Names are looked up where `render()` is called — local variables first, then globals — and the current value is used on every call.
* A gradient in a color tag spans just the tagged text.

### Multi-line text

A `\n` in the text starts a new line (`\r\n` works too):

```python
RED = (255, 60, 60)
panel_text = font.render("HP: <color(RED)={100}> / 100\nMP: 45 / 80\n^1Gold^r: 12345", 24)
```

* Lines are left-aligned and one font line height apart, all in one Surface.
* Tags and `^X` colors can span several lines; a `render()` gradient sweeps across the whole block.
* Right-to-left direction is worked out for each line on its own (each line is its own BiDi paragraph).

### Bitmap fonts (`.dfbmp`)

A `.dfbmp` file is a pixel font in one small file. It isn't an image: a bitmap
"atlas" font is really two things — a picture of the glyphs plus a separate
file saying which character sits where, how big it is and how far apart
characters are. A `.dfbmp` holds the glyphs themselves as bits (one bit per
pixel) together with the few numbers that describe them, so it loads like any
other font file:

```python
pixel = dynamic_font.DynamicFont(dynamic_font.PIXEL_FONT)   # the pixel font that ships with the package
pixel.render("Score: 12345", 20, WHITE)   # 1x: one bit = 1 pixel
pixel.render("Score: 12345", 40, WHITE)   # 2x: one bit = 2x2 pixels
pixel.render("Score: 12345", 60, WHITE)   # 3x: one bit = 3x3 pixels

my_font = dynamic_font.DynamicFont("assets/fonts/my_font.dfbmp")   # or your own .dfbmp file
```

`dynamic_font.PIXEL_FONT` is **DynamicFont Pixel**, a 10x20-pixel font with
ASCII and full Vietnamese, made from JetBrains Mono (SIL Open Font License) by
`scripts/make_pixel_font.py`.

* Every character has the same fixed cell (e.g. 10x13 pixels), with a set gap between cells and a baseline.
* `size` picks the nearest whole-number scale for the cell height (never a fraction, so pixels stay square and sharp; at least 1x).
* Colors, gradients, inline tags, `^X` colors, multi-line text and `tnum` work as with any font. Characters the bitmap font doesn't have are drawn by the fallback fonts; `dynamic_font.SYNC_FONT_SIZE` (default `True`) makes them as tall as the bitmap line.
* A `.dfbmp` font can be the primary font only (`primary_name`), not `fallback_name`.

Two tools come with the package — HTML pages that open in your web browser and work offline:

```
python -m dynamic_font -buildbitmap     # builder: make a .dfbmp from an atlas image
python -m dynamic_font -bitmapviewer    # viewer: see every glyph of a .dfbmp file
```

In the builder, load an atlas image (white glyphs on black, one image pixel =
one font pixel), set the cell size, click to place a cell on each character
and type which character it is, then export the `.dfbmp` file. It can also open
an existing `.dfbmp` file to edit it.

## Parameter Variables and Functions
```python
dynamic_font.MODERN_FONT = True # Enable Primary Font ( If False, Extension Will load Fallback Font first )
```
```python
dynamic_font.SMOOTH_FONT = True # Enable Font Baseline balance ( follow Fallback font ) ( If False, each font will use its own baseline. )
```
```python
dynamic_font.EMOJI_OFFSET_Y = 0.15 # Adjust Emoji offset baseline ( Default : 0.15 )
```
```python
dynamic_font.RICH_PALETTE["x"] = (255, 150, 40) # Add / change a ^X palette color ( "^xText" ). Editing or replacing the palette takes effect on the next render()
```
```python
dynamic_font.SYNC_FONT_SIZE = True # .dfbmp primary fonts: characters from the fallback fonts as tall as the bitmap line ( If False, they use render()'s size )
```
```python
dynamic_font.is_scanning() # Read-Only API, to report the status of system font scanning
```
```python
dynamic_font.get_engine_version() # Returns the current engine version string, e.g. "v1.2.4-release"
```

## Technical Comparison

| Metric | Pygame Default | DynamicFont (v1.2.4) |
| ----- | ----- | ----- |
| **Rendering Strategy** | Re-rasterize per update | **Cached glyph bitmaps + cached layouts** |
| **CPU Overhead** | High (Scales with string length) | **Near-Zero (O(1) per glyph)** |
| **RAM Allocation** | High Frequency (Creates GC Junk) | **Minimal / Zero-Path** |
| **FPS Stability** | Prone to stuttering | **Rock-solid 60+ FPS** |
| **Complex Scripts / Emoji** | Limited / Broken | **Full (HarfBuzz + COLRv1/COLRv0/CBDT)** |
| **Right-to-left Text** | Limited | **Unicode BiDi (UAX #9)** |
| **Pixel / Bitmap Fonts** | Scaled and blurred | **Pixel-perfect `.dfbmp`, whole-number scales** |
| **Font Metadata Reading** | N/A | **Direct FreeType C API (no fontTools)** |

## Mod And Build
You are welcome to contribute to and modify the source code of this Extension!

**Windows:**
- Visual Studio 2022 or later (MSVC v142+), with the "C++ CMake tools for Windows" component
- Run `build_all.bat` once to build FreeType (with PNG support) and its dependencies, then build the extension with `setup.py`

**Linux / macOS:**
- A C compiler (gcc/clang) and `pkg-config`
- Install FreeType's development headers via your package manager (`libfreetype6-dev` on Debian/Ubuntu, `freetype` via Homebrew on macOS) — `setup.py` finds them automatically

CI builds wheels for Windows, Linux, and macOS across CPython 3.8–3.14 automatically on tagged releases — see `.github/workflows/build_wheels.yml`.

## Support & Maintenance

DynamicFont is an open-source labor of love aimed at solving a 20-year-old
framework limitation. If this extension powers your software, saves your
frame rates, and improves your workflow, consider supporting its continued
development!

- **Vietnam supporters:** [SociaBuzz](https://sociabuzz.com/v2pro1990-proto/donate) — ZaloPay, bank
 transfer, and other local payment methods.
- **International supporters:** the same [SociaBuzz](https://sociabuzz.com/v2pro1990-proto/donate)
 page currently only accepts crypto for non-Vietnam accounts. This isn't
 by choice — mainstream options like Stripe/PayPal don't currently support
 payouts to Vietnamese personal bank accounts, so broader international
 support isn't available yet.
- Have a workaround, a platform that works well for your region, or just
 want to help figure this out together? Open a
 [Discussion](https://github.com/v2pro1990-proto/Pygame-DynamicFont-Extension/discussions) — genuinely open to ideas.

## Third-Party Licenses

This extension statically links or bundles the following third-party
components. Their own licenses apply to those components independently
of this project's MIT license below. The full license texts ship inside
every wheel in `dynamic_font/licenses/` (see `README.txt` there for the
index).

* **[FreeType](https://freetype.org/)** — statically linked directly into
 the compiled extension (see `build_all.bat`). Distributed under the
 [FreeType License (FTL)](https://freetype.org/license.html), a BSD-style
 license. Per FTL's own suggested credit text:
 > Portions of this software are copyright © 1996-2023 The FreeType
 > Project (www.freetype.org). All rights reserved.
* **[libpng](http://www.libpng.org/pub/png/libpng.html)** — statically
 linked, required for CBDT color emoji support. Distributed under the
 [libpng license](http://www.libpng.org/pub/png/src/libpng-LICENSE.txt),
 a permissive BSD-style license.
* **[zlib](https://zlib.net/)** — statically linked, a dependency of
 libpng. Distributed under the [zlib License](https://zlib.net/zlib_license.html),
 a permissive license.
* **[HarfBuzz](https://harfbuzz.github.io/)** 14.5.0 — text shaping,
 compiled statically into the extension from `harfbuzz_src/`. Distributed
 under the ["Old MIT" license](https://github.com/harfbuzz/harfbuzz/blob/main/COPYING).
* **[SheenBidi](https://github.com/Tehreer/SheenBidi)** 3.0.0 — Unicode
 bidirectional algorithm (UAX #9) and script itemization, compiled
 statically into the extension from `sheenbidi_src/`. Distributed under
 the [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0).
* **DynamicFont Pixel** (`dynamic_font.PIXEL_FONT`) — a bitmap version of
 [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono), bundled in the
 package. Distributed under the [SIL Open Font License](https://openfontlicense.org/),
 like JetBrains Mono itself.
* **[Noto fonts](https://notofonts.github.io/)** (Noto Sans + per-script
 variants, Noto Color Emoji) — bundled directly in the package as the
 default `fallback_dir`/emoji fallback (see
 **Zero-Configuration Fonts** above). Distributed
 under the [SIL Open Font License](https://openfontlicense.org/), which
 explicitly permits bundling and redistribution with other software.

## Credits

DynamicFont is and will stay MIT-licensed — free to use, modify, and ship
in free or commercial games, with no strings attached beyond the MIT
license itself. It exists to solve a problem for the Pygame community.

If you ship a game or product that uses it, a mention in your credits is
**appreciated, not required**. For example:

```
Text rendering: DynamicFont by v2pro1990
https://github.com/v2pro1990-proto/Pygame-DynamicFont-Extension
```

One line *is* required by a third-party license rather than by this
project: FreeType's license asks for credit in your product's
documentation or credits. You can place it right next to the line above:

```
Portions of this software are copyright © 1996-2023 The FreeType
Project (www.freetype.org). All rights reserved.
```

## License

Distributed under the **MIT License**. See the `LICENSE` file for more information.

**Author**: v2pro1990
**Email**: v2pro1990@gmail.com
