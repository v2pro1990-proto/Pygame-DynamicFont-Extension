# DynamicFont: Font Render Extension for Pygame

> For details on what's new in the latest version, see [CHANGELOG.md](https://github.com/v2pro1990-proto/Pygame-DynamicFont-Extension/blob/master/CHANGELOG.md).

**DynamicFont** is a professional-grade Cython extension designed to eliminate the long-standing text rendering bottlenecks in standard Pygame and Pygame-CE. By engineering a custom **Texture Atlas (Glyph Caching)** architecture, it achieves rock-solid 60 FPS rendering for highly dynamic content—such as data dashboards, real-time timers, and FPS counters—without the CPU spikes or memory leaks typical of traditional surface generation.

## The Architecture: Why is it faster?

Standard rendering methods in Pygame calculate typography and allocate new RAM for every single text update. DynamicFont fundamentally changes this paradigm:

* ** Texture Atlas Generation**: Every unique character is rasterized exactly *once* and stored as a reusable bitmap in a high-speed dictionary (`_glyph_cache`).
* **️ Zero-Allocation Dynamic Path**: For rapidly changing text, the engine bypasses FreeType entirely. It simply "blits" pre-rendered glyphs onto the target surface, achieving `O(1)` complexity per character and generating zero garbage for the Python GC.
* ** O(1) Drip Eviction**: Employs a trickle-down cache management system to prevent the infamous "Micro-stutters" caused by mass memory deallocation during gameplay.
* **️ Perfect Baseline Alignment**: The `SMOOTH_FONT` engine ensures that mixed content—including Emojis and diverse font faces—remains perfectly aligned on a consistent typographic baseline.
* ** Embedded, Not Wrapped**: FreeType is statically linked directly into the compiled extension via a custom C API layer — not through `freetype-py` or any other Python wrapper — for direct C-level glyph access with no extra Python-object overhead.

## Key Features

* **Blazing Fast**: Written in pure Cython for C-level execution efficiency.
* **TrueType Collections (.ttc)**: Full native support for indexing and extracting specific faces from `.ttc` files.
* **Smart Font Fallback**: Automatically searches system paths and local directories to support international characters (Thai, Arabic, Hindi, etc.) without crashing.
* **HarfBuzz Integration**: Complex script shaping ensures ligatures, connected scripts, and mark positioning (e.g. Vietnamese tone-mark stacks) are rendered flawlessly.
* **Rich Text Palette**: Built-in multi-color string support using a simple `^` prefix (e.g., `^1Red Text ^2Green Text`).
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
  they ship directly in the wheel, adding roughly 60MB.
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
pip install pygame-ce uharfbuzz
```

### Building from source
Only two Python packages are required at runtime — everything else (FreeType, HarfBuzz's shaping engine access, font name-table parsing, cmap lookups) is either statically embedded in the extension or reads through it directly:
```bash
pip install pygame-ce cython uharfbuzz
```
* **Python 3.8–3.14 (64-bit)**
* **Pygame or Pygame-CE** (recommended): the graphics surface/display backend the rendered output is blitted onto.
* **Cython**: required to compile the extension from source.
* **uharfbuzz**: text shaping (ligatures, RTL reordering, mark positioning) — used at the Python level for the stable build; see `CHANGELOG.md` for the in-progress direct-C-API migration.
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
```

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
dynamic_font.is_scanning() # Read-Only API, to report the status of system font scanning
```
```python
dynamic_font.get_engine_version() # Returns the current engine version string, e.g. "v1.2.3-preview"
```

## Technical Comparison

| Metric | Pygame Default | DynamicFont (v1.2.3) |
| ----- | ----- | ----- |
| **Rendering Strategy** | Re-rasterize per update | **Texture Atlas Lookup** |
| **CPU Overhead** | High (Scales with string length) | **Near-Zero (O(1) per glyph)** |
| **RAM Allocation** | High Frequency (Creates GC Junk) | **Minimal / Zero-Path** |
| **FPS Stability** | Prone to stuttering | **Rock-solid 60+ FPS** |
| **Complex Scripts / Emoji** | Limited / Broken | **Full (HarfBuzz + COLRv1/COLRv0/CBDT)** |
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
of this project's MIT license below.

* **[FreeType](https://freetype.org/)** — statically linked directly into
 the compiled extension (see `build_all.bat`). Distributed under the
 [FreeType License (FTL)](https://freetype.org/license.html), a BSD-style
 license. Per FTL's own suggested credit text:
 > Portions of this software are copyright © 1996-2024 The FreeType
 > Project (www.freetype.org). All rights reserved.
* **[libpng](http://www.libpng.org/pub/png/libpng.html)** — statically
 linked, required for CBDT color emoji support. Distributed under the
 [libpng license](http://www.libpng.org/pub/png/src/libpng-LICENSE.txt),
 a permissive BSD-style license.
* **[zlib](https://zlib.net/)** — statically linked, a dependency of
 libpng. Distributed under the [zlib License](https://zlib.net/zlib_license.html),
 a permissive license.
* **[Noto fonts](https://notofonts.github.io/)** (Noto Sans + per-script
 variants, Noto Color Emoji) — bundled directly in the package as the
 default `fallback_dir`/emoji fallback (see
 **Zero-Configuration Fonts** above). Distributed
 under the [SIL Open Font License](https://openfontlicense.org/), which
 explicitly permits bundling and redistribution with other software.

## License

Distributed under the **MIT License**. See the `LICENSE` file for more information.

**Author**: v2pro1990
**Email**: v2pro1990@gmail.com
