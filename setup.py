from setuptools import setup
from Cython.Build import cythonize
from setuptools.extension import Extension
from pathlib import Path
import subprocess
import platform
import sys
import os

# --- 1. Long Description from README.md ---
_THIS_DIR = Path(__file__).parent
_README_PATH = _THIS_DIR / "README.md"
_LONG_DESCRIPTION = _README_PATH.read_text(encoding="utf-8") if _README_PATH.exists() else ""

# --- 2. Compiler & Linker Optimization Flags ---
if sys.platform == "win32":
    # Enable MSVC Max Speed, Auto-Vectorization, Link-Time Code Generation and whole-program optimization
    extra_compile_args = ["/O2", "/GL", "/fp:fast", "/favor:blend", "/Gy", "/Gw"]
    extra_link_args     = ["/LTCG", "/OPT:REF", "/OPT:ICF"]
else:
    # Enable GCC/Clang -O3 Tree Auto-Vectorization (SSE on x86, NEON on ARM64) and Link-Time Optimization
    extra_compile_args = ["-O3", "-flto", "-fno-math-errno", "-fomit-frame-pointer"]
    extra_link_args     = ["-flto"]

SOURCES = [
    "dynamic_font/_core.pyx",
    "dynamic_font/emoji_ranges.c",
    "dynamic_font/colrv0_render.c",
    "dynamic_font/colrv1_render.c",
    "dynamic_font/cbdt_render.c",
    "dynamic_font/c_parser.c",
    "dynamic_font/c_fontscanner.c",
]

if sys.platform == "win32":
    # ========================================================================
    # Windows: FreeType built from source (minimal config, only the modules
    # actually needed), WITH PNG support (required for CBDT color emoji
    # bitmaps) — statically linked straight into dynamic_font.pyd, so the
    # end result is a single file with no external DLL dependency.
    #
    # Both 32-bit (win32) and 64-bit (win_amd64) Python are supported —
    # build_all.bat builds BOTH architectures into separate output dirs
    # (build_x64/build_x86, and DEPS_ROOT/x64, DEPS_ROOT/x86), since a
    # 32-bit Python extension cannot link against 64-bit static libs or
    # vice versa. This picks the right one automatically based on the
    # bitness of the Python interpreter CURRENTLY RUNNING this script —
    # correct even under cibuildwheel, which invokes setup.py separately
    # once per target interpreter (so sys.maxsize here always reflects
    # the actual build target, not the host machine's own architecture).
    #
    # See build_all.bat for the full build sequence (zlib -> libpng ->
    # FreeType). After running it, the .lib files live at:
    #   freetype_src/build_x64/Release/freetype.lib   (or build_x86)
    #   <DEPS_ROOT>/x64/lib/{libpng16_static,zlibstatic}.lib  (or /x86/lib)
    # Headers (same for both architectures):
    #   freetype_src/include/
    #
    # Both roots can be overridden via environment variables — set these
    # before running this script if your layout differs from the defaults:
    #   FREETYPE_ROOT   (default: ./freetype_src, relative to this file)
    #   DEPS_ROOT        (default: C:\deps, matching build_all.bat's DEPS_ROOT)
    # ========================================================================
    _THIS_DIR_STR = os.path.dirname(os.path.abspath(__file__))
    # ARM64 detection needs TWO signals, checked in priority order —
    # platform.machine() alone is NOT sufficient:
    #
    # 1. VSCMD_ARG_TGT_ARCH — set by the MSVC dev environment specifically
    #    during CROSS-compilation (cibuildwheel's own Windows ARM64 cross-
    #    build sets this internally before invoking setup.py). This is the
    #    ONLY reliable signal in that scenario: when cross-compiling ARM64
    #    from an x64 GitHub runner, the Python process actually RUNNING
    #    this script is still x64 — only the COMPILER (cl.exe) gets
    #    retargeted to ARM64, via this exact variable (confirmed via
    #    MSVC/setuptools' own cross-compilation documentation: "By
    #    VSCMD_ARG_TGT_ARCH env var, we're telling Python it runs on the
    #    given platform"). platform.machine() in this scenario reports the
    #    HOST's real architecture (AMD64) — checking it ALONE would
    #    silently link the wrong (x64) static libs into what's supposed to
    #    be an ARM64 wheel, producing a binary that fails on real ARM64
    #    devices despite the build itself appearing to succeed.
    # 2. platform.machine() — the correct signal for a genuine NATIVE
    #    ARM64 Python (e.g. a developer building locally on real ARM64
    #    Windows hardware, not cross-compiling), where VSCMD_ARG_TGT_ARCH
    #    won't be set at all.
    #
    # sys.maxsize reliably reflects the CURRENT Python process (32 vs
    # 64-bit) even under WOW64 emulation — platform.machine() alone can
    # report the underlying OS's architecture instead of the running
    # process's in that case, which would misdetect a 32-bit Python
    # running on a 64-bit Windows machine as 64-bit. Only within the
    # 64-bit case do we need the ARM64 checks at all (there's no common
    # 32-bit ARM Python on Windows, so the 32-bit branch doesn't need this).
    _vscmd_target_arch = os.environ.get("VSCMD_ARG_TGT_ARCH", "").strip().lower()
    if sys.maxsize <= 2**32:
        _ARCH_TAG, _FT_BUILD_DIR = "x86", "build_x86"
    elif _vscmd_target_arch == "arm64" or platform.machine().upper() == "ARM64":
        _ARCH_TAG, _FT_BUILD_DIR = "arm64", "build_arm64"
    else:
        _ARCH_TAG, _FT_BUILD_DIR = "x64", "build_x64"

    FREETYPE_ROOT = os.environ.get(
        "FREETYPE_ROOT",
        os.path.join(_THIS_DIR_STR, "freetype_src")
    )
    DEPS_ROOT = os.environ.get("DEPS_ROOT", r"C:\deps")

    include_dirs = [os.path.join(FREETYPE_ROOT, "include")]
    library_dirs = [
        os.path.join(FREETYPE_ROOT, _FT_BUILD_DIR, "Release"),
        os.path.join(DEPS_ROOT, _ARCH_TAG, "lib"),
    ]
    # Link order matters for static libs: freetype depends on libpng, which
    # depends on zlib — list them in that dependency order.
    libraries = ["freetype", "libpng16_static", "zlibstatic"]

else:
    # ========================================================================
    # Linux / macOS: use FreeType (and its dependencies) via pkg-config,
    # OR a directly-specified prefix (DYNFONT_DEPS_PREFIX) when set.
    #
    # The direct-prefix path exists because pkg-config alone turned out to
    # be unreliable on macOS specifically: even with PKG_CONFIG_PATH set to
    # a from-source FreeType build's own .pc directory, pkg-config STILL
    # resolved to Homebrew's separately-installed freetype2.pc instead —
    # confirmed via a real build where the resulting wheel bundled
    # Homebrew's SHARED libfreetype.6.dylib (with its full harfbuzz/glib/
    # graphite2/brotli/pcre2 dependency chain pulled in along with it),
    # not the STATIC libfreetype.a actually built from source for this
    # exact purpose. PKG_CONFIG_PATH only ever ADDS a search location — it
    # doesn't reliably take priority over whatever Homebrew itself already
    # registered on the system beforehand, and PKG_CONFIG_LIBDIR (which
    # does fully replace the default) still wouldn't touch a Homebrew
    # path that isn't part of pkg-config's own compiled-in default.
    #
    # DYNFONT_DEPS_PREFIX, when set (see pyproject.toml's macOS before-all,
    # which builds FreeType + libpng from source into a fixed prefix),
    # bypasses pkg-config ENTIRELY for freetype/libpng — no ambiguity
    # possible about which copy gets linked. Linux's before-all already
    # installs FreeType to /usr directly (found automatically without
    # needing this at all), so this only actually activates on macOS.
    # ========================================================================
    _deps_prefix = os.environ.get("DYNFONT_DEPS_PREFIX", "")

    if _deps_prefix:
        include_dirs = [os.path.join(_deps_prefix, "include", "freetype2")]
        library_dirs = [os.path.join(_deps_prefix, "lib")]
        libraries = ["freetype", "png16", "z"]
    else:
        def _pkgconfig(flag, package):
            try:
                out = subprocess.check_output(
                    ["pkg-config", flag, package], text=True
                ).strip()
                return out.split() if out else []
            except (subprocess.CalledProcessError, FileNotFoundError):
                return []

        def _strip_prefix(flags, prefix):
            return [f[len(prefix):] for f in flags if f.startswith(prefix)]

        _cflags = _pkgconfig("--cflags", "freetype2")
        _libs = _pkgconfig("--libs", "freetype2")

        include_dirs = _strip_prefix(_cflags, "-I")
        library_dirs = _strip_prefix(_libs, "-L")
        libraries = _strip_prefix(_libs, "-l") or ["freetype"]

        if not include_dirs:
            # pkg-config not found or freetype2.pc missing — fall back to the
            # standard system paths most distros/Homebrew already put it in.
            print("[WARN] pkg-config could not find freetype2 — falling back to "
                  "default system include/lib paths. If the build fails, install "
                  "the FreeType development package for your platform (see "
                  "comment above) and/or ensure pkg-config is installed.")
            include_dirs = ["/usr/include/freetype2", "/usr/local/include/freetype2"]
            libraries = ["freetype"]

extensions = [
    Extension(
        # Module name now reflects its location INSIDE the dynamic_font
        # package (dynamic_font/_core.{pyd,so}) — not the top-level
        # "dynamic_font" name anymore, since that's now the pure-Python
        # package (__init__.py) wrapping this compiled extension.
        name="dynamic_font._core",
        sources=SOURCES,
        include_dirs=include_dirs,
        library_dirs=library_dirs,
        libraries=libraries,
        extra_compile_args=extra_compile_args,
        extra_link_args=extra_link_args,
    )
]

setup(
    name="dynamic_font",
    version="1.2.3.1",
    packages=["dynamic_font"],
    # Bundles dynamic_font/assets/fonts/** into the wheel — these are
    # ONLY the OFL-licensed Noto family fonts (Sans/CJK/Color Emoji),
    # verified redistributable ("bundled, embedded, redistributed
    # and/or sold with any software" per Noto's own SIL Open Font
    # License text). Deliberately does NOT include anything requiring
    # a system/proprietary font license — see _core.pyx's fallback
    # resolution logic for how OS-native emoji fonts (Segoe UI Emoji,
    # Apple Color Emoji) are used directly from the user's own system
    # instead of being bundled here, avoiding that licensing question
    # entirely rather than redistributing them.
    package_data={"dynamic_font": ["assets/fonts/**/*"]},
    include_package_data=True,
    # include_package_data=True bundles EVERY file inside the package
    # directory into the wheel by default (confirmed via setuptools'
    # own docs) — since dynamic_font/*.c, *.h, and _core.pyx all sit
    # right alongside __init__.py, they were being shipped into every
    # installed wheel too, not just the sdist. This only affects the
    # WHEEL (built distribution) — the sdist (source distribution)
    # still needs and keeps these files, since it's what the from-
    # source build actually compiles from.
    exclude_package_data={"dynamic_font": ["*.c", "*.h", "*.pyx"]},
    author="v2pro1990",
    author_email="v2pro1990@gmail.com",
    description="High-performance multilingual text & color emoji typography engine for Pygame and Pygame-CE",
    long_description=_LONG_DESCRIPTION,
    long_description_content_type="text/markdown",
    url="https://github.com/v2pro1990-proto/Pygame-DynamicFont-Extension",
    project_urls={
        "Source": "https://github.com/v2pro1990-proto/Pygame-DynamicFont-Extension",
        "Bug Tracker": "https://github.com/v2pro1990-proto/Pygame-DynamicFont-Extension/issues",
    },
    classifiers=[
        "Programming Language :: Python :: 3",
        "Programming Language :: Python :: 3.8",
        "Programming Language :: Python :: 3.9",
        "Programming Language :: Python :: 3.10",
        "Programming Language :: Python :: 3.11",
        "Programming Language :: Python :: 3.12",
        "Programming Language :: Python :: 3.13",
        "Programming Language :: Python :: 3.14",
        "Programming Language :: Cython",
        "Programming Language :: C",
        "Topic :: Multimedia :: Graphics",
        "Topic :: Software Development :: Libraries :: pygame",
        "Intended Audience :: Developers",
        "License :: OSI Approved :: MIT License",
        "Operating System :: Microsoft :: Windows",
        "Operating System :: POSIX :: Linux",
        "Operating System :: MacOS",
    ],
    keywords=["pygame", "pygame-ce", "font", "text rendering", "emoji", "colrv1", "colrv0", "cbdt", "sbix", "harfbuzz", "freetype", "cython"],
    install_requires=[
        "uharfbuzz",
    ],
    ext_modules=cythonize(
        extensions,
        language_level="3",
        compiler_directives={
            "boundscheck": False,
            "wraparound": False,
            "cdivision": True,
            "profile": False,
        },
    ),
)