# ============================================================================
# DynamicFont Extension For Pygame and Pygame-CE !
# Author : v2pro1990
# Email : v2pro1990@gmail.com
# ============================================================================
# cython: language_level=3
# cython: boundscheck=False
# cython: wraparound=False
# cython: nonecheck=False
# cython: cdivision=True
import pygame
import pygame.freetype # Now upgrade to pygame.freetype !
import os, json
import io
import sys
import time
import shutil
import types
import re
cimport cython
import unicodedata
import weakref
import gc
from collections import OrderedDict
from libc.string cimport memset, memcpy, strcmp
from libc.stdlib cimport malloc, realloc, free
from libc.math cimport floor

# FreeType load flags
cdef int _FT_LOAD_RENDER     = 0x4
cdef int _FT_LOAD_NO_HINTING = 0x2


# Hinting ENABLED (native font hinting, e.g. Arial's own TrueType bytecode)
# — previously OR'd with NO_HINTING, which rendered thin strokes (small
# diacritic marks like Vietnamese circumflex/dot-below at moderate-to-large
# sizes) with very low anti-aliased alpha since the outline wasn't
# grid-fit to the pixel raster. Windows' own text renderers (Notepad via
# DirectWrite/ClearType) apply this same kind of grid-fitting, which is
# why the same font looks fine there — confirmed via direct comparison.
cdef int _FT_LOAD_AA         = _FT_LOAD_RENDER  # = 4, antialiased, hinting ON
cdef int _FT_LOAD_MONO       = _FT_LOAD_RENDER | 0x20000               # FT_LOAD_TARGET_MONO = (2<<16)
cdef int _FT_LOAD_COLOR      = 0x100000
cdef int _FT_LOAD_COLOR_RENDER = _FT_LOAD_COLOR | _FT_LOAD_RENDER

MODERN_FONT = True
SMOOTH_FONT = True   # Enable/Disable baseline alignment
ANTI_ALIAS = True
# .dfbmp bitmap primary fonts: characters the bitmap font lacks (drawn by
# the fallback / emoji fonts) are sized to the bitmap's line height at its
# current scale (True), or drawn at render()'s size as given (False).
SYNC_FONT_SIZE = True
EMOJI_OFFSET_Y = 0.15  # Same familiar value/meaning as before — see
                       # _EMOJI_ANCHOR_COMPENSATION / _EMOJI_TOP_COMPENSATION
                       # below for why this still produces the right
                       # result no matter which internal formula is used.
# Internal, hidden compensations — NOT meant to be tuned by hand. Both
# exist for the same reason: each time the underlying positioning formula
# was corrected to use a more accurate reference point, the SAME
# EMOJI_OFFSET_Y value would otherwise produce a different visual result.
# Baking the difference in here keeps EMOJI_OFFSET_Y's public meaning
# identical across all these internal changes, so 0.15 still means what
# it always meant to the caller.
#
# _EMOJI_ANCHOR_COMPENSATION: for the pygame.font fallback path, which
# still measures from the rendered Surface's own height (no better
# reference available there).
cdef double _EMOJI_ANCHOR_COMPENSATION = 0.30
# _EMOJI_TOP_COMPENSATION: for the COLRv1/COLRv0 paths, which now use the
# REAL device-pixel top offset reported by colrv0_render.c/colrv1_render.c
# (see out_top) instead of approximating via height — a different,
# separately-calibrated reference point requiring its own compensation.
cdef double _EMOJI_TOP_COMPENSATION = 0.20  # 0.10 + 0.15 — the +0.15 absorbs a shift
                                # introduced when hinting was re-enabled for
                                # regular text (_FT_LOAD_AA), which appears
                                # to affect the shared face's overall metrics
                                # slightly — keeps EMOJI_OFFSET_Y=0.15 meaning
                                # the same visual result as before that fix.
MAX_TEXT_CACHE = 1200
MAX_GLYPH_CACHE = 4096     # rasterized glyph bitmaps, shared by every color (~0.5KB each at UI sizes)
MAX_FONT_OBJ_CACHE = 256    # distinct (path,index,size,face) font-object combos
MAX_PATH_CACHE     = 4000   # distinct (char,face) -> font-path resolutions
MAX_EMOJI_CACHE    = 512    # rendered color-emoji glyph surfaces
MAX_SHAPE_CACHE    = 1024   # HarfBuzz shaping results per (run text, font)
MAX_LAYOUT_CACHE   = 1024   # laid-out runs (glyph positions + bitmaps), color-independent
MAX_RUNS_CACHE     = 512    # parsed lines: tags + BiDi + script + font split -> runs

#======================================================================
"""This variable is an API that informs the main game program that it is scanning for fonts in the system.
It can read the value of this variable to display the loading screen, avoiding the
"Not Responding" error window which is aesthetically unpleasing!"""
# NOTE: THIS VARIABLE CAN ONLY BE READ FROM THE MAIN PROGRAM! IMPOSSIBLE TO OVERWRITE ITS VALUE TO AVOID SYSTEM ERRORS!!!
cdef bint _is_scanning = False
# This tuple is initialized for comparison in the protection mechanism.

#=====================================================================
# NEW IN V1.3 : Now embbeded FreeType to Extension
#=======================================================================
# ft2build.h MUST be included before ANY other FreeType header — FreeType's
# own freetype.h has a hard #error guard that refuses to compile unless
# this came first (its intended usage is "#include <ft2build.h>" followed
# by "#include FT_FREETYPE_H", not including freetype/freetype.h by its
# literal path directly). This block declares nothing — it exists purely
# so Cython emits the #include line at the right point, before the real
# declarations block below. Confirmed via a real build failure: this
# guard didn't trigger during earlier local Windows/Linux builds (likely
# a difference in how those FreeType installs were configured), but DID
# trigger on the manylinux container's dnf-installed FreeType, aborting
# the build with "ft2build.h' hasn't been included yet!" — this fixes it
# unconditionally rather than relying on it happening to work.
#=======================================================================
cdef extern from "ft2build.h":
    pass

#=======================================================================
# FreeType is now statically linked into the .pyd — declare ALL API/struct
# needed in a single block here; other cdef extern blocks below just reuse
# the type names (FT_Face/FT_GlyphSlot), not re-declare the struct body.
#=======================================================================
cdef extern from "freetype/freetype.h":
    ctypedef struct FT_LibraryRec:
        pass
    ctypedef FT_LibraryRec* FT_Library

    ctypedef struct FT_Bitmap:
        unsigned int rows
        unsigned int width
        int pitch
        unsigned char* buffer
        unsigned char pixel_mode   # FT_PIXEL_MODE_MONO=1, GRAY=2, BGRA=7 —
                                    # needed to detect when FreeType silently
                                    # returned an embedded bitmap strike
                                    # (MONO) instead of an anti-aliased
                                    # outline render.

    ctypedef struct FT_GlyphSlotRec:
        FT_Bitmap bitmap
        int bitmap_left
        int bitmap_top
    ctypedef FT_GlyphSlotRec* FT_GlyphSlot

    ctypedef struct FT_FaceRec:
        FT_GlyphSlot glyph
        long num_faces
    ctypedef FT_FaceRec* FT_Face

    int FT_Init_FreeType(FT_Library* alibrary) nogil
    int FT_Done_FreeType(FT_Library library) nogil
    int FT_New_Face(FT_Library library, const char* filepathname,
                     long face_index, FT_Face* aface) nogil
    int FT_Done_Face(FT_Face face) nogil
    int FT_Set_Pixel_Sizes(FT_Face face, unsigned int pixel_width,
                            unsigned int pixel_height) nogil
    int FT_Load_Glyph(FT_Face face, unsigned int glyph_index, int load_flags) nogil
    int FT_Render_Glyph(FT_GlyphSlot slot, int render_mode) nogil
    unsigned int FT_Get_Char_Index(FT_Face face, unsigned long charcode) nogil

# HarfBuzz is compiled INTO this extension (harfbuzz_src/src/harfbuzz.cc,
# statically linked like FreeType) and called through its C API directly —
# no uharfbuzz, no Python objects per glyph.
cdef extern from "hb.h":
    ctypedef struct hb_blob_t:
        pass
    ctypedef struct hb_face_t:
        pass
    ctypedef struct hb_font_t:
        pass
    ctypedef struct hb_buffer_t:
        pass
    ctypedef struct hb_feature_t:
        unsigned int tag
        unsigned int value
        unsigned int start
        unsigned int end
    ctypedef unsigned int hb_codepoint_t
    ctypedef int hb_position_t
    ctypedef struct hb_glyph_info_t:
        hb_codepoint_t codepoint
        unsigned int cluster
    ctypedef struct hb_glyph_position_t:
        hb_position_t x_advance
        hb_position_t y_advance
        hb_position_t x_offset
        hb_position_t y_offset

    hb_blob_t* hb_blob_create_from_file_or_fail(const char* file_name) nogil
    void hb_blob_destroy(hb_blob_t* blob) nogil
    hb_face_t* hb_face_create(hb_blob_t* blob, unsigned int index) nogil
    void hb_face_destroy(hb_face_t* face) nogil
    unsigned int hb_face_get_upem(const hb_face_t* face) nogil
    unsigned int hb_face_get_glyph_count(const hb_face_t* face) nogil
    hb_font_t* hb_font_create(hb_face_t* face) nogil
    hb_buffer_t* hb_buffer_create() nogil
    void hb_buffer_clear_contents(hb_buffer_t* buffer) nogil
    void hb_buffer_add_utf32(hb_buffer_t* buffer, const unsigned int* text, int text_length,
                             unsigned int item_offset, int item_length) nogil
    void hb_buffer_guess_segment_properties(hb_buffer_t* buffer) nogil
    ctypedef unsigned int hb_script_t
    ctypedef int hb_direction_t
    void hb_buffer_set_direction(hb_buffer_t* buffer, hb_direction_t direction) nogil
    void hb_buffer_set_script(hb_buffer_t* buffer, hb_script_t script) nogil
    hb_script_t hb_script_from_iso15924_tag(unsigned int tag) nogil
    enum:
        HB_DIRECTION_LTR
        HB_DIRECTION_RTL
    void hb_shape(hb_font_t* font, hb_buffer_t* buffer, const hb_feature_t* features,
                  unsigned int num_features) nogil
    hb_glyph_info_t* hb_buffer_get_glyph_infos(hb_buffer_t* buffer, unsigned int* length) nogil
    hb_glyph_position_t* hb_buffer_get_glyph_positions(hb_buffer_t* buffer, unsigned int* length) nogil
    const char* hb_version_string() nogil

# One reusable shaping buffer (all shaping runs under the GIL, one at a time).
cdef hb_buffer_t* _hb_shape_buf = NULL


cdef extern from "freetype/ftsynth.h":
    void FT_GlyphSlot_Embolden(FT_GlyphSlot slot) nogil
    void FT_GlyphSlot_Oblique(FT_GlyphSlot slot) nogil

# FT_Library shared across the whole engine when calling FT_* directly
# (not through freetype-py) — lazy init, exactly once, on first use.
cdef FT_Library _global_ft_lib = NULL

cdef FT_Library _ensure_ft_library() except NULL:
    global _global_ft_lib
    cdef int err
    if _global_ft_lib == NULL:
        err = FT_Init_FreeType(&_global_ft_lib)
        if err != 0:
            raise RuntimeError(f"FT_Init_FreeType failed, Error code: {err}")
    return _global_ft_lib

cdef bint _IS_WIN = sys.platform == "win32"

def _win_short_path(str path):
    """8.3 short form of an existing Windows path (pure ASCII), or None."""
    import ctypes
    cdef int n
    try:
        buf = ctypes.create_unicode_buffer(1024)
        n = ctypes.windll.kernel32.GetShortPathNameW(path, buf, 1024)
        if 0 < n < 1024:
            return buf.value
    except Exception:
        pass
    return None

cdef bytes _fs_path_bytes(str path):
    """Encodes a path for the narrow char* C APIs used here (FT_New_Face and
    the C font scanner). On Windows those resolve paths in the ANSI code
    page (CreateFileA / FindFirstFileA), NOT UTF-8 — a UTF-8 encoded path
    containing any non-ASCII character (e.g. a Vietnamese user name under
    C:/Users, or a game installed in "D:/Trò chơi") silently failed to open."""
    cdef object short
    if path is None:
        raise ValueError("font path is None")
    if not _IS_WIN:
        return os.fsencode(path)
    try:
        return path.encode("mbcs", "strict")
    except UnicodeEncodeError:
        pass
    short = _win_short_path(path)
    if short is not None:
        try:
            return (<str>short).encode("mbcs", "strict")
        except UnicodeEncodeError:
            pass
    return path.encode("utf-8")

cdef str _fs_path_str(bytes raw):
    """Inverse of _fs_path_bytes for paths coming back from the C scanner."""
    if not _IS_WIN:
        return os.fsdecode(raw)
    return raw.decode("mbcs", "replace")

_SYNTHETIC_FACE_MAP = {
    "bold":        (True,  False),
    "italic":      (False, True),
    "oblique":     (False, True),
    "bold italic": (True,  True),
    "bold_italic": (True,  True),
    "bolditalic":  (True,  True),
    "italic bold": (True,  True),
}

cdef tuple PROTECTED_VARS = ("is_scanning", "_is_scanning", "_SYNTHETIC_FACE_MAP")
#======================================================================

# How many times RICH_PALETTE has changed. Every DynamicFont compares it
# with the value it saw last and drops its cached renders when they differ:
# a static text drawn with ^X colors otherwise kept the colors it was first
# drawn with after the palette was edited.
cdef unsigned long _PALETTE_GEN = 0


cdef void _palette_changed():
    global _PALETTE_GEN
    _PALETTE_GEN += 1


class _Palette(dict):
    """RICH_PALETTE: a plain dict ({"1": (R, G, B), ...}) that notices when it
    is changed, so renders cached with the old ^X colors are redrawn."""
    def __setitem__(self, key, value):
        dict.__setitem__(self, key, value); _palette_changed()

    def __delitem__(self, key):
        dict.__delitem__(self, key); _palette_changed()

    def __ior__(self, other):
        dict.update(self, other); _palette_changed(); return self

    def update(self, *args, **kwargs):
        dict.update(self, *args, **kwargs); _palette_changed()

    def setdefault(self, key, default=None):
        _palette_changed(); return dict.setdefault(self, key, default)

    def pop(self, key, *default):
        _palette_changed(); return dict.pop(self, key, *default)

    def popitem(self):
        _palette_changed(); return dict.popitem(self)

    def clear(self):
        dict.clear(self); _palette_changed()


RICH_PALETTE = _Palette({
    '0': (255, 255, 255), '1': (255, 50, 50),   '2': (50, 255, 50),
    '3': (80, 150, 255),  '4': (255, 255, 50),  '5': (255, 50, 255),
    '6': (50, 255, 255),  '7': (200, 200, 200), '8': (100, 100, 100),
    '9': (0, 0, 0), 'a': (102, 178, 255)
})

# ADDED FONT SCANNER IN PURE C
cdef extern from "c_fontscanner.h":
    ctypedef struct C_FontEntry:
        char full_name[128]
        char family_root[128]
        char norm_name[128]
        char file_path[260]
        int face_index

    ctypedef struct C_FontScanResult:
        C_FontEntry* entries
        int count
        int capacity

    int c_get_fonts_fingerprint(const char** dirs, int num_dirs, char* out_fingerprint, int max_len) nogil
    int c_scan_system_fonts(FT_Library ft_lib, const char** dirs, int num_dirs, C_FontScanResult* out_result) nogil
    void c_free_font_scan_result(C_FontScanResult* result) nogil
    void c_get_family_root(const char* font_name, char* out_root, int max_len) nogil

cdef dict _EMOJI_CACHE = {}

# Configuration metadata for type validation
cdef dict _CONFIG_VALIDATORS = {
    "MODERN_FONT": (bool, "a Boolean value (True/False)"),
    "SMOOTH_FONT": (bool, "a Boolean value (True/False)"),
    "ANTI_ALIAS": (bool, "a Boolean value (True/False)"),
    "EMOJI_OFFSET_Y": ((int, float), "a Float or Int value"),
    "SYNC_FONT_SIZE": (bool, "a Boolean value (True/False)"),
    "MAX_TEXT_CACHE": (int, "a positive Integer value"),
    "MAX_GLYPH_CACHE": (int, "a positive Integer value"),
}

pygame.freetype.init()

def is_scanning() -> bool:
    """Read-Only API: Returns the font scanning status of the Engine"""
    global _is_scanning
    return _is_scanning

def _parse_font_input(name):
    """Parse font input — can be:
      - Font name: "JetBrains Mono"      -> (name, None)
      - Path file: "assets/fonts/x.ttf" → ([path, -1], None)
      - Path TTC:  "assets/fonts/x.ttc" → ([path, -1], None)
      - Path TTC + index: ["assets/fonts/x.ttc", 2] → ([path, 2], None)
    Returns: (resolved, is_path)
    """
    if isinstance(name, (list, tuple)):
        # Already [path, index]
        return list(name), True
    if isinstance(name, str):
        low = name.lower().strip()
        if low.endswith((".ttf", ".otf", ".ttc", ".dfbmp")) or os.sep in name or "/" in name:
            if low.endswith(".ttc"):
                # TTC has no index -> auto-detect: use index 0 (first face)
                # User wants a specific face -> pass [path, index] directly
                return [name, 0], True
            return [name, -1], True
    return name, False

cpdef str get_family_root(str font_name):
    """Strips font style suffix using high-speed C parser without regular expressions."""
    if not font_name:
        return ""
    cdef bytes name_bytes = font_name.strip().encode('utf-8')
    cdef char root_buf[128]
    c_get_family_root(name_bytes, root_buf, 128)
    return root_buf.decode('utf-8', errors='ignore')


def build_font_map():
    """Scans and indexes system fonts using high-speed native C recursion and FreeType SFNT parser."""
    global _is_scanning
    _is_scanning = True

    cdef C_FontScanResult scan_res
    cdef FT_Library ft_lib = NULL
    cdef list font_dirs = []
    cdef list c_dir_bytes = []
    cdef int num_dirs = 0
    cdef const char* dir_ptrs[8]
    cdef int i = 0, face_idx = 0
    cdef dict paths = {}
    cdef dict names = {}
    cdef str font_name_str = "", norm_name_str = "", path_str = "", d = ""

    scan_res.entries = NULL
    scan_res.count = 0
    scan_res.capacity = 0
    try:
        # A PRIVATE FT_Library for the scan: the scan below runs without the
        # GIL, and FreeType requires FT_New_Face/FT_Done_Face calls on one
        # library to be serialized — sharing _global_ft_lib would race with
        # any DynamicFont rendering on another thread meanwhile.
        if FT_Init_FreeType(&ft_lib) != 0:
            raise RuntimeError("FT_Init_FreeType failed for the font scanner")
        if sys.platform == "win32":
            font_dirs = [
                r"C:/Windows/Fonts",
                os.path.expanduser(r"~/AppData/Local/Microsoft/Windows/Fonts")
            ]
        elif sys.platform == "linux":
            font_dirs = ["/usr/share/fonts", "/usr/local/share/fonts", os.path.expanduser("~/.local/share/fonts")]
        elif sys.platform == "darwin":
            font_dirs = ["/Library/Fonts", os.path.expanduser("~/Library/Fonts")]

        c_dir_bytes = [_fs_path_bytes(d) for d in font_dirs if os.path.exists(d)]
        num_dirs = <int>len(c_dir_bytes)
        for i in range(num_dirs):
            dir_ptrs[i] = c_dir_bytes[i]

        print("[SYSTEM] Scanning and indexing system fonts...")
        # Release the GIL for the whole (multi-second on first run) scan, so
        # a game that runs this on a worker thread can keep its main loop —
        # and the is_scanning() loading screen — responsive meanwhile.
        with nogil:
            c_scan_system_fonts(ft_lib, dir_ptrs, num_dirs, &scan_res)

        for i in range(scan_res.count):
            font_name_str = scan_res.entries[i].full_name.decode('utf-8', errors='ignore')
            norm_name_str = scan_res.entries[i].norm_name.decode('utf-8', errors='ignore')
            path_str = _fs_path_str(scan_res.entries[i].file_path)
            face_idx = scan_res.entries[i].face_index

            paths[font_name_str.lower()] = [path_str, face_idx]
            if norm_name_str.lower() != font_name_str.lower():
                names[norm_name_str.lower()] = font_name_str.lower()

        print(f"[SUCCESS] Scan Finished {len(paths)} Font faces!")
        return {"paths": paths, "names": names}
    finally:
        c_free_font_scan_result(&scan_res)
        if ft_lib != NULL:
            FT_Done_FreeType(ft_lib)
        _is_scanning = False

def get_fonts_timestamp():
    """Computes directory modification timestamp and font file count fingerprint in pure C."""
    cdef list font_dirs = []
    cdef list c_dir_bytes = []
    cdef int num_dirs = 0
    cdef const char* dir_ptrs[8]
    cdef int i = 0
    cdef char fingerprint_buf[1024]
    cdef str d = ""

    if sys.platform == "win32":
        font_dirs = [
            r"C:/Windows/Fonts",
            os.path.expanduser(r"~/AppData/Local/Microsoft/Windows/Fonts")
        ]
    elif sys.platform == "linux":
        font_dirs = ["/usr/share/fonts", "/usr/local/share/fonts", os.path.expanduser("~/.local/share/fonts")]
    elif sys.platform == "darwin":
        font_dirs = ["/Library/Fonts", os.path.expanduser("~/Library/Fonts")]

    c_dir_bytes = [_fs_path_bytes(d) for d in font_dirs if os.path.exists(d)]
    num_dirs = <int>len(c_dir_bytes)
    if num_dirs == 0:
        return ""

    for i in range(num_dirs):
        dir_ptrs[i] = c_dir_bytes[i]

    with nogil:
        c_get_fonts_fingerprint(dir_ptrs, num_dirs, fingerprint_buf, 1024)
    return fingerprint_buf.decode('utf-8')

# Process-wide memo of the font map: every DynamicFont instance used to
# re-walk the system font directories (fingerprint) and re-parse the whole
# font_map.json on its first render — N fonts in a game meant N full scans
# of C:/Windows/Fonts. The map only changes when fonts are (un)installed.
_FONT_MAP_MEMO = None

def load_or_update_font_map():
    global _FONT_MAP_MEMO
    if _FONT_MAP_MEMO is None:
        _FONT_MAP_MEMO = _load_or_update_font_map_uncached()
    return _FONT_MAP_MEMO

def _load_or_update_font_map_uncached():
    #1. Cross-platform Root Directory Routing
    if sys.platform == "win32":
        base_dir = os.environ.get("ProgramData", r"C:/ProgramData")
    elif sys.platform == "darwin": # macOS
        base_dir = os.path.expanduser("~/Library/Application Support")
    else: # Linux and other operating systems (SteamOS, Ubuntu...)
        base_dir = os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share"))
        
    game_dir = os.path.join(base_dir, "dynamic_font_map")
    
    #2. Create a secure folder with Fallback protection to prevent Permission errors.
    if not os.path.exists(game_dir):
        try:
            os.makedirs(game_dir, exist_ok=True)
        except PermissionError:
            # If the OS denies system write permission, revert to the root User directory.
            print("[WARNING] No permission to write in system app data. Using local user directory.")
            game_dir = os.path.join(os.path.expanduser("~"), ".dynamic_font_map")
            os.makedirs(game_dir, exist_ok=True)
            
    target_file = os.path.join(game_dir, "font_map.json")
    current_ts = get_fonts_timestamp()

    # 3. Check cache
    if os.path.exists(target_file):
        try:
            with open(target_file, "r", encoding="utf-8") as fp:
                data = json.load(fp)
            
            # STRICT CHECK:
            # In addition to matching the timestamp, ensure the data format is version 2 (list [path, index])
            paths_dict = data.get("paths", {})
            first_val = next(iter(paths_dict.values()), None)
            
            # If the data is old (str) or the timestamp doesn't match -> Force a rescan
            if data.get("_timestamp") == current_ts and isinstance(first_val, list):
                return data
                
        except Exception as e:
            print(f"[DEBUG] Cache error or old format, Rescanning: {e}")

    # 4. SCAN command (Use 'Indexing' instead of 'Extracting' for accuracy, v2)
    print("[SYSTEM] Scanning and indexing system fonts... Please wait.")

    font_map = build_font_map() 
    
    full_data = {"_timestamp": current_ts, **font_map}
    
    # 5. Overwrite the new JSON file.
    try:
        with open(target_file, "w", encoding="utf-8") as fp:
            json.dump(full_data, fp, indent=2, ensure_ascii=False)
        print(f"[SUCCESS] Font index updated at {target_file}")
    except Exception as e:
        print(f"[ERROR] Failed to update font_map.json: {e}")
        
    return full_data

# NEW IN v1.2.3 : Move some parser to c-module
cdef extern from "c_parser.h":
    ctypedef struct CP_Color:
        unsigned char r
        unsigned char g
        unsigned char b

    ctypedef struct CP_PaletteEntry:
        unsigned char r
        unsigned char g
        unsigned char b
        unsigned char is_set

    ctypedef struct CP_Run:
        int start
        int length
        int script_group
        CP_Color color
        char face[32]
        int aa_toggle
        int color_is_default
        int size
        int grad_id
        int tag_seq
        int level
        unsigned int script_tag

    ctypedef struct CP_DebugToken:
        unsigned int codepoint
        int is_tag
        char tag_type[32]
        char active_face[32]
        int script_group
        int size
        int has_color
        CP_Color color
        int grad_id

    int cp_itemize(const unsigned int* text, int length, const CP_Run* style_runs, int n_style,
                   int base_dir, CP_Run* out_items, int max_items) nogil
    enum:
        CP_STYLE_AA
        CP_STYLE_TNUM
    enum:
        CP_DIR_AUTO
        CP_DIR_FORCE_LTR
        CP_DIR_FORCE_RTL

    int cp_is_ignorable(unsigned int code) nogil
    int cp_analyze_chars(const unsigned int* text, int length, int base_dir,
                         unsigned char* out_levels, unsigned char* out_scripts) nogil
    const char* cp_script_name(int sb_script) nogil
    unsigned int cp_script_tag(int sb_script) nogil

    int cp_parse_debug(
        const unsigned int* codepoints,
        int length,
        const char* default_face,
        const CP_PaletteEntry* palette,
        CP_DebugToken* out_tokens,
        int max_tokens
    ) nogil

    int cp_parse_text(
        const unsigned int* codepoints,
        int length,
        CP_Color default_color,
        const char* default_face,
        const CP_PaletteEntry* palette,
        unsigned int* out_clean_chars,
        int* out_clean_len,
        CP_Run* out_runs,
        int max_runs
    ) nogil


cdef extern from "emoji_ranges.h":
    int is_emoji_codepoint(unsigned int code) nogil

cdef extern from "colrv0_render.h":
    # FT_Face already declared in full in the "freetype/freetype.h" block
    # above — just reuse the name, don't redeclare the struct.
    int render_colrv0_glyph(FT_Face face, unsigned int glyph_index, int apply_italic,
                            unsigned char** out_rgba, int* out_w, int* out_h,
                            int* out_top, int* out_left) nogil

cdef extern from "colrv1_render.h":
    int render_colrv1_glyph(FT_Face face, unsigned int glyph_index, int apply_italic,
                            unsigned char** out_rgba, int* out_w, int* out_h,
                            int* out_top, int* out_left) nogil

cdef extern from "cbdt_render.h":
    int render_cbdt_glyph(FT_Face face, unsigned int glyph_index, int requested_size,
                          unsigned char** out_rgba, int* out_w, int* out_h,
                          int* out_top, int* out_left) nogil

cdef struct EmojiGlyphPos:
    double x
    double y
    int top


cdef inline bint is_emoji(int code) noexcept:
    # 1. BLOCK: Alphanumerics (Ⓐ-ⓩ)
    if 0x24B6 <= code <= 0x24EA:
        return False
    # 2. SPECIAL AMNESTY: Sun, Deck of Cards, Retro Smiley Face
    elif (0x2600 <= code <= 0x2604) or \
         (0x2660 <= code <= 0x2667) or \
         (0x2639 <= code <= 0x263B):
        return True
    # 3. BLOCK: Chess piece
    elif 0x2654 <= code <= 0x265F:
        return False
    # 4. ACCEPT: Emoji data
    else:
        return (is_emoji_codepoint(<unsigned int>code) != 0 or code == 0x200D or code == 0xFE0F)


cdef extern from *:
    """
    #ifndef CYTHON_HEX_VERSION
    #define CYTHON_HEX_VERSION 0
    #endif
    """
    cdef unsigned long CYTHON_HEX_VERSION


def get_harfbuzz_version():
    """Version of the HarfBuzz library compiled into this extension."""
    return hb_version_string().decode("ascii")


cpdef get_engine_version(bint include_cython=False):
    cdef unsigned char hex_bytes[15]
    hex_bytes[0] = 0x76
    hex_bytes[1] = 0x31
    hex_bytes[2] = 0x2e
    hex_bytes[3] = 0x32
    hex_bytes[4] = 0x2e
    hex_bytes[5] = 0x34
    hex_bytes[6] = 0x2d
    hex_bytes[7] = 0x72
    hex_bytes[8] = 0x65
    hex_bytes[9] = 0x6c
    hex_bytes[10] = 0x65
    hex_bytes[11] = 0x61
    hex_bytes[12] = 0x73
    hex_bytes[13] = 0x65
    hex_bytes[14] = 0x00
    cdef str version = bytes(hex_bytes).decode('utf-8')

    if not include_cython:
        return version

    # Decode compile-time Cython version from CYTHON_HEX_VERSION macro
    cdef unsigned int cy_major = (CYTHON_HEX_VERSION >> 24) & 0xFF
    cdef unsigned int cy_minor = (CYTHON_HEX_VERSION >> 16) & 0xFF
    cdef unsigned int cy_micro = (CYTHON_HEX_VERSION >> 8) & 0xFF
    cdef unsigned int cy_rel   = (CYTHON_HEX_VERSION >> 4) & 0x0F
    cdef unsigned int cy_ser   = CYTHON_HEX_VERSION & 0x0F

    cdef str cy_ver_str
    if cy_rel == 0xA:
        cy_ver_str = f"{cy_major}.{cy_minor}.{cy_micro}a{cy_ser}"
    elif cy_rel == 0xB:
        cy_ver_str = f"{cy_major}.{cy_minor}.{cy_micro}b{cy_ser}"
    elif cy_rel == 0xC:
        cy_ver_str = f"{cy_major}.{cy_minor}.{cy_micro}rc{cy_ser}"
    else:
        cy_ver_str = f"{cy_major}.{cy_minor}.{cy_micro}"

    return f"{version} (Cython {cy_ver_str})"


# Raw glyph metadata — replace Python 8-tuple to C-struct.
# Avoid boxing/unboxing int/double on every write/read in the hot path.
cdef struct FontMetricData:
    double asc
    double height

cdef extern from "Python.h":
    object PyUnicode_FromKindAndData(int kind, const void *buffer, Py_ssize_t size)
    int PyUnicode_4BYTE_KIND

cdef struct GlyphMeta:
    int    w_bmp
    int    h_bmp
    int    pitch
    int    left
    int    top
    double x        # base_x + x_off
    double y_off
    const unsigned char* buf   # points into a cached bitmap bytes object
    int    pixel_mode  # FreeType's ACTUAL bitmap.pixel_mode for this
                         # specific glyph (1=MONO packed-bit, 2=GRAY
                         # 8bpp) — recorded per-glyph because FreeType
                         # can silently return a MONO embedded bitmap
                         # strike instead of an anti-aliased outline
                         # render even when FT_LOAD_RENDER/AA was
                         # requested, whenever the font has a strike
                         # that exactly matches the requested pixel
                         # size (confirmed via a real font + real
                         # FreeType call, not assumed) — the caller's
                         # _aa intent alone is not a reliable signal
                         # for which format the buffer is actually in.

cdef class _LRUNode:
    """Node of a doubly-linked list. Cython automatically manages refcount
    for object/_LRUNode attributes — no manual malloc or Py_INCREF needed."""
    cdef object key
    cdef object value
    cdef _LRUNode prev
    cdef _LRUNode next

    def __cinit__(self):
        self.key   = None
        self.value = None
        self.prev  = None
        self.next  = None


cdef class _LRUCache:
    """True O(1) LRU: dict lookup key->node + doubly-linked list tracking
    access order. Touch happens in __getitem__ (cache hit) and __setitem__
    (insert/update). Keeps a dict-like interface (in / [] / []=) so existing
    call sites (`if key in cache: return cache[key]`, `cache[key]=v`)
    don't need to change at all."""
    cdef dict _map        # key -> _LRUNode
    cdef _LRUNode _head   # sentinel — most-recently-used ngay sau _head
    cdef _LRUNode _tail   # sentinel — least-recently-used, right before _tail
    cdef int _maxsize
    cdef int _size

    def __cinit__(self, int maxsize):
        self._map = {}
        self._maxsize = maxsize if maxsize > 0 else 1
        self._size = 0
        self._head = _LRUNode()
        self._tail = _LRUNode()
        self._head.next = self._tail
        self._tail.prev = self._head

    cdef inline void _unlink(self, _LRUNode node):
        node.prev.next = node.next
        node.next.prev = node.prev

    cdef inline void _push_front(self, _LRUNode node):
        node.next = self._head.next
        node.prev = self._head
        self._head.next.prev = node
        self._head.next = node

    cdef inline void _touch(self, _LRUNode node):
        if node.prev is self._head:
            return  # Already MRU at the head, skip pointer rewiring
        self._unlink(node)
        self._push_front(node)

    cdef void _evict_lru(self):
        cdef _LRUNode lru = self._tail.prev
        if lru is self._head:
            return
        self._unlink(lru)
        del self._map[lru.key]
        self._size -= 1

    cdef object c_get(self, object key):
        """Fast path — single function lookup with head-check bypass to eliminate memory pointer churn."""
        cdef _LRUNode node = self._map.get(key)
        if node is None:
            return None
        if node.prev is not self._head:
            # Inline touch only when node is not already at the front
            node.prev.next = node.next
            node.next.prev = node.prev
            node.next = self._head.next
            node.prev = self._head
            self._head.next.prev = node
            self._head.next = node
        return node.value

    cdef void c_set(self, object key, object value):
        """Pure cdef — inlines push_front/touch logic directly, no sub-function calls."""
        cdef _LRUNode node = self._map.get(key)
        if node is not None:
            node.value = value
            # Inline touch
            node.prev.next = node.next
            node.next.prev = node.prev
            node.next = self._head.next
            node.prev = self._head
            self._head.next.prev = node
            self._head.next = node
            return
        node = _LRUNode()
        node.key   = key
        node.value = value
        self._map[key] = node
        # Inline push_front
        node.next = self._head.next
        node.prev = self._head
        self._head.next.prev = node
        self._head.next = node
        self._size += 1
        if self._size > self._maxsize:
            self._evict_lru()

    def __contains__(self, key):
        return key in self._map

    def __getitem__(self, key):
        cdef _LRUNode node = self._map.get(key)
        if node is None:
            raise KeyError(key)
        self._touch(node)
        return node.value

    def __setitem__(self, key, value):
        cdef _LRUNode node = self._map.get(key)
        if node is not None:
            node.value = value
            self._touch(node)
            return
        node = _LRUNode()
        node.key   = key
        node.value = value
        self._map[key] = node
        self._push_front(node)
        self._size += 1
        if self._size > self._maxsize:
            self._evict_lru()

    def get(self, key, default=None):
        cdef _LRUNode node = self._map.get(key)
        if node is None:
            return default
        self._touch(node)
        return node.value

    def __len__(self):
        return self._size

    def clear(self):
        self._map.clear()
        self._head.next = self._tail
        self._tail.prev = self._head
        self._size = 0


_PACKAGE_DIR = os.path.dirname(os.path.abspath(__file__))
# __file__ here is the COMPILED _core.{pyd,so}'s own path after
# installation — its parent directory IS the installed "dynamic_font"
# package folder, with assets/fonts/ sitting right alongside it. This
# works identically whether the package was pip-installed into
# site-packages or run from a local source checkout, since it's always
# relative to wherever this compiled module itself actually lives.

def _auto_detect_emoji_path():
    """Used when emoji_path isn't explicitly given. Deliberately points
    at an emoji font ALREADY PRESENT on the user's own OS wherever
    possible — never bundles Segoe UI Emoji (Microsoft) or Apple Color
    Emoji (Apple) itself, since neither is legally redistributable.
    Falls back to the bundled OFL-licensed Noto Color Emoji (verified
    redistributable) only if no system emoji font can be found at all.

    macOS note: Apple Color Emoji uses the 'sbix' table format, not
    CBDT — this project's cbdt_render.c has NOT been directly verified
    against a real sbix font on real macOS hardware, though FreeType's
    own documented sbix handling (accessed via the same FT_LOAD_COLOR
    flag and the same face->available_sizes strike-selection mechanism
    already used for CBDT, both producing FT_PIXEL_MODE_BGRA output)
    strongly suggests it should work unmodified. Treat this path as
    reasonably confident but not field-tested.
    """
    cdef str candidate

    if sys.platform == "win32":
        candidate = os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Fonts", "seguiemj.ttf")
        if os.path.isfile(candidate):
            return candidate
    elif sys.platform == "darwin":
        candidate = "/System/Library/Fonts/Apple Color Emoji.ttc"
        if os.path.isfile(candidate):
            return candidate
    else:
        # Linux: no single universal path across distros, so check the
        # handful of locations Noto Color Emoji is actually commonly
        # installed at (Debian/Ubuntu, Fedora, and a generic fontconfig
        # location some distros use).
        for candidate in (
            "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
            "/usr/share/fonts/noto/NotoColorEmoji.ttf",
            "/usr/share/fonts/google-noto-emoji/NotoColorEmoji.ttf",
        ):
            if os.path.isfile(candidate):
                return candidate

    # Nothing found on the system — fall back to this package's own
    # bundled copy (OFL-licensed, safe to ship) rather than leaving
    # emoji entirely unhandled.
    candidate = os.path.join(_PACKAGE_DIR, "assets", "fonts", "NotoColorEmoji.ttf")
    if os.path.isfile(candidate):
        return candidate
    return None  # no emoji font available anywhere — emoji chars simply
                 # won't render as color; render() itself doesn't crash.


def _get_bundled_fallback_dir():
    """Used when fallback_dir isn't explicitly given. Unlike emoji
    fonts, broad international/CJK coverage genuinely isn't guaranteed
    to already exist on every OS out of the box — this always points
    at the bundled Noto Sans / Noto Sans CJK files shipped with this
    package (OFL-licensed, safe to redistribute), so multilingual text
    works immediately after a plain `pip install` with zero setup.
    Points specifically at assets/fonts/fallback/ (not assets/fonts/
    itself) — that's where the actual Noto family files live on disk,
    matching the confirmed real directory layout (111 files, one per
    script/writing system, ~76MB total)."""
    return os.path.join(_PACKAGE_DIR, "assets", "fonts", "fallback")


# The .dfbmp bitmap font that ships with the package — "DynamicFont Pixel", a
# 10x20-pixel cell with ASCII + Vietnamese, made from JetBrains Mono (SIL Open
# Font License 1.1; see scripts/make_pixel_font.py). DynamicFont(PIXEL_FONT).
PIXEL_FONT = os.path.join(_PACKAGE_DIR, "assets", "fonts", "DynamicFontPixel.dfbmp")


cdef object _rgba_to_surface(unsigned char* rgba_buf, int w, int h):
    """Wraps (and frees) a malloc'd RGBA buffer from the C color renderers.
    convert_alpha() needs a display mode — without one (rendering before
    set_mode, headless tools, tests) it raised pygame.error and killed the
    render; an independent copy works everywhere."""
    cdef bytes py_bytes = (<char*>rgba_buf)[:w * h * 4]
    free(rgba_buf)
    cdef object surf = pygame.image.frombuffer(py_bytes, (w, h), "RGBA")
    if pygame.display.get_surface() is not None:
        return surf.convert_alpha()
    return surf.copy()


# ----------------------------------------------------------------------
# Process-wide font pools, shared by EVERY DynamicFont instance.
#
# Each instance used to open its own FT_Face and read its own full copy of
# every font file into RAM for HarfBuzz — a game with 5 DynamicFont objects
# held 5 copies of NotoSansCJK (tens of MB each). A font file is now opened
# once per process no matter how many instances use it. Both pools are
# bounded by the number of distinct font FILES touched, and live until the
# process exits (FreeType frees everything with the library at exit).
#
# Sharing is safe because all rendering runs with the GIL held (FreeType is
# only ever driven by one thread at a time), and every user of a face sets
# its pixel size before loading glyphs from it.
# ----------------------------------------------------------------------
cdef dict _FT_FACE_POOL = {}     # (path, index) -> FT_Face as int (0 = failed)
cdef dict _HB_FONT_POOL = {}     # (path, index) -> (hb_font_t* as int, upem) | False

cdef object _NO_PATH = object()   # 'not cached yet' sentinel (a cached path may be None)
cdef dict _FACE_IDS = {}         # FT_Face pointer -> small int, for compact glyph-cache keys

cdef long long _face_id(size_t face_ptr):
    cdef object fid = _FACE_IDS.get(face_ptr)
    if fid is None:
        fid = len(_FACE_IDS) + 1
        _FACE_IDS[face_ptr] = fid
    return <long long>fid


cdef extern from "c_gradientcolor.h":
    ctypedef struct GradColor:
        unsigned char r
        unsigned char g
        unsigned char b
    enum: GRAD_LUT_SIZE
    void grad_build_lut(const GradColor* colors, int n, int layers, int mirror,
                        unsigned char* lut) nogil
    void grad_setup(double angle_deg, int x0, int y0, int w, int h, double period,
                    long long* ax, long long* ay, long long* c) nogil

cdef class _GradLength:
    """A gradient layer length: gradient.px(60) or gradient.em(2)."""
    cdef readonly double value
    cdef readonly int unit          # 1 = px, 2 = em

    def __init__(self, value, int unit):
        cdef str name = "px" if unit == 1 else "em"
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise TypeError(f"gradient.{name}() expects a number, got {value!r}")
        if not value > 0:
            raise ValueError(f"gradient.{name}() must be greater than 0, got {value}")
        self.value = float(value)
        self.unit = unit

    def __eq__(self, other):
        if not isinstance(other, _GradLength):
            return NotImplemented
        return self.value == (<_GradLength>other).value and self.unit == (<_GradLength>other).unit

    def __hash__(self):
        return hash((self.value, self.unit))

    def __repr__(self):
        return f"gradient.{'px' if self.unit == 1 else 'em'}({self.value:g})"


cdef class Gradient:
    """A multi-color linear text gradient, usable anywhere a color is.
    Exported as `dynamic_font.gradient` (the same class):

        from dynamic_font import gradient
        gradient([RED, WHITE])                  # 0 deg: left -> right (default)
        gradient([RED, WHITE], gradient.UP)     # named direction
        gradient([RED, WHITE, BLUE], 45)        # any angle, in degrees
        gradient([RED, BLUE], layer=3)                    # 3 sweeps across the text
        gradient([RED, BLUE], layer=gradient.px(60))      # one sweep every 60 px
        gradient([RED, BLUE], layer=gradient.em(2))       # one sweep every 2x the font size
        gradient([RED, BLUE], layer=3, mirror=True)       # RED->BLUE->RED->BLUE, seamless
        font.render("GAME OVER", 48, gradient([RED, YELLOW], gradient.UP))

    colors: 1 or more (R, G, B) tuples, spread evenly (1 color = solid).
    angle:  direction the colors run in, from the first to the last color,
            in degrees counter-clockwise: 0 = RIGHT, 90 = UP, 180 = LEFT,
            270 = DOWN, 45 = towards the top-right corner.
    layer:  how the colors repeat:
            - an int N (1-256): N sweeps stretched over the whole text, ending
              exactly on the last color — for static titles;
            - gradient.px(N): each sweep is N pixels long and the pattern
              repeats as far as the text goes, anchored at its start, so
              growing dynamic text ("Score: 9" -> "Score: 1000") keeps the
              existing characters' colors in place;
            - gradient.em(N): like px, but N times the font size, so the same
              gradient keeps the same rhythm at every font size.
    mirror: False: every sweep restarts at the first color (a hard cut
            between sweeps). True: every other sweep runs backwards, so they
            join seamlessly, like a wave.

    Create it once and reuse it every frame — it's immutable and hashable
    (render()'s cache keys include it) and precomputes its color table,
    so drawing costs a table lookup per pixel.

    With an int layer, the gradient covers the whole rendered line:
    horizontally the full text width, vertically the letters' actual height.
    Inline ^X color tags still override it for the text they cover; color
    emoji keep their own colors."""
    # Named directions, as angles in degrees.
    RIGHT = 0.0     # first color on the left  -> last color on the right
    UP    = 90.0    # bottom -> top
    LEFT  = 180.0   # right  -> left
    DOWN  = 270.0   # top    -> bottom

    @staticmethod
    def px(value):
        """Layer length in pixels: gradient([...], layer=gradient.px(60))."""
        return _GradLength(value, 1)

    @staticmethod
    def em(value):
        """Layer length in multiples of the font size:
        gradient([...], layer=gradient.em(2))."""
        return _GradLength(value, 2)

    cdef readonly tuple colors
    cdef readonly double angle
    cdef readonly object layer      # int, or a gradient.px()/em() length
    cdef readonly bint mirror
    cdef _GradLength _length        # the length form of layer, else None
    cdef unsigned char lut[GRAD_LUT_SIZE * 3]   # RGB triplets
    # lut pre-packed into pixels for one surface channel layout (shifts),
    # so drawing doesn't re-pack the whole table for every run it draws.
    cdef unsigned int _packed[GRAD_LUT_SIZE]
    cdef tuple _packed_shifts
    cdef Py_hash_t _hash
    cdef readonly long handle       # N in the "gradient#N" tag handle
    cdef object __weakref__

    def __init__(self, colors, angle=0.0, layer=1, mirror=False):
        cdef list parsed = []
        cdef GradColor* stops
        cdef int i, n
        cdef object c
        if isinstance(colors, (str, bytes)) or not hasattr(colors, "__iter__"):
            raise TypeError("gradient() expects a list of RGB tuples, e.g. [(255, 0, 0), (0, 0, 255)]")
        for c in colors:
            if not isinstance(c, (tuple, list)) or len(c) not in (3, 4):
                raise TypeError(f"gradient color {c!r} is not an (R, G, B) tuple")
            if not all(isinstance(v, int) and 0 <= v <= 255 for v in c[:3]):
                raise ValueError(f"gradient color {c!r}: each channel must be an int 0-255")
            parsed.append((c[0], c[1], c[2]))
        if not parsed:
            raise ValueError("gradient() needs at least one color")
        if isinstance(angle, bool) or not isinstance(angle, (int, float)):
            raise TypeError(f"gradient angle must be a number of degrees (e.g. 45) or "
                            f"gradient.UP / DOWN / LEFT / RIGHT, got {angle!r}")
        if isinstance(layer, _GradLength):
            self._length = <_GradLength>layer
        elif isinstance(layer, bool) or not isinstance(layer, int):
            raise TypeError(f"gradient layer must be a number of sweeps (e.g. 3) or a length: "
                            f"gradient.px(60) / gradient.em(2), got {layer!r}")
        elif not 1 <= layer <= 256:
            raise ValueError(f"gradient layer must be between 1 and 256, got {layer}")
        if not isinstance(mirror, bool):
            raise TypeError(f"gradient mirror must be True or False, got {mirror!r}")

        self.colors = tuple(parsed)
        self.angle = float(angle) % 360.0
        self.layer = layer
        self.mirror = mirror
        self._packed_shifts = None
        self._hash = hash((self.colors, self.angle, self.layer, self.mirror))
        global _gradient_handle_counter
        cdef tuple key = (self.colors, self.angle, self.layer, self.mirror)
        cdef object h = _GRADIENT_KEY_HANDLE.get(key)
        if h is None:
            _gradient_handle_counter += 1
            h = _gradient_handle_counter
            _GRADIENT_KEY_HANDLE[key] = h
        self.handle = h
        _GRADIENT_HANDLES[self.handle] = self
        _GRADIENT_RECENT[self.handle] = self
        _GRADIENT_RECENT.move_to_end(self.handle)
        while len(_GRADIENT_RECENT) > _GRADIENT_RECENT_MAX:
            _GRADIENT_RECENT.popitem(last=False)
        if len(_GRADIENT_KEY_HANDLE) > 4 * _GRADIENT_RECENT_MAX:
            # Keep the key map bounded too: drop keys whose gradients are gone.
            for k in [k for k, v in _GRADIENT_KEY_HANDLE.items()
                      if v not in _GRADIENT_RECENT and v not in _GRADIENT_HANDLES]:
                del _GRADIENT_KEY_HANDLE[k]

        n = len(parsed)
        stops = <GradColor*>malloc(n * sizeof(GradColor))
        if stops == NULL:
            raise MemoryError()
        for i in range(n):
            stops[i].r = <unsigned char><int>parsed[i][0]
            stops[i].g = <unsigned char><int>parsed[i][1]
            stops[i].b = <unsigned char><int>parsed[i][2]
        if self._length is not None:
            # The table holds ONE period of the repeating pattern: a single
            # sweep, or sweep + reversed sweep when mirrored.
            grad_build_lut(stops, n, 2 if mirror else 1, self.mirror, self.lut)
        else:
            grad_build_lut(stops, n, <int>layer, self.mirror, self.lut)
        free(stops)

    def __eq__(self, other):
        if not isinstance(other, Gradient):
            return NotImplemented
        return (self.colors == (<Gradient>other).colors and self.angle == (<Gradient>other).angle
                and self.layer == (<Gradient>other).layer and self.mirror == (<Gradient>other).mirror)

    def __hash__(self):
        return self._hash

    def __str__(self):
        """The gradient's tag handle, so it can go straight into a color tag
        through an f-string (double the tag's own braces there):
            font.render(f"<color({fire})={{HOT}}> text", 24)
        repr() still shows the full definition."""
        return f"gradient#{self.handle}"

    def __repr__(self):
        extra = ""
        if self.layer != 1:
            extra += f", layer={self.layer!r}"
        if self.mirror:
            extra += ", mirror=True"
        return f"gradient({list(self.colors)!r}, {self.angle:g}{extra})"

    cdef double period_px(self, int font_size):
        """Pixels covered by the whole color table for a length layer
        (px / em, doubled when mirrored); 0 for an int layer (stretch)."""
        cdef double sweep
        if self._length is None:
            return 0.0
        sweep = self._length.value * (font_size if self._length.unit == 2 else 1)
        return sweep * (2 if self.mirror else 1)

    cdef const unsigned int* packed_for(self, tuple shifts):
        """The color table as pixels for a surface with these channel
        shifts (alpha left 0 — the caller ORs in coverage)."""
        cdef int i
        cdef unsigned int s_r, s_g, s_b
        if self._packed_shifts != shifts:
            s_r = <unsigned int>shifts[0]
            s_g = <unsigned int>shifts[1]
            s_b = <unsigned int>shifts[2]
            for i in range(GRAD_LUT_SIZE):
                self._packed[i] = ((<unsigned int>self.lut[i * 3] << s_r) |
                                   (<unsigned int>self.lut[i * 3 + 1] << s_g) |
                                   (<unsigned int>self.lut[i * 3 + 2] << s_b))
            self._packed_shifts = shifts
        return self._packed


# gradient#N handles (see Gradient.__str__) -> Gradient objects.
#   - Equal gradients share one handle, so f"<color({gradient([...])})=...>"
#     rebuilt every frame yields the SAME text (render caches keep hitting).
#   - The most recently created handles are held strongly (bounded LRU): a
#     gradient built inline inside an f-string is a temporary that would
#     otherwise be garbage-collected before render() ever resolves it.
#   - Anything the program still references also resolves (weak map).
_GRADIENT_HANDLES = weakref.WeakValueDictionary()
_GRADIENT_RECENT = OrderedDict()   # handle -> Gradient, strong, bounded
_GRADIENT_KEY_HANDLE = {}          # (colors, angle, layer, mirror) -> handle
cdef int _GRADIENT_RECENT_MAX = 1024
cdef long _gradient_handle_counter = 0

cdef object _resolve_gradient(long handle, object default):
    cdef object g = _GRADIENT_RECENT.get(handle)
    if g is None:
        g = _GRADIENT_HANDLES.get(handle)
    return default if g is None else g


# Public name: the class itself, so gradient([...]) builds one and
# gradient.UP / DOWN / LEFT / RIGHT need no extra imports.
gradient = Gradient


# ---------------------------------------------------------------------------
# Color tags that name a variable: "<color(ORANGE)={...}>", "[color=theme.gold]".
# The name is looked up where render() was called from (its local, then
# global variables — the way Python itself resolves a name; dotted names
# follow attributes), and replaced in the text by the value's tag form:
# "(R,G,B)" for a tuple / pygame.Color, "gradient#N" for a gradient. The
# result is what render()'s caches are keyed on, so changing the variable's
# value changes the rendered color.
# ---------------------------------------------------------------------------
cdef str _NAME = r"[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*"
_TAG_CMD_RE = re.compile(r"<[^<>{}]{1,64}?=\{")
_COLOR_NAME_RE = re.compile(
    r"((?i:color)\(\s*)(" + _NAME + r")(\s*\))"            # color(NAME)
    r"|(\[\s*(?i:color)\s*=\s*)(" + _NAME + r")(\s*\])")  # [color=NAME]
_WARNED_COLOR_NAMES = set()

cdef object _lookup_name(str dotted, object frame):
    cdef list parts = dotted.split(".")
    cdef object obj, attr
    cdef object f_locals = frame.f_locals
    cdef object f_globals = frame.f_globals
    if parts[0] in f_locals:
        obj = f_locals[parts[0]]
    elif parts[0] in f_globals:
        obj = f_globals[parts[0]]
    else:
        return _NO_PATH
    for attr in parts[1:]:
        obj = getattr(obj, attr, _NO_PATH)
        if obj is _NO_PATH:
            return _NO_PATH
    return obj

cdef object _color_tag_value(object value):
    """A looked-up variable as tag text, or None if it isn't a color."""
    if isinstance(value, Gradient):
        return str(value)
    if isinstance(value, pygame.Color):
        return f"({value.r},{value.g},{value.b})"
    if (isinstance(value, (tuple, list)) and len(value) in (3, 4)
            and all(isinstance(v, int) and not isinstance(v, bool) and 0 <= v <= 255 for v in value)):
        return f"({value[0]},{value[1]},{value[2]})"
    return None

# text -> None (no named colors) or (parts, names): the text split around each
# variable name found in a color tag. Built once per distinct text, so the
# per-call work is just looking the names up — a regex pass per render() cost
# ~6-10us even on a cache hit.
_COLOR_TEMPLATES = {}
cdef int _COLOR_TEMPLATES_MAX = 4096

cdef object _build_color_template(str text):
    cdef list parts = [], names = []
    cdef Py_ssize_t pos = 0, tag_start, a, b
    cdef int grp
    for tag_m in _TAG_CMD_RE.finditer(text):
        tag_start = tag_m.start()
        for m in _COLOR_NAME_RE.finditer(tag_m.group(0)):
            grp = 2 if m.group(2) else 5
            a = tag_start + m.start(grp)
            b = tag_start + m.end(grp)
            parts.append(text[pos:a])
            names.append(m.group(grp))
            pos = b
    if not names:
        return None
    parts.append(text[pos:])
    return (tuple(parts), tuple(names))

cdef str _expand_color_names(str text, object frame):
    """Replaces variable names in color tags with their values (see above)."""
    cdef object tpl = _COLOR_TEMPLATES.get(text, _NO_PATH)
    cdef tuple parts, names
    cdef list out
    cdef Py_ssize_t i
    cdef object name, value, tag_value
    if tpl is _NO_PATH:
        tpl = _build_color_template(text)
        if len(_COLOR_TEMPLATES) >= _COLOR_TEMPLATES_MAX:
            _COLOR_TEMPLATES.clear()
        _COLOR_TEMPLATES[text] = tpl
    if tpl is None:
        return text
    parts = (<tuple>tpl)[0]
    names = (<tuple>tpl)[1]
    out = [parts[0]]
    for i in range(len(names)):
        name = names[i]
        value = _lookup_name(<str>name, frame)
        tag_value = None if value is _NO_PATH else _color_tag_value(value)
        if tag_value is None:
            if name not in _WARNED_COLOR_NAMES:
                _WARNED_COLOR_NAMES.add(name)
                why = "is not defined" if value is _NO_PATH else f"is not a color: {value!r}"
                print(f"[WARNING] color tag: '{name}' {why} — the tag's color is ignored.")
            tag_value = name   # left as-is: the parser then ignores this color
        out.append(tag_value)
        out.append(parts[i + 1])
    return "".join(out)


cdef object _palette_key():
    """Hashable snapshot of RICH_PALETTE (for the parsed-runs cache key)."""
    return tuple([(k, tuple(v)) for k, v in RICH_PALETTE.items()])


# get_debug_info()'s (script, script_tag) for characters that aren't shaped.
# One shared object: the template cache there keys on its id().
cdef tuple _DBG_NO_SCRIPT = ("-", "-")


# (font path, face index) -> tabular digit cell width in font units: the
# widest of 0-9 shaped alone with 'tnum' on (fonts are shared process-wide).
cdef dict _TNUM_CELLS = {}


cdef int _tnum_cell(size_t hb_font_ptr, str real_path, int index):
    """Width every digit gets inside a [tnum] / tnum tag. For a font whose
    'tnum' feature gives equal-width digits this is exactly their width, so
    nothing moves; for fonts without real tabular digits (Georgia) or that
    kern digit pairs (Arial's "11") it is what makes the digits equal."""
    global _hb_shape_buf
    cdef tuple key = (real_path, index)
    cdef object v = _TNUM_CELLS.get(key)
    cdef hb_feature_t feat
    cdef unsigned int code, n = 0, cell = 0
    cdef hb_glyph_position_t* positions
    if v is not None:
        return <int>v
    if _hb_shape_buf == NULL:
        _hb_shape_buf = hb_buffer_create()
    feat.tag = 0x746E756D          # 'tnum'
    feat.value = 1
    feat.start = 0
    feat.end = <unsigned int>-1
    for code in range(0x30, 0x3A):
        hb_buffer_clear_contents(_hb_shape_buf)
        hb_buffer_add_utf32(_hb_shape_buf, &code, 1, 0, 1)
        hb_buffer_set_direction(_hb_shape_buf, HB_DIRECTION_LTR)
        hb_buffer_guess_segment_properties(_hb_shape_buf)
        hb_shape(<hb_font_t*>hb_font_ptr, _hb_shape_buf, &feat, 1)
        positions = hb_buffer_get_glyph_positions(_hb_shape_buf, &n)
        if n >= 1 and <unsigned int>positions[0].x_advance > cell:
            cell = <unsigned int>positions[0].x_advance
    _TNUM_CELLS[key] = <int>cell
    return <int>cell


cdef int _direction_code(str direction) except -1:
    """render()'s direction= as a cp_itemize() base direction."""
    if direction == "auto":
        return CP_DIR_AUTO
    if direction == "ltr":
        return CP_DIR_FORCE_LTR
    if direction == "rtl":
        return CP_DIR_FORCE_RTL
    raise ValueError(f'direction must be "auto", "ltr" or "rtl", got {direction!r}')


cdef tuple _normalize_color(object color):
    """render()'s color as an (R, G, B[, A]) tuple — lists are accepted too."""
    if isinstance(color, list) and len(color) in (3, 4):
        return tuple(color)
    raise TypeError(f"color must be an (R, G, B) tuple or a gradient(...), got {color!r}")


cdef class _GlyphBitmap:
    """One rasterized glyph (8-bit coverage or 1-bit mono, no color).
    C fields instead of a 7-tuple: reading them in the render loop is a
    plain struct access, with no Python int unboxing per glyph."""
    cdef int w, h, pitch, left, top, pixel_mode
    cdef bytes data


cdef extern from "c_bitmapfont.h":
    ctypedef struct DfbmpGlyphEntry:
        unsigned int codepoint
        const unsigned char* bits
    ctypedef struct DfbmpFont:
        unsigned int glyph_count
        unsigned short cell_w
        unsigned short cell_h
        unsigned short baseline
        unsigned short gap
        DfbmpGlyphEntry* glyphs
    DfbmpFont* dfbmp_load_memory(const unsigned char* data, long size) nogil
    void dfbmp_free(DfbmpFont* font) nogil


cdef class _BitmapFont:
    """A loaded .dfbmp (v3) bitmap font: a fixed cell of cell_w x cell_h
    pixels per character, the baseline `baseline` rows below the cell top.
    One bit of the file is one screen pixel at 1x; at scale s every bit
    becomes an s x s block (2x: 2x2 px, 3x: 3x3 px...) — only whole-number
    scales, so pixels stay square and sharp. The pen moves one cell plus
    the font's gap ((cell_w + gap) * s) per character."""
    cdef DfbmpFont* font
    cdef dict index      # codepoint -> glyph index
    cdef dict scaled     # (glyph index, scale) -> bytes: 8-bit coverage, cell_w*s x cell_h*s
    cdef int cell_w, cell_h, baseline, gap

    def __cinit__(self):
        self.font = NULL
        self.index = {}
        self.scaled = {}

    def __dealloc__(self):
        if self.font != NULL:
            dfbmp_free(self.font)
            self.font = NULL

    cdef int scale_for(self, int size):
        """render()'s size (a height in pixels, compared with the cell
        height) -> the nearest whole scale, at least 1x."""
        cdef int s = (size + self.cell_h // 2) // self.cell_h
        return s if s >= 1 else 1

    cdef bytes glyph(self, int idx, int s):
        """Glyph idx's bits as 8-bit coverage (0 / 255), each bit an s x s block."""
        cdef tuple key = (idx, s)
        cdef object v = self.scaled.get(key)
        cdef DfbmpGlyphEntry* e = &self.font.glyphs[idx]
        cdef int w = self.cell_w, h = self.cell_h, sw = self.cell_w * s, x, y, k, bit
        cdef unsigned char* buf
        cdef unsigned char* row
        cdef bytes out
        if v is not None:
            return <bytes>v
        buf = <unsigned char*>malloc(<size_t>(sw * h * s) if sw * h * s > 0 else 1)
        if buf == NULL:
            raise MemoryError()
        for y in range(h):
            row = buf + <size_t>(y * s) * sw
            for x in range(w):
                bit = y * w + x
                memset(row + x * s, 255 if (e.bits[bit >> 3] & (0x80 >> (bit & 7))) else 0, s)
            for k in range(1, s):
                memcpy(row + <size_t>k * sw, row, sw)
        out = (<char*>buf)[:sw * h * s]
        free(buf)
        if len(self.scaled) >= MAX_GLYPH_CACHE:
            self.scaled.clear()
        self.scaled[key] = out
        return out


cdef dict _DFBMP_POOL = {}   # absolute path -> _BitmapFont (shared by every DynamicFont)


cdef _BitmapFont _load_dfbmp(str path):
    """Loads (once per process) a .dfbmp font; ValueError if it isn't one."""
    cdef str key = os.path.abspath(path)
    cdef _BitmapFont bf = _DFBMP_POOL.get(key)
    cdef bytes data
    cdef DfbmpFont* f
    cdef unsigned int i
    if bf is not None:
        return bf
    try:
        with open(path, 'rb') as fh:
            data = fh.read()
    except OSError as e:
        raise ValueError(f"can't open the .dfbmp font {path!r}: {e}")
    f = dfbmp_load_memory(<const unsigned char*><const char*>data, <long>len(data))
    if f == NULL:
        raise ValueError(f"{path!r} is not a valid .dfbmp font (format version 3 — "
                         f"older files can be converted with dfbmp_builder's \"Open .dfbmp\")")
    bf = _BitmapFont()
    bf.font = f
    bf.cell_w = f.cell_w
    bf.cell_h = f.cell_h
    bf.baseline = f.baseline
    bf.gap = f.gap
    for i in range(f.glyph_count):
        bf.index.setdefault(<int>f.glyphs[i].codepoint, <int>i)   # a duplicated character: the first one wins
    _DFBMP_POOL[key] = bf
    return bf


cdef class _RunLayout:
    """A shaped + glyph-resolved run, ready to be drawn anywhere
    (see DynamicFont._layout_run / _draw_layout)."""
    cdef GlyphMeta* g_meta      # malloc'd, owned
    cdef Py_ssize_t n           # glyphs to draw (0 = nothing / surf-only)
    cdef list keep_alive        # bitmap bytes that g_meta[].buf points into
    cdef double start_x         # shift so ink left of the pen origin stays >= 0
    cdef int baseline_y, final_h, ink_w, logic_w
    cdef int ink_top, ink_bot   # vertical ink extent (surface rows) — a gradient's vertical span
    cdef int size               # font pixel size (gradient.em() lengths)
    cdef bint has_ink           # False for runs with no visible glyphs (spaces)
    cdef object surf            # pre-rendered Surface (emoji / failure), else None

    def __cinit__(self):
        self.g_meta = NULL
        self.n = 0
        self.keep_alive = []
        self.surf = None

    def __dealloc__(self):
        if self.g_meta != NULL:
            free(self.g_meta)
            self.g_meta = NULL


cdef FT_Face _pool_ft_face(str real_path, int index) noexcept:
    """Shared FT_Face for (path, index); NULL (no exception) if it can't be opened."""
    cdef tuple key = (real_path, max(0, index))
    cdef object cached_val = _FT_FACE_POOL.get(key)
    cdef FT_Face face_ptr = NULL
    cdef bytes path_bytes

    if real_path is None:
        return NULL
    if cached_val is not None:
        if <size_t>cached_val == 0:
            return NULL
        return <FT_Face><void*><size_t>cached_val
    try:
        path_bytes = _fs_path_bytes(real_path)
        if FT_New_Face(_ensure_ft_library(), path_bytes, max(0, index), &face_ptr) != 0:
            face_ptr = NULL
    except Exception:
        face_ptr = NULL
    _FT_FACE_POOL[key] = <size_t>face_ptr
    return face_ptr

cdef object _pool_hb_font(str real_path, int index):
    """Shared (hb_font_t* as int, upem) for (path, index), or None if the file
    can't be loaded (failures are remembered, so a bad file is reported
    once). The font file is memory-mapped by HarfBuzz — not read into RAM —
    and the font lives for the rest of the process, like the FT_Face pool."""
    cdef tuple key = (real_path, index)
    cdef object cached = _HB_FONT_POOL.get(key)
    cdef bytes path_bytes
    cdef hb_blob_t* blob
    cdef hb_face_t* face
    cdef hb_font_t* font
    if real_path is None or cached is False:
        return None
    if cached is not None:
        return cached
    # HarfBuzz takes UTF-8 paths on Windows too (it converts to UTF-16 and
    # opens with CreateFileW), so non-ASCII paths work as-is.
    path_bytes = real_path.encode("utf-8") if _IS_WIN else os.fsencode(real_path)
    blob = hb_blob_create_from_file_or_fail(path_bytes)
    if blob == NULL:
        print(f"Error loading HarfBuzz font at {real_path}, (index {index}): cannot open file")
        _HB_FONT_POOL[key] = False
        return None
    # A .ttc collection holds several faces; index selects one.
    face = hb_face_create(blob, max(0, index))
    hb_blob_destroy(blob)          # the face keeps its own reference
    if hb_face_get_glyph_count(face) == 0:
        hb_face_destroy(face)
        print(f"Error loading HarfBuzz font at {real_path}, (index {index}): not a usable font")
        _HB_FONT_POOL[key] = False
        return None
    font = hb_font_create(face)    # default scale = upem, built-in OpenType funcs
    cached = (<size_t>font, hb_face_get_upem(face))
    hb_face_destroy(face)          # the font keeps its own reference
    _HB_FONT_POOL[key] = cached
    return cached



cdef class DynamicFont:
    """(primary_name, fallback_name, fallback_dir, emoji_path, init_face)
    Intalize DynamicFont Object to Render -> Compas"""
    cdef str primary_name, fallback_name, fallback_dir, emoji_path
    cdef object _primary_path   # [path, index] if primary is a bundled file
    cdef object _fallback_path  # [path, index] if fallback is a bundled file
    cdef bint _anti_alias       # set at init time, doesn't change at runtime
    cdef _BitmapFont _bmp       # primary font when it is a .dfbmp bitmap font, else None
    cdef bint _sync_size        # SYNC_FONT_SIZE, set at init time
    cdef unsigned long _palette_gen   # _PALETTE_GEN when the caches were last in step with RICH_PALETTE
    cdef _LRUCache _font_objs
    # face -> {codepoint: font path}. Plain dicts keyed by int (no tuple key
    # allocated per character); each face's map is reset if it outgrows
    # MAX_PATH_CACHE.
    cdef dict _path_maps
    cdef dict _ascii_paths   # (face, primary_space) -> font covering all printable ASCII, or None
    cdef dict _space_paths   # face -> fallback font path used for spaces, or None
    # (run text, font path, index) -> packed int32 [glyph_id, x_advance,
    # x_offset, y_offset] * n from HarfBuzz. Shaping depends only on text +
    # font, so a repeated run skips HarfBuzz AND the ~2 Python objects per
    # glyph that reading its output creates.
    cdef _LRUCache _shape_cache
    # (run text, font path, size, face, aa_toggle) -> _RunLayout. A layout
    # holds no color, so a run that repeats between frames ("HP:", "/",
    # spaces, words that didn't change) is drawn without re-doing any of
    # the per-run setup, shaping lookup or per-glyph cache lookups.
    cdef _LRUCache _layout_cache
    # (text, color, face, use_primary_space, direction) -> the run list from
    # _parse_render_accumulate. Tag parsing, BiDi / script itemization and
    # the per-character font split depend on nothing else, so a line that is
    # re-rendered (dynamic=True labels, dialogue, menus) skips all of it.
    cdef _LRUCache _runs_cache
    # (glyph_id, size, italic) -> (Surface|None, top, left) for color emoji.
    cdef _LRUCache _emoji_cache
    cdef dict _pg_font_cache
    cdef dict _std_metrics, _font_map, _path_resolve_cache
    cdef list _intl_font_paths
    cdef public dict emoji_fallback_engine
    cdef FT_Face _emoji_ft_face      # real FT_Face pointer from _FT_FACE_POOL (not owned)
    cdef bint _emoji_colr_checked   # whether the emoji font's COLR support has been checked
    cdef bint _emoji_has_colr       # result: emoji font DOES support COLRv0
    cdef bint _emoji_has_colrv1     # result: emoji font DOES support COLRv1 (Solid + LinearGradient)
    cdef bint _emoji_has_cbdt       # result: emoji font DOES support CBDT (embedded PNG bitmap)
    # _glyph_cache: packed int key (face, size, mode, glyph_id) -> rasterized
    # glyph bitmap (_GlyphBitmap, no color), sized by MAX_GLYPH_CACHE. Keyed by
    # the SHAPED glyph id rather than the character, so it serves every
    # render path and script (combining marks, ligatures, Arabic joining
    # forms) and one entry is shared by all colors — re-rendering text never
    # re-runs FreeType's hinting + rasterizer for a glyph it has seen.
    # (It used to hold per-character colored Surfaces for the ASCII fast
    # path only.)
    # _text_cache: finished Surfaces for static (dynamic=False) text.
    cdef public _LRUCache _glyph_cache, _text_cache
    cdef bint _initialized
    cdef object _cached_p_path
    cdef object _cached_f_path_std
    cdef public str init_face
    

    def __init__(self, 
                 primary_name="Arial", 
                 fallback_name=None, 
                 fallback_dir=None, 
                 emoji_path=None,
                 init_face="regular"):
        # fallback_dir/emoji_path/fallback_name default to None (not a
        # hardcoded value) specifically so "the caller didn't specify
        # this" is unambiguous — auto-detection only kicks in for the
        # genuine default case, never silently overriding a value the
        # caller actually passed (including an intentional empty
        # string, which stays as-is rather than being auto-replaced).
        if fallback_dir is None:
            fallback_dir = _get_bundled_fallback_dir()
        if emoji_path is None:
            emoji_path = _auto_detect_emoji_path()
        if fallback_name is None:
            # "Times New Roman" (the previous default) is a Windows-
            # bundled font with no guaranteed presence on Linux/macOS —
            # pointing at the package's own bundled Noto Sans CJK
            # instead means the default actually works identically on
            # every OS out of the box, consistent with this project's
            # own "Zero-Configuration Fonts" goal rather than working
            # against it.
            # Prefer the CALLER's fallback_dir when it has the file — the
            # default used to always point into the package directory, even
            # when the caller supplied their own fallback_dir.
            fallback_name = os.path.join(fallback_dir, "NotoSansCJK-Regular.ttc") if fallback_dir else ""
            if not os.path.isfile(fallback_name):
                fallback_name = os.path.join(_get_bundled_fallback_dir(), "NotoSansCJK-Regular.ttc")

        # 1. INPUT SANITIZATION
            # Detect if primary/fallback is a bundled file path -> don't strip the name
        cdef object _p_parsed, _f_parsed
        cdef bint _p_is_path, _f_is_path

        _p_parsed, _p_is_path = _parse_font_input(primary_name)
        if _p_is_path:
            # primary_name is a file path -> store directly, skip get_family_root
            self.primary_name   = _p_parsed[0]  # path string for identification
            self._primary_path  = _p_parsed      # [path, index] to load
        else:
            self.primary_name   = get_family_root(primary_name)
            self._primary_path  = None

        _f_parsed, _f_is_path = _parse_font_input(fallback_name)
        if _f_is_path:
            self.fallback_name  = _f_parsed[0]
            self._fallback_path = _f_parsed
        else:
            self.fallback_name  = get_family_root(fallback_name)
            self._fallback_path = None

        self.fallback_dir  = fallback_dir
        self.emoji_path    = emoji_path

        # .dfbmp bitmap fonts: primary font only (the fallback must be able
        # to draw any character, which a bitmap font can't).
        if self._fallback_path is not None and str(self._fallback_path[0]).lower().endswith(".dfbmp"):
            raise ValueError("a .dfbmp bitmap font can only be the primary font (primary_name)")
        self._bmp = None
        if self._primary_path is not None and str(self._primary_path[0]).lower().endswith(".dfbmp"):
            self._bmp = _load_dfbmp(str(self._primary_path[0]))
        self._sync_size = True
        self._palette_gen = _PALETTE_GEN
        self._anti_alias   = True  # snapshot from ANTI_ALIAS at _ensure_init time
        self._emoji_ft_face      = NULL
        self._emoji_colr_checked = False
        self._emoji_has_colr     = False
        self._emoji_has_colrv1   = False
        self._emoji_has_cbdt     = False
        
        # 2. FACE EXTRACTION: Safely extract font face without regular expressions
        # primary_name.strip() below requires a STRING — but primary_name
        # can also legitimately be a [path, index] list (TTC index),
        # which has no .strip() at all. Safe fallback: use
        # self.primary_name (always a plain string by this point)
        # instead, since the face-suffix-extraction logic below is only
        # meaningful when _p_is_path is False anyway (a list input
        # always sets _p_is_path True, so p_clean's value doesn't affect
        # anything in that branch regardless of which fallback is used).
        cdef str p_clean = primary_name.strip() if isinstance(primary_name, str) else self.primary_name
        cdef str extracted_face = "regular"
        if not _p_is_path and len(self.primary_name) < len(p_clean):
            extracted_face = p_clean[len(self.primary_name):].strip("-").strip().lower()
            if not extracted_face:
                extracted_face = "regular"
                
        # Prioritize explicitly passed init_face, otherwise use the extracted one
        if init_face != "regular":
            self.init_face = init_face.lower()
        else:
            self.init_face = extracted_face

        # Core Engine States & Memory Caches
        self._font_objs = _LRUCache(MAX_FONT_OBJ_CACHE)
        self._path_maps = {}
        self._ascii_paths = {}
        self._space_paths = {}
        self._shape_cache = _LRUCache(MAX_SHAPE_CACHE)
        self._layout_cache = _LRUCache(MAX_LAYOUT_CACHE)
        self._runs_cache = _LRUCache(MAX_RUNS_CACHE)
        self._emoji_cache = _LRUCache(MAX_EMOJI_CACHE)
        self._pg_font_cache = {}
        self._std_metrics = {}
        self._glyph_cache = _LRUCache(MAX_GLYPH_CACHE)
        self._text_cache  = _LRUCache(MAX_TEXT_CACHE)
        self._font_map = {}
        self._path_resolve_cache = {}
        self._intl_font_paths = []
        self._initialized = False
        self.emoji_fallback_engine = {}

    cdef void _ensure_init(self):
        """Lazy initialization: Scans system fonts only when the first render is called."""
        if self._initialized: return
        self._font_map = load_or_update_font_map()

        cdef str check_p = ""
        cdef object check_f_path
        if self._fallback_path is not None and not os.path.isfile(self._fallback_path[0]):
            # A fallback given as a FILE path that doesn't exist used to be
            # kept anyway — every render then retried (and failed) to open
            # it, printing a HarfBuzz load error per space-run per frame.
            self._fallback_path = None
            self.fallback_name = ""
        elif self._fallback_path is None:
            check_f_path = self._get_true_path(self.fallback_name, self.init_face)
            if check_f_path:
                if isinstance(check_f_path, (list, tuple)):
                    check_p = <str>check_f_path[0]
                else:
                    check_p = <str>check_f_path
                if not os.path.exists(check_p):
                    self.fallback_name = ""

        if self.fallback_dir and os.path.isdir(self.fallback_dir):
            # sorted(): os.listdir order is filesystem-dependent (arbitrary
            # on ext4), so which intl font won for a given character used
            # to differ between machines.
            self._intl_font_paths = [os.path.join(self.fallback_dir, f)
                                     for f in sorted(os.listdir(self.fallback_dir))
                                     if f.lower().endswith((".ttf", ".otf", ".ttc"))]
        self._anti_alias = <bint>ANTI_ALIAS
        self._sync_size = <bint>SYNC_FONT_SIZE
        self._initialized = True

    cdef void _ensure_emoji_face(self):
        """Opens the emoji font's FT_Face once (shared by the COLRv1, COLRv0
        and CBDT paths). The has_* flags start optimistic and self-correct
        to False on the first real "not supported" result from each renderer."""
        if self._emoji_colr_checked:
            return
        self._emoji_colr_checked = True
        self._emoji_ft_face = NULL
        self._emoji_has_colr = False
        self._emoji_has_colrv1 = False
        self._emoji_has_cbdt = False
        if not self.emoji_path:
            return
        self._emoji_ft_face = _pool_ft_face(self.emoji_path, 0)
        if self._emoji_ft_face != NULL:
            self._emoji_has_colr = True
            self._emoji_has_colrv1 = True
            self._emoji_has_cbdt = True

    cdef tuple _render_colrv1_emoji(self, str ch, int size, bint apply_italic=False):
        """Try to render emoji via COLRv1 using render_colrv1_glyph() in
        pure C. Returns (pygame.Surface, top) on success — `top` is the
        device-pixel distance from baseline to the surface's top row
        (see colrv1_render.h), needed for correct positioning since the
        surface is a TIGHT crop, not always anchored the same way as a
        simple single glyph. Returns (None, 0) if the font has no COLRv1
        paint for this glyph OR the paint graph uses an unsupported
        feature — the caller then falls back to COLRv0, then pygame.font.

        Shares the SAME self._emoji_ft_face as _render_colrv0_emoji (same
        font file, one FT_New_Face call total) — relies on that method's
        init block having already run, or runs it itself if called first."""
        cdef int code = ord(ch)
        cdef unsigned int glyph_index
        cdef unsigned char* rgba_buf = NULL
        cdef int w = 0, h = 0, top = 0, left = 0
        cdef int result
        cdef object surf

        self._ensure_emoji_face()

        if not self._emoji_has_colrv1 or self._emoji_ft_face == NULL:
            return None, 0, 0

        FT_Set_Pixel_Sizes(self._emoji_ft_face, 0, size)
        glyph_index = FT_Get_Char_Index(self._emoji_ft_face, code)
        if glyph_index == 0:
            return None, 0, 0

        result = render_colrv1_glyph(
            self._emoji_ft_face, glyph_index, <int>apply_italic, &rgba_buf, &w, &h, &top, &left
        )

        if result != 0 or rgba_buf == NULL or w <= 0 or h <= 0:
            # NOTE: unlike COLRv0, do NOT disable _emoji_has_colrv1 on a
            # single glyph failure — result==3 ("unsupported feature in
            # THIS glyph's paint graph") is expected and common (radial/
            # sweep gradients, etc.), and does not mean the FONT lacks
            # COLRv1 support overall. Other glyphs in the same font may
            # still succeed. Only a hard FT_New_Face-level failure (above)
            # disables it permanently.
            return None, 0, 0

        surf = _rgba_to_surface(rgba_buf, w, h)
        return surf, top, left

    cdef tuple _render_colrv1_by_id(self, unsigned int glyph_id, int size, bint apply_italic=False):
        """Same as _render_colrv1_emoji but takes an ALREADY-RESOLVED glyph
        ID directly (e.g. from HarfBuzz shaping a ZWJ ligature sequence),
        skipping the FT_Get_Char_Index step. Caller must ensure the emoji
        face is already loaded (self._emoji_ft_face != NULL) — used by
        _render_emoji_run's shaped-ZWJ path, which triggers init via a
        throwaway _render_colrv1_emoji call first."""
        cdef unsigned char* rgba_buf = NULL
        cdef int w = 0, h = 0, top = 0, left = 0
        cdef int result
        cdef object surf

        if not self._emoji_has_colrv1 or self._emoji_ft_face == NULL or glyph_id == 0:
            return None, 0, 0

        FT_Set_Pixel_Sizes(self._emoji_ft_face, 0, size)
        result = render_colrv1_glyph(self._emoji_ft_face, glyph_id, <int>apply_italic, &rgba_buf, &w, &h, &top, &left)
        if result != 0 or rgba_buf == NULL or w <= 0 or h <= 0:
            return None, 0, 0

        surf = _rgba_to_surface(rgba_buf, w, h)
        return surf, top, left

    cdef tuple _render_colrv0_emoji(self, str ch, int size, bint apply_italic=False):
        """Try to render emoji via COLRv0 using render_colrv0_glyph() in
        pure C. Returns (pygame.Surface, top) if successful — see
        _render_colrv1_emoji's docstring for what `top` means and why.
        Returns (None, 0) if the font doesn't support COLR or the glyph
        has no color layer — the caller then falls back to pygame.font.

        Does NOT use freetype-py — calls FT_New_Face/FT_Set_Pixel_Sizes/
        FT_Get_Char_Index directly via cdef extern, statically linked into the .pyd."""
        cdef int code = ord(ch)
        cdef unsigned int glyph_index
        cdef unsigned char* rgba_buf = NULL
        cdef int w = 0, h = 0, top = 0, left = 0
        cdef int result
        cdef object surf

        self._ensure_emoji_face()

        if not self._emoji_has_colr or self._emoji_ft_face == NULL:
            return None, 0, 0

        FT_Set_Pixel_Sizes(self._emoji_ft_face, 0, size)
        glyph_index = FT_Get_Char_Index(self._emoji_ft_face, code)
        if glyph_index == 0:
            return None, 0, 0

        result = render_colrv0_glyph(
            self._emoji_ft_face, glyph_index, <int>apply_italic, &rgba_buf, &w, &h, &top, &left
        )

        if result != 0 or rgba_buf == NULL or w <= 0 or h <= 0:
            if result == 1 or result == 2:
                # Font has no CPAL, or this glyph isn't COLR —
                # mark the font as UNSUPPORTED so we don't retry per character
                self._emoji_has_colr = False
            return None, 0, 0

        surf = _rgba_to_surface(rgba_buf, w, h)
        return surf, top, left

    cdef tuple _render_colrv0_by_id(self, unsigned int glyph_id, int size, bint apply_italic=False):
        """Same as _render_colrv0_emoji but takes an ALREADY-RESOLVED glyph
        ID directly (e.g. from HarfBuzz shaping) — see _render_colrv1_by_id
        for why this exists.

        apply_italic: forwarded straight to render_colrv0_glyph() — see
        colrv0_render.h for why this only affects COLRv0's own vector
        layers (CBDT bitmap emoji are architecturally unable to support
        this, by design, not a bug)."""
        cdef unsigned char* rgba_buf = NULL
        cdef int w = 0, h = 0, top = 0, left = 0
        cdef int result
        cdef object surf

        if not self._emoji_has_colr or self._emoji_ft_face == NULL or glyph_id == 0:
            return None, 0, 0

        FT_Set_Pixel_Sizes(self._emoji_ft_face, 0, size)
        result = render_colrv0_glyph(self._emoji_ft_face, glyph_id, <int>apply_italic, &rgba_buf, &w, &h, &top, &left)
        if result != 0 or rgba_buf == NULL or w <= 0 or h <= 0:
            if result == 1 or result == 2:
                self._emoji_has_colr = False
            return None, 0, 0

        surf = _rgba_to_surface(rgba_buf, w, h)
        return surf, top, left

    cdef tuple _render_cbdt_emoji(self, str ch, int size):
        """Try to render emoji via CBDT (embedded PNG color bitmap) using
        render_cbdt_glyph() in pure C — requires FreeType built WITH PNG
        support (FT_REQUIRE_PNG, linked against libpng+zlib); without it
        FT_Load_Glyph fails with error 1 (mapped from FreeType's own
        error 7, Unimplemented_Feature) and this stays permanently
        disabled for the session. Returns (pygame.Surface, top, left) on
        success, (None, 0, 0) otherwise — caller falls back to
        pygame.font as the final resort.

        CBDT bitmaps only exist at whatever fixed strike size(s) the font
        embeds (e.g. only 109 ppem for NotoColorEmoji's CBDT build) —
        render_cbdt_glyph() picks a strike and, when it is more than 15%
        off, resizes it to `size` itself (Lanczos-3 on premultiplied alpha,
        see cbdt_render.c). Far from the strike, detail is still limited by
        the bitmap — softer than COLRv1/COLRv0's vector output — but without
        the dark fringe a straight-alpha smoothscale used to add."""
        cdef int code = ord(ch)
        cdef unsigned int glyph_index
        cdef unsigned char* rgba_buf = NULL
        cdef int w = 0, h = 0, top = 0, left = 0
        cdef int result
        cdef object surf

        self._ensure_emoji_face()

        if not self._emoji_has_cbdt or self._emoji_ft_face == NULL:
            return None, 0, 0

        glyph_index = FT_Get_Char_Index(self._emoji_ft_face, code)
        if glyph_index == 0:
            return None, 0, 0

        result = render_cbdt_glyph(
            self._emoji_ft_face, glyph_index, size, &rgba_buf, &w, &h, &top, &left
        )
        if result != 0 or rgba_buf == NULL or w <= 0 or h <= 0:
            if result == 1 or result == 5:
                # Hard failure (no CBDT table at all, or FreeType lacks
                # PNG support) — don't retry this font every character.
                self._emoji_has_cbdt = False
            # result==2 (this glyph isn't a color bitmap) does NOT disable
            # the flag — other glyphs in the same font may still have one.
            return None, 0, 0

        surf = _rgba_to_surface(rgba_buf, w, h)
        return surf, top, left

    cdef tuple _render_cbdt_by_id(self, unsigned int glyph_id, int size):
        """Same as _render_cbdt_emoji but takes an ALREADY-RESOLVED glyph
        ID directly (e.g. from HarfBuzz shaping) — see _render_colrv1_by_id
        for why this exists."""
        cdef unsigned char* rgba_buf = NULL
        cdef int w = 0, h = 0, top = 0, left = 0
        cdef int result
        cdef object surf

        if not self._emoji_has_cbdt or self._emoji_ft_face == NULL or glyph_id == 0:
            return None, 0, 0

        result = render_cbdt_glyph(self._emoji_ft_face, glyph_id, size, &rgba_buf, &w, &h, &top, &left)
        if result != 0 or rgba_buf == NULL or w <= 0 or h <= 0:
            if result == 1 or result == 5:
                self._emoji_has_cbdt = False
            return None, 0, 0

        surf = _rgba_to_surface(rgba_buf, w, h)
        return surf, top, left
        
        
    cdef FT_Face _get_shared_ft_face(self, str real_path, int index) noexcept:
        """Master FT_Face Pool — the font file is opened ONCE per process
        (see _FT_FACE_POOL) and the FT_Face reused across all sizes and all
        DynamicFont instances. Returns NULL (no exception) when the file
        can't be opened."""
        return _pool_ft_face(real_path, index)

    cdef object _get_old_engine(self, int size):
        if size not in self.emoji_fallback_engine:
            try:
                # Load fonts using pygame.font to enable color rendering.
                self.emoji_fallback_engine[size] = pygame.font.Font(self.emoji_path, size)
            except Exception as e:
                print(f"[ERROR] Can't load old Emoji Engine: {e}")
                self.emoji_fallback_engine[size] = pygame.font.SysFont("seguiemj", size)
        return self.emoji_fallback_engine[size]

    cdef object _get_true_path(self, str name, str face):
        """O(1) Cached Path Resolution: Eliminates heavy string operations inside the render loop."""
        # CYTHON FIX: Hoist all cdef declarations to the top of the function to comply with C89 standards.
        cdef tuple key
        cdef dict paths, names
        cdef str low_name, face_target1, face_target2, target
        cdef object result = None
        cdef object _direct

        if not name: return None

        key = (name, face)
        if key in self._path_resolve_cache:
            return self._path_resolve_cache[key]

        # Bundled path: primary or fallback passed directly as a file
        if self._primary_path and name == self._primary_path[0]:
            self._path_resolve_cache[key] = self._primary_path
            return self._primary_path
        if self._fallback_path and name == self._fallback_path[0]:
            self._path_resolve_cache[key] = self._fallback_path
            return self._fallback_path

        # Direct file path (not a font name)
        if os.path.exists(name):
            _direct = [name, -1]
            self._path_resolve_cache[key] = _direct
            return _direct
        
        paths = self._font_map.get("paths", {})
        low_name = name.lower()
        
        face_target1 = f"{low_name} {face}".strip()
        face_target2 = f"{low_name}-{face}".strip()
        
        if face_target1 in paths: 
            result = paths[face_target1]
        elif face_target2 in paths: 
            result = paths[face_target2]
        else:
            names = self._font_map.get("names", {})
            target = names.get(low_name, low_name)
            result = paths.get(target, name)
            
        self._path_resolve_cache[key] = result
        return result

    cdef tuple _get_synthetic_flags(self, str face):
        if not face:
            return (False, False)
        return _SYNTHETIC_FACE_MAP.get(face.lower(), (False, False))

    cdef bint _is_synthetic_needed(self, str name, str face, object actual_path=None):
        """True = no real font file exists -> synthetic needed.
        Logic: nếu _get_true_path(name, face) == _get_true_path(name, regular)
               -> the real face wasn't found -> synthetic needed.
        actual_path: path being rendered, used to find the corresponding font_name.
        """
        cdef object path_with_face, path_regular
        cdef str font_name
        if not face:
            return False
        if face.lower() not in _SYNTHETIC_FACE_MAP:
            return False
        # Determine font_name from actual_path if available
        if actual_path is not None:
            # Compare: path of the real face vs. path of regular
            # If equal -> no real face exists -> synthetic needed
            # Use primary_name and fallback_name to check
            path_with_face = self._get_true_path(self.primary_name, face)
            path_regular   = self._get_true_path(self.primary_name, self.init_face)
            if path_with_face != path_regular:
                # Primary has a real face
                # Check whether actual_path is primary
                if actual_path == path_with_face or actual_path == path_regular:
                    return False  # Using primary -> no synthetic needed
            path_with_face = self._get_true_path(self.fallback_name, face)
            path_regular   = self._get_true_path(self.fallback_name, self.init_face)
            if path_with_face != path_regular:
                # Fallback has a real face
                if actual_path == path_with_face or actual_path == path_regular:
                    return False  # Using fallback -> no synthetic needed
            # actual_path isn't primary/fallback (intl font) -> check separately
            # Intl fonts usually have only 1 face -> always needs synthetic
            return True
        # No actual_path -> check by name
        if not name:
            return False
        path_with_face = self._get_true_path(name, face)
        path_regular   = self._get_true_path(name, self.init_face)
        return path_with_face == path_regular

    cdef inline bint _is_bmp_path(self, object path_data):
        """True if path_data is the primary .dfbmp bitmap font."""
        if self._bmp is None or path_data is None:
            return False
        if path_data is self._primary_path:
            return True
        if isinstance(path_data, (list, tuple)):
            return len(path_data) > 0 and path_data[0] == self.primary_name
        return path_data == self.primary_name

    cdef bint _has_glyph(self, object path_data, int code):
        if not path_data: return False
        if self._bmp is not None and self._is_bmp_path(path_data):
            return code in self._bmp.index
        
        # 1. Separate paths and indexes from input data.
        cdef str real_path
        cdef int index = 0
        cdef FT_Face face_obj
        
        if isinstance(path_data, (list, tuple)):
            real_path = path_data[0]
            index = path_data[1]
        else:
            real_path = path_data

        face_obj = self._get_shared_ft_face(real_path, index)
        if face_obj == NULL:
            return False

        return FT_Get_Char_Index(face_obj, <unsigned long>code) != 0

    cdef object _find_best_font_path_code(self, int code, str face, bint primary_space=False):
        """Direct integer codepoint cascade search with immediate O(1) cache check at line 1.
        Prevents millions of heap tuple allocations per minute.

        Whitespace (U+0020 / U+00A0) takes the FALLBACK font's space by
        default, so every space in a line has the same width whichever font
        draws the words around it. primary_space=True (render(...,
        use_primary_space=True)) resolves spaces like any other character
        instead — normally the primary font's own space, which is what keeps
        monospace fonts column-aligned. Either way the rule is applied here,
        in the one per-character font chooser, so the static pipeline, the
        dynamic ASCII fast path and get_debug_info() always agree."""
        cdef object sp_path
        if (code == 0x20 or code == 0xA0) and not primary_space:
            sp_path = self._fallback_space_path(face)
            if sp_path is not None:
                return sp_path

        cdef dict fmap = self._path_maps.get(face)
        cdef object _cached_path
        if fmap is None:
            fmap = {}
            self._path_maps[face] = fmap
        else:
            _cached_path = fmap.get(code, _NO_PATH)
            if _cached_path is not _NO_PATH:
                return _cached_path

        cdef object path = None
        cdef object current_p_path = self._get_true_path(self.primary_name, face)

        # Priority 1: Emoji Handling (pure C codepoint check)
        if is_emoji(code):
            if self._has_glyph(self.emoji_path, code):
                path = self.emoji_path
                
        if not path:
            # Priority 2: Primary Font
            if MODERN_FONT and self._has_glyph(current_p_path, code):
                path = current_p_path
            else:
                # Priority 3: Fallback Layers (Standard -> International)
                path = self._search_fallback_layers(code, face)
                
        if len(fmap) >= MAX_PATH_CACHE:
            fmap.clear()
        fmap[code] = path
        return path

    cdef object _fallback_space_path(self, str face):
        """Fallback font path used for spaces (per face), or None when there
        is no usable fallback (then spaces resolve like other characters)."""
        cdef object v = self._space_paths.get(face, _NO_PATH)
        if v is _NO_PATH:
            v = self._get_true_path(self.fallback_name, face)
            if not v or not self._has_glyph(v, 0x20):
                v = None
            self._space_paths[face] = v
        return v

    cdef object _ascii_word_path(self, str face):
        """The font path that every printable non-space ASCII character
        (0x21-0x7E) resolves to for this face, or None if they're split
        across fonts. Resolved once per face."""
        cdef tuple key = (face, "words")
        cdef object v = self._ascii_paths.get(key, _NO_PATH)
        cdef int c
        if v is _NO_PATH:
            v = self._find_best_font_path_code(0x21, face)
            for c in range(0x22, 0x7F):
                if self._find_best_font_path_code(c, face) != v:
                    v = None
                    break
            self._ascii_paths[key] = v
        return v

    cdef list _split_space_runs(self, str text, object word_path, object space_path,
                                object color, str face):
        """Printable-ASCII text whose words and spaces come from two fonts:
        the run list the full pipeline would produce (word / space pieces),
        built directly — no tag parser, no per-character font lookups."""
        cdef list runs = []
        cdef Py_ssize_t i, start = 0, n = len(text)
        cdef bint sp, cur_sp = text[0] == ' '
        for i in range(1, n + 1):
            sp = i < n and text[i] == ' '
            if i == n or sp != cur_sp:
                runs.append((text[start:i], space_path if cur_sp else word_path,
                             color, 0 if cur_sp else 7, face, False, 0, 0, False, 0))
                start = i
                cur_sp = sp
        return runs

    cdef object _ascii_font_path(self, str face, bint primary_space):
        """The font path that ALL printable ASCII (0x20-0x7E) resolves to
        for this face, or None when those characters are split across fonts
        (e.g. spaces from the fallback font). Resolved once per face."""
        cdef tuple key = (face, primary_space)
        cdef object v = self._ascii_paths.get(key, _NO_PATH)
        cdef int c
        if v is _NO_PATH:
            v = self._find_best_font_path_code(0x20, face, primary_space)
            for c in range(0x21, 0x7F):
                if self._find_best_font_path_code(c, face) != v:
                    v = None
                    break
            self._ascii_paths[key] = v
        return v

    cdef object _find_best_font_path(self, str ch, str face, bint primary_space=False):
        """Cascade Search: Finds the best font file that contains the requested glyph."""
        return self._find_best_font_path_code(ord(ch), face, primary_space)

    cdef object _search_fallback_layers(self, int code, str face):
        """Searches through Layer 2 (Standard Fallback) and Layer 3 (International Directory)."""
        cdef object current_f_path = self._get_true_path(self.fallback_name, face)
        if current_f_path and self._has_glyph(current_f_path, code):
            return current_f_path
            
        for f_path in self._intl_font_paths:
            if self._has_glyph(f_path, code):
                return f_path
        
        # Failsafe: Return primary path even if glyph is missing (renders as 'tofu' box)
        return self._get_true_path(self.primary_name, face)

    cdef object _get_font_obj(self, object path_data, int size, str face="", str font_name=""):
        cdef str real_path
        cdef int index = 0
        
        # Extracting paths and indexes from data
        if isinstance(path_data, (list, tuple)):
            real_path = path_data[0]
            index = path_data[1]
        else:
            real_path = path_data

        # Check your cache to avoid reloading existing fonts.
        cdef tuple cache_key = (real_path, index, size, face)
        cdef object _cached_fobj = self._font_objs.c_get(cache_key)
        if _cached_fobj is not None:
            return _cached_fobj

        cdef object f_obj
        cdef bint syn_bold, syn_italic
        cdef tuple syn_flags
        try:
            # No font path at all (e.g. fallback_name that isn't installed):
            # go straight to the system-font fallback below. The module is
            # compiled with nonecheck=False, so real_path.lower() on None
            # was an access violation (hard crash), not a Python exception.
            if real_path is None:
                raise ValueError("no font path")
            # Use pygame.freetype instead of pygame.font
            if real_path.lower().endswith(".ttc"):
                # TTC: use the index if given, default to 0 otherwise
                f_obj = pygame.freetype.Font(real_path, size, font_index=max(0, index))
            else:
                # TTF/OTF: don't pass font_index
                f_obj = pygame.freetype.Font(real_path, size)
                
            # Additional configuration to make the font look better (optional)
            f_obj.antialiased = self._anti_alias
            f_obj.use_bitmap_strikes = True
            #f_obj.origin = True

            # Synthetic Bold/Italic: apply when both primary and fallback
            # have no real font file for this face
            # If font_name is unknown, check both primary and fallback
            if face and self._is_synthetic_needed("", face, path_data):
                syn_flags  = self._get_synthetic_flags(face)
                syn_bold   = <bint>syn_flags[0]
                syn_italic = <bint>syn_flags[1]
                if syn_bold:   f_obj.strong  = True
                if syn_italic: f_obj.oblique = True

            self._font_objs.c_set(cache_key, f_obj)
            return f_obj
            
        except Exception as e:
            pass
            # Fallback to system fonts but still using FreeType
            try:
                # Use FreeType's SysFont to synchronize object types
                f_obj = pygame.freetype.SysFont("arial", size)
                f_obj.antialiased = True
                return f_obj
            except:
                # If even the system doesn't have Arial, use Pygame's default font.
                # Note: pygame.freetype.Font(None) will load the module's default font.
                return pygame.freetype.Font(None, size)

    cdef FontMetricData _get_metrics(self, int size, str face):
        """Compute and cache ascender/height. Returns a struct — not a tuple,
        so the caller (hot path: per character) doesn't need to subscript+unbox."""
        cdef tuple cache_key = (size, face)
        cdef object f_fallback, current_f_path
        cdef double asc, height
        cdef tuple cached
        cdef FontMetricData result
        cdef int b_scale, v_size

        if self._bmp is not None:
            # Bitmap primary font: the line is the bitmap's cell at its
            # scale, with the font's own baseline. Fallback text drawn at
            # render()'s own size (SYNC_FONT_SIZE off) may be taller: then
            # the line grows to fit it.
            if cache_key not in self._std_metrics:
                b_scale = self._bmp.scale_for(size)
                asc = self._bmp.baseline * b_scale
                height = self._bmp.cell_h * b_scale
                if not self._sync_size:
                    v_size = size
                    try:
                        current_f_path = self._get_true_path(self.fallback_name, face)
                        f_fallback = self._get_font_obj(current_f_path, v_size, face)
                        if float(f_fallback.get_sized_ascender()) > asc:
                            asc = float(f_fallback.get_sized_ascender())
                        if float(f_fallback.get_sized_height()) > height:
                            height = float(f_fallback.get_sized_height())
                    except Exception:
                        pass
                self._std_metrics[cache_key] = (asc, height)
            cached = self._std_metrics[cache_key]
            result.asc    = cached[0]
            result.height = cached[1]
            return result

        if cache_key not in self._std_metrics:
            try:
                current_f_path = self._get_true_path(self.fallback_name, face)
                f_fallback = self._get_font_obj(current_f_path, size, face)
                asc = float(f_fallback.get_sized_ascender())
                height = float(f_fallback.get_sized_height())
                self._std_metrics[cache_key] = (asc, height)
            except Exception:
                f_fallback = self._get_font_obj(None, size, face)
                asc = float(f_fallback.get_sized_ascender())
                height = float(f_fallback.get_sized_height())
                self._std_metrics[cache_key] = (asc, height)

        cached = self._std_metrics[cache_key]
        result.asc    = cached[0]
        result.height = cached[1]
        return result

    cdef object _get_hb_font(self, object path_data):
        if isinstance(path_data, (list, tuple)):
            return _pool_hb_font(<str>path_data[0], <int>path_data[1])
        return _pool_hb_font(<str>path_data, 0)

    cdef object _render_emoji_run(self, str text, int size, double f_asc, int final_h, bint apply_italic=False,
                                  bint rtl=False, unsigned int script_tag=0):
        """UNIFIED emoji rendering for the FULL PIPELINE — one single code
        path for every case (single emoji, variation-selector sequences,
        ZWJ ligatures), no more special-casing.

        ALWAYS shapes `text` via HarfBuzz first — the SAME correct
        approach used for regular script text, and the only way to
        reliably resolve ANY ligature-like sequence (not just ZWJ; e.g. a
        base emoji + FE0F variation selector also goes through the font's
        GSUB table). Each shaped glyph is then rendered via COLRv1 ->
        COLRv0 by glyph ID directly (no per-character FT_Get_Char_Index
        guessing), positioned using HarfBuzz's own x_advance/x_offset/
        y_offset — the same positioning primitives the main text pipeline
        already trusts for combining marks and other GPOS-adjusted glyphs.

        SAFETY: if HarfBuzz is unavailable for this font, OR if ANY single
        shaped glyph fails BOTH COLRv1 and COLRv0, the WHOLE run falls
        back to whole-string pygame.font.render() — never a mix of
        rendered and missing/wrong pieces within one shaped sequence."""
        cdef object surf_raw, old_font, final_surf
        cdef int final_w, dy, w, i, baseline_y, top_off
        cdef object hb_font
        cdef bytes shaped
        cdef const int* sh
        cdef double scale, x_adv, x_off, y_off, fcur_x
        cdef bint all_ok
        cdef unsigned int glyph_id
        cdef int left_off
        cdef list glyph_surfs = []
        cdef Py_ssize_t n_glyphs, gi
        cdef object e_key, e_val

        # Stack buffer for glyph geometry (replaces 3 separate Python lists)
        cdef EmojiGlyphPos pos_stack[64]
        cdef EmojiGlyphPos* g_pos = pos_stack
        cdef bint heap_pos = False
        cdef int valid_glyphs = 0

        baseline_y = <int>(f_asc + 0.5)

        # Ensure the emoji FT_Face is loaded (guarded init lives inside
        # _render_colrv1_emoji — a throwaway call on the first char
        # triggers it if this is the very first emoji touched this run).
        self._ensure_emoji_face()

        hb_font = self._get_hb_font(self.emoji_path)
        all_ok = False
        fcur_x = 0.0

        if hb_font is not None:
            scale = size / <double><int>hb_font[1]
            shaped = self._shape_packed(text, <size_t>hb_font[0], self.emoji_path, 0, rtl, script_tag)
            sh = <const int*><const char*>shaped
            n_glyphs = len(shaped) // (4 * <Py_ssize_t>sizeof(int))

            if n_glyphs > 64:
                g_pos = <EmojiGlyphPos*>malloc(n_glyphs * sizeof(EmojiGlyphPos))
                if g_pos == NULL: raise MemoryError()
                heap_pos = True

            all_ok = True
            for gi in range(n_glyphs):
                glyph_id = <unsigned int>sh[4 * gi]
                x_adv = sh[4 * gi + 1] * scale
                x_off = sh[4 * gi + 2] * scale
                y_off = sh[4 * gi + 3] * scale

                # Rendered emoji are cached: COLRv1 gradients are composited
                # per pixel in C, far too slow to redo every frame for
                # dynamic text. Failures are cached too (surf None).
                e_key = (glyph_id, size, apply_italic)
                e_val = self._emoji_cache.c_get(e_key)
                if e_val is None:
                    surf_raw, top_off, left_off = self._render_colrv1_by_id(glyph_id, size, apply_italic)
                    if surf_raw is None:
                        surf_raw, top_off, left_off = self._render_colrv0_by_id(glyph_id, size, apply_italic)
                    if surf_raw is None:
                        surf_raw, top_off, left_off = self._render_cbdt_by_id(glyph_id, size)
                    self._emoji_cache.c_set(e_key, (surf_raw, top_off, left_off))
                else:
                    surf_raw, top_off, left_off = e_val

                if surf_raw is None:
                    # Zero-advance-width glyphs are almost always invisible placeholders
                    if x_adv < 0.5:
                        continue
                    all_ok = False
                    break

                glyph_surfs.append(surf_raw)
                g_pos[valid_glyphs].x = fcur_x + x_off + left_off
                g_pos[valid_glyphs].y = y_off
                g_pos[valid_glyphs].top = top_off
                valid_glyphs += 1
                fcur_x += x_adv

        if all_ok and valid_glyphs > 0:
            final_w = <int>fcur_x
            if final_w <= 0: final_w = 1
            final_surf = pygame.Surface((final_w, final_h), pygame.SRCALPHA)
            for i in range(valid_glyphs):
                surf_raw = glyph_surfs[i]
                # Anchor using the REAL device-pixel top offset (see colrv1_render.h)
                dy = baseline_y - g_pos[i].top \
                     - <int>(size * (EMOJI_OFFSET_Y - _EMOJI_TOP_COMPENSATION)) \
                     - <int>g_pos[i].y
                if dy < 0: dy = 0
                if dy > final_h - 1: dy = final_h - 1
                w = <int>g_pos[i].x
                final_surf.blit(surf_raw, (w, dy))

            if heap_pos: free(g_pos)
            return final_surf, final_w

        if heap_pos: free(g_pos)

        # Fallback: HarfBuzz font unavailable, OR some glyph in the shaped
        # sequence couldn't render via COLRv1/COLRv0 — whole-string
        # pygame.font, the proven-safe path for any remaining case.
        old_font = self._get_old_engine(size)
        try:
            surf_raw = old_font.render(text, self._anti_alias, (255, 255, 255))
        except pygame.error as _pe:
            return pygame.Surface((1, final_h), pygame.SRCALPHA), 1
        final_w = surf_raw.get_width()
        if final_w <= 0: final_w = 1
        final_surf = pygame.Surface((final_w, final_h), pygame.SRCALPHA)
        dy = (baseline_y - surf_raw.get_height() - <int>(size * (EMOJI_OFFSET_Y - _EMOJI_ANCHOR_COMPENSATION))) if SMOOTH_FONT else 0
        if dy < 0: dy = 0
        final_surf.blit(surf_raw, (0, dy))
        return final_surf, final_w

    cdef _GlyphBitmap _rasterize_glyph(self, FT_Face face_obj, unsigned int glyph_id, bint aa,
                                       bint syn_bold, bint syn_italic):
        """Rasterizes one glyph at the face's CURRENT pixel size.

        A failed FT_Load_Glyph now yields an empty bitmap — the error used to
        be ignored, leaving the slot holding the PREVIOUS glyph's bitmap,
        which was then drawn a second time in this glyph's position."""
        cdef int err
        cdef FT_GlyphSlot slot
        cdef int n_bytes
        cdef _GlyphBitmap gb = _GlyphBitmap()
        gb.data = b""
        gb.pixel_mode = 2

        if syn_bold or syn_italic:
            err = FT_Load_Glyph(face_obj, glyph_id, _FT_LOAD_NO_HINTING)
            if err == 0:
                slot = face_obj.glyph
                if syn_bold:   FT_GlyphSlot_Embolden(slot)
                if syn_italic: FT_GlyphSlot_Oblique(slot)
                err = FT_Render_Glyph(slot, 0 if aa else 2)
        else:
            err = FT_Load_Glyph(face_obj, glyph_id, _FT_LOAD_AA if aa else _FT_LOAD_MONO)
        if err != 0:
            return gb  # empty (w == 0)

        slot = face_obj.glyph
        gb.w = slot.bitmap.width
        gb.h = slot.bitmap.rows
        gb.pitch = slot.bitmap.pitch
        gb.left = slot.bitmap_left
        gb.top = slot.bitmap_top
        gb.pixel_mode = slot.bitmap.pixel_mode
        if gb.w > 0 and gb.h > 0 and slot.bitmap.buffer != NULL:
            n_bytes = (gb.pitch if gb.pitch >= 0 else -gb.pitch) * gb.h
            gb.data = (<char*>slot.bitmap.buffer)[:n_bytes]
        else:
            gb.w = 0
        return gb

    cdef bytes _shape_packed(self, str text, size_t hb_font_ptr, str real_path, int index,
                             bint rtl=False, unsigned int script_tag=0, bint tnum=False):
        """HarfBuzz output for `text` as packed int32 quads
        [glyph_id, x_advance, x_offset, y_offset] (font units), cached.
        Direction and script come from the BiDi / script itemizer
        (cp_itemize) instead of being guessed; for a right-to-left run
        HarfBuzz returns the glyphs already in visual (left-to-right) order
        and mirrors brackets. tnum (a [tnum] / tnum tag): OpenType 'tnum' on,
        then every digit 0-9 is set in one equal-width cell (_tnum_cell),
        centred — equal widths even when the font has no tabular digits or
        kerns digit pairs."""
        global _hb_shape_buf
        cdef tuple key = (text, real_path, index, rtl, script_tag, tnum)
        cdef hb_feature_t feat
        cdef int cell = 0, extra
        cdef unsigned int cl
        cdef object packed = self._shape_cache.c_get(key)
        cdef Py_ssize_t n_chars = len(text), i
        cdef unsigned int n = 0
        cdef unsigned int* codes
        cdef int* tmp
        cdef Py_UCS4 ch
        cdef hb_glyph_info_t* infos
        cdef hb_glyph_position_t* positions
        if packed is not None:
            return <bytes>packed

        if tnum:
            cell = _tnum_cell(hb_font_ptr, real_path, index)   # (uses the buffer: before shaping)
        if _hb_shape_buf == NULL:
            _hb_shape_buf = hb_buffer_create()
        codes = <unsigned int*>malloc((n_chars + 1) * sizeof(unsigned int))
        if codes == NULL:
            raise MemoryError()
        i = 0
        for ch in text:
            codes[i] = ch
            i += 1
        hb_buffer_clear_contents(_hb_shape_buf)
        hb_buffer_add_utf32(_hb_shape_buf, codes, <int>n_chars, 0, <int>n_chars)
        free(codes)
        hb_buffer_set_direction(_hb_shape_buf, HB_DIRECTION_RTL if rtl else HB_DIRECTION_LTR)
        if script_tag:
            hb_buffer_set_script(_hb_shape_buf, hb_script_from_iso15924_tag(script_tag))
        hb_buffer_guess_segment_properties(_hb_shape_buf)   # fills in the language (and script if unknown)
        if tnum:
            feat.tag = 0x746E756D          # 'tnum'
            feat.value = 1
            feat.start = 0                 # whole buffer
            feat.end = <unsigned int>-1
            hb_shape(<hb_font_t*>hb_font_ptr, _hb_shape_buf, &feat, 1)
        else:
            hb_shape(<hb_font_t*>hb_font_ptr, _hb_shape_buf, NULL, 0)
        infos = hb_buffer_get_glyph_infos(_hb_shape_buf, &n)
        positions = hb_buffer_get_glyph_positions(_hb_shape_buf, NULL)

        tmp = <int*>malloc((n * 4 + 1) * sizeof(int))
        if tmp == NULL:
            raise MemoryError()
        for i in range(n):
            tmp[4 * i]     = <int>infos[i].codepoint
            tmp[4 * i + 1] = positions[i].x_advance
            tmp[4 * i + 2] = positions[i].x_offset
            tmp[4 * i + 3] = positions[i].y_offset
            if cell > 0:
                cl = infos[i].cluster
                if cl < <unsigned int>n_chars and 0x30 <= <Py_UCS4>text[cl] <= 0x39:
                    extra = cell - positions[i].x_advance
                    tmp[4 * i + 1] = cell
                    tmp[4 * i + 2] = positions[i].x_offset + extra // 2
        packed = (<char*>tmp)[:n * 4 * sizeof(int)]
        free(tmp)
        self._shape_cache.c_set(key, packed)
        return packed

    cdef _RunLayout _get_layout(self, str text, int size, object font_path, str face, int aa_toggle,
                                bint rtl=False, unsigned int script_tag=0):
        """_layout_run through self._layout_cache."""
        cdef object path_key = (<str>font_path[0], <int>font_path[1]) if isinstance(font_path, (list, tuple)) else font_path
        if self._bmp is not None and self._sync_size and not self._is_bmp_path(font_path):
            # SYNC_FONT_SIZE: fallback / emoji text as tall as the bitmap line.
            size = self._bmp.cell_h * self._bmp.scale_for(size)
        cdef tuple key = (text, path_key, size, face, aa_toggle, rtl, script_tag)
        cdef object lay = self._layout_cache.c_get(key)
        if lay is None:
            lay = self._layout_run(text, size, font_path, face, aa_toggle, rtl, script_tag)
            # Glyph runs only: emoji-run surfaces bake in EMOJI_OFFSET_Y /
            # SMOOTH_FONT, which may change at runtime (their glyphs are
            # already cached in _emoji_cache anyway).
            if (<_RunLayout>lay).surf is None:
                self._layout_cache.c_set(key, lay)
        return <_RunLayout>lay

    cdef _RunLayout _layout_run(self, str text, int size, object font_path, str face, int aa_toggle=0,
                                bint rtl=False, unsigned int script_tag=0):
        """Phase 1 of drawing a run: shape it, fetch every glyph bitmap from
        the cache (rasterizing only the ones never seen), and compute the
        glyph positions + the run's ink/logical widths — WITHOUT creating a
        Surface. Phase 2 (_draw_layout) writes the glyphs straight into
        whatever destination Surface the caller provides, so a multi-run line
        is drawn into ONE surface instead of one surface per run that then
        had to be alpha-blitted together (a 400x49 SRCALPHA->SRCALPHA blit
        alone costs ~100us — more than drawing the glyphs themselves).

        Emoji runs and failure cases carry a ready-made Surface in lay.surf
        instead of glyphs.
        """
        cdef _RunLayout lay = _RunLayout()
        cdef object hb_font
        cdef FT_Face face_obj
        cdef double f_asc, f_h, scale, cur_x, min_x, max_x, glyph_x, glyph_right, logical_x1, logical_x2, base_x
        cdef unsigned int glyph_id
        cdef int w_bmp, left
        cdef double x_adv, x_off, y_off
        cdef str real_path
        cdef FontMetricData metrics
        cdef GlyphMeta* g_meta
        cdef Py_ssize_t n_glyphs, gi
        cdef int index = 0, space_w = 0
        cdef double total_adv = 0.0

        cdef _LRUCache bcache = self._glyph_cache
        cdef _GlyphBitmap entry
        cdef object cached_entry
        cdef int mode_key
        cdef long long key_base
        cdef bint size_ready = False
        cdef bytes shaped
        cdef const int* sh

        metrics = self._get_metrics(size, face)
        f_asc = metrics.asc
        f_h   = metrics.height
        lay.baseline_y = <int>(f_asc + 0.5)
        lay.final_h = <int>(f_h * 1.5)
        lay.size = size
        lay.ink_top = 0
        lay.ink_bot = <int>(f_h + 0.5)
        cdef int g_top, ink_t = 1 << 30, ink_b = -(1 << 30)

        if self._bmp is not None and self._is_bmp_path(font_path):
            return self._layout_bitmap(lay, text, size, rtl)

        # Synthetic bold/italic detection moved HERE, before the emoji
        # early-return below — previously this only ran further down,
        # which meant emoji text inside an inline <italic={...}> tag
        # silently never received the flag at all (the emoji path
        # returned before ever reaching that code). See colrv0_render.c's
        # apply_italic parameter for where this actually takes effect —
        # CBDT/COLRv1 emoji still ignore it (CBDT can't, by nature of
        # being a pre-rasterized bitmap; COLRv1 support is a separate,
        # not-yet-done follow-up).
        cdef bint _syn_bold = False, _syn_italic = False
        cdef tuple _syn_flags
        if face and self._is_synthetic_needed("", face, font_path):
            _syn_flags = self._get_synthetic_flags(face)
            _syn_bold   = <bint>_syn_flags[0]
            _syn_italic = <bint>_syn_flags[1]

        if isinstance(font_path, (list, tuple)) and font_path[0] == self.emoji_path or font_path == self.emoji_path:
            lay.surf, lay.logic_w = self._render_emoji_run(text, size, f_asc, lay.final_h, _syn_italic,
                                                           rtl, script_tag)
            lay.ink_w = lay.surf.get_width()
            return lay

        if isinstance(font_path, (list, tuple)):
            real_path = font_path[0]
            index = font_path[1]
            if index < 0: index = 0
        else:
            real_path = font_path

        hb_font = self._get_hb_font(font_path)
        face_obj = self._get_shared_ft_face(real_path, index) if hb_font is not None else NULL
        if face_obj == NULL:
            lay.surf = pygame.Surface((1, lay.final_h), pygame.SRCALPHA)
            lay.ink_w = lay.logic_w = 1
            return lay

        scale = size / <double><int>hb_font[1]
        shaped = self._shape_packed(text, <size_t>hb_font[0], real_path, index, rtl, script_tag,
                                    (aa_toggle & CP_STYLE_TNUM) != 0)
        sh = <const int*><const char*>shaped
        n_glyphs = len(shaped) // (4 * <Py_ssize_t>sizeof(int))

        g_meta = <GlyphMeta*>malloc((n_glyphs if n_glyphs > 0 else 1) * sizeof(GlyphMeta))
        if g_meta == NULL: raise MemoryError()
        lay.g_meta = g_meta   # owned (freed) by the layout from here on
        lay.n = n_glyphs

        # aa_toggle holds a tag's CP_STYLE_* flags.
        cdef bint _aa = (not self._anti_alias) if (aa_toggle & CP_STYLE_AA) else self._anti_alias
        mode_key = (1 if _aa else 0) | (2 if _syn_bold else 0) | (4 if _syn_italic else 0)
        # Glyph-cache key packed into ONE int: face | size | mode | glyph id
        # (glyph ids are 16-bit in OpenType) — no 4-tuple built per glyph.
        key_base = (((_face_id(<size_t>face_obj) << 20) | (size & 0xFFFFF)) << 3 | mode_key) << 16

        cur_x = 0.0
        min_x = 999999.0
        max_x = -999999.0

        for gi in range(n_glyphs):
            glyph_id = <unsigned int>sh[4 * gi] & 0xFFFF
            x_adv = sh[4 * gi + 1] * scale
            x_off = sh[4 * gi + 2] * scale
            y_off = sh[4 * gi + 3] * scale
            total_adv += x_adv
            base_x = cur_x
            cur_x += x_adv

            cached_entry = bcache.c_get(key_base | glyph_id)
            if cached_entry is None:
                # Set the size lazily: FT_Set_Pixel_Sizes re-runs the
                # font's hinting setup, wasted work when every glyph hits.
                if not size_ready:
                    FT_Set_Pixel_Sizes(face_obj, 0, size)
                    size_ready = True
                entry = self._rasterize_glyph(face_obj, glyph_id, _aa, _syn_bold, _syn_italic)
                bcache.c_set(key_base | glyph_id, entry)
            else:
                entry = <_GlyphBitmap>cached_entry

            w_bmp = entry.w
            left  = entry.left

            glyph_x = base_x + x_off + left
            glyph_right = glyph_x + w_bmp

            if glyph_x < min_x: min_x = glyph_x
            if glyph_right > max_x: max_x = glyph_right

            logical_x1 = base_x + x_off
            logical_x2 = logical_x1 + x_adv

            if logical_x1 < min_x: min_x = logical_x1
            if logical_x1 > max_x: max_x = logical_x1
            if logical_x2 < min_x: min_x = logical_x2
            if logical_x2 > max_x: max_x = logical_x2

            g_meta[gi].w_bmp = w_bmp
            g_meta[gi].h_bmp = entry.h
            g_meta[gi].pitch = entry.pitch
            g_meta[gi].left  = left
            g_meta[gi].top   = entry.top
            g_meta[gi].x     = base_x + x_off
            g_meta[gi].y_off = y_off
            g_meta[gi].pixel_mode = entry.pixel_mode
            if w_bmp > 0 and entry.h > 0:
                # Same row rounding as _draw_layout's oy.
                g_top = <int>floor(lay.baseline_y - entry.top - y_off + 0.5)
                if g_top < ink_t: ink_t = g_top
                if g_top + entry.h > ink_b: ink_b = g_top + entry.h
            if w_bmp > 0:
                # The layout holds the bitmap bytes alive while g_meta[].buf
                # points into them, even if the LRU evicts the entry meanwhile.
                lay.keep_alive.append(entry.data)
                g_meta[gi].buf = <const unsigned char*><char*>entry.data
            else:
                g_meta[gi].buf = NULL

        if min_x > max_x:
            space_w = max(1, <int>(total_adv + 0.5))
            lay.n = 0
            lay.ink_w = lay.logic_w = space_w
            return lay

        if ink_t < ink_b:
            lay.ink_top = ink_t
            lay.ink_bot = ink_b
            lay.has_ink = True
        lay.start_x = -min_x if min_x < 0 else 0.0
        lay.logic_w = <int>(total_adv + 0.5)
        lay.ink_w = max(1, <int>(max_x + lay.start_x + 1.0))
        if lay.logic_w > lay.ink_w:
            lay.ink_w = lay.logic_w
        return lay

    cdef _RunLayout _layout_bitmap(self, _RunLayout lay, str text, int size, bint rtl):
        """_layout_run for the .dfbmp primary font: no shaping, each
        character's cell placed at scale s (every bit an s x s block of full
        coverage), the pen moved one cell plus the gap ((cell_w + gap) * s)
        per character — no gap after the last one. lay already carries the
        line metrics (baseline, height) for this size."""
        cdef _BitmapFont bf = self._bmp
        cdef int s = bf.scale_for(size)
        cdef Py_ssize_t n = len(text), i, k = 0
        cdef GlyphMeta* g_meta
        cdef object idx_obj
        cdef int idx, pen = 0, g_top
        cdef int w = bf.cell_w * s, h = bf.cell_h * s, top = bf.baseline * s, gap = bf.gap * s
        cdef bytes data

        g_meta = <GlyphMeta*>malloc((n if n > 0 else 1) * sizeof(GlyphMeta))
        if g_meta == NULL:
            raise MemoryError()
        lay.g_meta = g_meta
        for i in range(n):
            idx_obj = bf.index.get(<int>text[n - 1 - i if rtl else i])
            if idx_obj is None:
                continue   # e.g. a BiDi control riding along: nothing to draw
            idx = <int>idx_obj
            data = bf.glyph(idx, s)
            lay.keep_alive.append(data)
            g_meta[k].w_bmp = w
            g_meta[k].h_bmp = h
            g_meta[k].pitch = w
            g_meta[k].left = 0
            g_meta[k].top = top        # cell top = baseline - baseline rows
            g_meta[k].x = pen
            g_meta[k].y_off = 0
            g_meta[k].pixel_mode = 2   # 8-bit coverage
            g_meta[k].buf = <const unsigned char*><char*>data
            k += 1
            pen += w + gap
        lay.n = k
        lay.start_x = 0.0
        # logic_w keeps the gap after the last cell (the next run starts
        # there); the surface itself ends at the last cell.
        lay.logic_w = pen if pen > 0 else 1
        lay.ink_w = pen - gap if k > 0 else lay.logic_w
        if k > 0:
            g_top = lay.baseline_y - top
            lay.ink_top = g_top
            lay.ink_bot = g_top + h
            lay.has_ink = True
        return lay

    cdef void _draw_layout(self, _RunLayout lay, object color, unsigned int[:, :] px_view, int dst_w, int dst_h,
                           int dst_x, int dst_y, object shifts, int grad_x0, int grad_w, int grad_y0, int grad_h,
                           int grad_em_size):
        """Phase 2: writes a layout's glyphs into px_view with the run's
        origin at (dst_x, dst_y), clipped to the run's own box and to the
        destination. dst_y > 0 shifts a run down so runs of different sizes
        (inline size tags) share one baseline. grad_em_size: the font size
        gradient.em() lengths refer to. Uses the surface's REAL channel layout (shifts) instead
        of assuming ARGB (a<<24) — correct on any SDL pixel format.

        color: (R, G, B) tuple, or a Gradient spanning the destination box
        (0, grad_y0, grad_w, grad_h): the full line width and the line's
        actual ink height, so one smooth sweep crosses every run and a
        vertical gradient really goes from the first color to the last on
        the letters themselves."""
        cdef unsigned int mapped_colors[256]
        cdef const unsigned int* glut
        cdef unsigned int a_shift, s_r, s_g, s_b, base_rgb, cur
        cdef int a, gi, bmp_x, bmp_y, alpha_val, py
        cdef int w_bmp, h_bmp, pitch, abs_pitch
        cdef int ox, oy, x0, x1, y0, y1, clip_w, clip_h, clip_top
        cdef const unsigned char* bmp_ptr
        cdef const unsigned char* row_ptr
        cdef GlyphMeta* g_meta = lay.g_meta
        cdef Gradient grad
        cdef bint use_grad = isinstance(color, Gradient)
        cdef long long gax = 0, gay = 0, gc = 0, grow, gidx
        cdef bint grad_wrap = False
        cdef double grad_period

        if lay.n == 0:
            return
        a_shift = <unsigned int>shifts[3]
        s_r = <unsigned int>shifts[0]
        s_g = <unsigned int>shifts[1]
        s_b = <unsigned int>shifts[2]
        if use_grad:
            grad = <Gradient>color
            glut = grad.packed_for(<tuple>shifts)
            grad_period = grad.period_px(grad_em_size)
            grad_wrap = grad_period > 0
            grad_setup(grad.angle, grad_x0, grad_y0, grad_w, grad_h, grad_period, &gax, &gay, &gc)
        else:
            base_rgb = ((<unsigned int><int>color[0] << s_r) |
                        (<unsigned int><int>color[1] << s_g) |
                        (<unsigned int><int>color[2] << s_b))
            for a in range(256):
                mapped_colors[a] = (<unsigned int>a << a_shift) | base_rgb

        # Same clip a per-run surface (ink_w x final_h) blitted at dst_x had,
        # widened vertically to the run's ink: marks reaching above the ascent
        # or below final_h are drawn (the callers make the surface fit them).
        clip_w = dst_x + lay.ink_w
        if clip_w > dst_w: clip_w = dst_w
        clip_top = dst_y + (lay.ink_top if lay.ink_top < 0 else 0)
        clip_h = dst_y + (lay.ink_bot if lay.ink_bot > lay.final_h else lay.final_h)
        if clip_h > dst_h: clip_h = dst_h

        for gi in range(lay.n):
            w_bmp = g_meta[gi].w_bmp
            if w_bmp <= 0: continue
            if g_meta[gi].pixel_mode != 1 and g_meta[gi].pixel_mode != 2:
                continue  # not MONO/GRAY (e.g. GRAY2/GRAY4) — can't decode, skip

            h_bmp = g_meta[gi].h_bmp
            pitch = g_meta[gi].pitch
            abs_pitch = pitch if pitch > 0 else -pitch
            bmp_ptr = g_meta[gi].buf

            # Integer pixel origin + clip rectangle computed ONCE per
            # glyph: the inner loops below carry no bounds checks and no
            # float->int conversions.
            ox = dst_x + <int>floor(g_meta[gi].x + g_meta[gi].left + lay.start_x + 0.5)
            oy = dst_y + <int>floor(lay.baseline_y - g_meta[gi].top - g_meta[gi].y_off + 0.5)
            x0 = dst_x - ox if ox < dst_x else 0
            if ox + x0 < 0: x0 = -ox
            y0 = clip_top - oy if oy < clip_top else 0
            if oy + y0 < 0: y0 = -oy
            x1 = w_bmp if ox + w_bmp <= clip_w else clip_w - ox
            y1 = h_bmp if oy + h_bmp <= clip_h else clip_h - oy
            if x0 >= x1 or y0 >= y1: continue

            # Dispatch on the ACTUAL bitmap format FreeType returned for
            # THIS glyph (pixel_mode), not on the requested AA mode:
            # FreeType silently prefers an embedded MONO bitmap strike over
            # an anti-aliased render whenever the font has a strike matching
            # the requested pixel size (seen with JF.ttf's 14px strike).
            #
            # Overlapping glyphs (combining marks, tight kerning, italic
            # overhang) keep the STRONGER coverage — plain overwrite let a
            # later glyph's faint anti-aliased edge punch a lighter notch
            # into an already-solid neighbouring stroke.
            if use_grad:
                # Same loops, color looked up per pixel from the gradient
                # table: index = (x*ax + y*ay + c) >> 16, clamped (glyph ink
                # outside the line band, e.g. deep descenders).
                for bmp_y in range(y0, y1):
                    row_ptr = bmp_ptr + (bmp_y * pitch if pitch > 0 else (h_bmp - 1 - bmp_y) * abs_pitch)
                    py = oy + bmp_y
                    grow = py * gay + gc
                    for bmp_x in range(x0, x1):
                        if g_meta[gi].pixel_mode == 1:
                            alpha_val = 255 if (row_ptr[bmp_x >> 3] >> (7 - (bmp_x & 7))) & 1 else 0
                        else:
                            alpha_val = row_ptr[bmp_x]
                        if alpha_val == 0: continue
                        cur = px_view[ox + bmp_x, py]
                        if <unsigned int>alpha_val > ((cur >> a_shift) & 0xFF):
                            gidx = ((ox + bmp_x) * gax + grow) >> 16
                            if grad_wrap:
                                gidx = gidx & (GRAD_LUT_SIZE - 1)   # px/em layer: repeat
                            elif gidx < 0: gidx = 0
                            elif gidx > GRAD_LUT_SIZE - 1: gidx = GRAD_LUT_SIZE - 1
                            px_view[ox + bmp_x, py] = (<unsigned int>alpha_val << a_shift) | glut[gidx]
            elif g_meta[gi].pixel_mode == 1:  # FT_PIXEL_MODE_MONO — 1 bit/pixel, packed 8 per byte
                for bmp_y in range(y0, y1):
                    row_ptr = bmp_ptr + (bmp_y * pitch if pitch > 0 else (h_bmp - 1 - bmp_y) * abs_pitch)
                    for bmp_x in range(x0, x1):
                        if (row_ptr[bmp_x >> 3] >> (7 - (bmp_x & 7))) & 1:
                            px_view[ox + bmp_x, oy + bmp_y] = mapped_colors[255]
            else:  # FT_PIXEL_MODE_GRAY (2) — 1 byte/pixel, already an alpha coverage value
                for bmp_y in range(y0, y1):
                    row_ptr = bmp_ptr + (bmp_y * pitch if pitch > 0 else (h_bmp - 1 - bmp_y) * abs_pitch)
                    for bmp_x in range(x0, x1):
                        alpha_val = row_ptr[bmp_x]
                        if alpha_val == 0: continue
                        cur = px_view[ox + bmp_x, oy + bmp_y]
                        if <unsigned int>alpha_val > ((cur >> a_shift) & 0xFF):
                            px_view[ox + bmp_x, oy + bmp_y] = mapped_colors[alpha_val]

    cdef object _layout_to_surface(self, _RunLayout lay, object color):
        """A single run as its own Surface (ink_w x final_h). Glyphs that
        reach above the font's ascent or below the surface (a fallback
        font's stacked marks next to a tight .dfbmp line) make it taller
        instead of being cut off."""
        cdef object surf, px_array
        cdef unsigned int[:, :] px_view
        cdef int top = 0, h = lay.final_h
        if lay.surf is not None:
            # The layout (and its surface) is cached and reused: hand out a
            # copy so the caller can't alter what later renders draw.
            return lay.surf.copy()
        if lay.has_ink:
            if lay.ink_top < 0: top = -lay.ink_top
            if lay.ink_bot > h: h = lay.ink_bot
        h += top
        surf = pygame.Surface((lay.ink_w, h), pygame.SRCALPHA)
        if lay.n > 0:
            px_array = pygame.PixelArray(surf)
            px_view = px_array
            self._draw_layout(lay, color, px_view, lay.ink_w, h, 0, top, surf.get_shifts(),
                              0, lay.ink_w, lay.ink_top + top, lay.ink_bot - lay.ink_top, lay.size)
            px_view = None
            px_array.close()
        return surf

    cdef object _render_shaped_run(self, str text, int size, object color, object font_path, str face, int aa_toggle=0,
                                   bint rtl=False, unsigned int script_tag=0):
        """Renders one run to its own Surface: returns (surface, logical width).
        - Glyph bitmaps come from self._glyph_cache, so re-rendering text — dynamic
          text every frame in particular — skips FreeType's hinting + rasterizing.
        - Shaping results come from self._shape_cache.
        - Shares Master FT_Face instances across all sizes (FT_Set_Pixel_Sizes) to eliminate disk I/O spikes.
        """
        cdef _RunLayout lay = self._get_layout(text, size, font_path, face, aa_toggle, rtl, script_tag)
        return self._layout_to_surface(lay, color), lay.logic_w


    cdef object _compose_lines(self, list runs, int size, FontMetricData std_m):
        """Multi-line text: runs from _parse_render_accumulate with a None
        between lines. Every line is laid out like a single-line render()
        (shared baseline for inline sizes) and all of them are drawn into
        ONE surface, left-aligned, one line height (the font's) apart — so a
        render() gradient sweeps once across the whole block and a color tag
        spanning several lines gets a single gradient box."""
        cdef int std_h = <int>std_m.height
        cdef int fixed_h = <int>(std_h * 1.5)          # a single line's surface height
        cdef int main_base = <int>(std_m.asc + 0.5)
        cdef list lays = [], colors = [], seqs = [], xs = [], ys = []
        cdef list line
        cdef object run, seq, box
        cdef _RunLayout lay
        cdef int line_y = 0, block_w = 1, block_h = 0, cur_x, line_w, line_base, line_h, dy
        cdef int k, n_line, x, y, surf_h, ink_t, ink_b, push
        cdef Py_ssize_t idx = 0, n_runs = len(runs)
        cdef int ink_top = 1 << 30, ink_bot = -(1 << 30)
        cdef dict tag_box = {}
        cdef object final_surf, px_array, shifts
        cdef unsigned int[:, :] px_view

        while True:
            # ---- one line's layouts ----
            line = []
            while idx < n_runs and runs[idx] is not None:
                run = runs[idx]
                idx += 1
                if run[0]:
                    lay = self._get_layout(run[0], run[6] if run[6] > 0 else size, run[1], run[4],
                                           run[5], run[8], run[9])
                    line.append((lay, run[2], run[7]))

            # ---- shared baseline (as render() does for one line) ----
            n_line = len(line)
            line_base = main_base
            for k in range(n_line):
                lay = <_RunLayout>line[k][0]
                if lay.size != size and lay.baseline_y > line_base:
                    line_base = lay.baseline_y
            line_h = fixed_h + (line_base - main_base)
            # Glyphs reaching above this line or below it (a fallback font's
            # stacked marks next to a tight .dfbmp line) push the line down /
            # make it taller, as in a single-line render().
            ink_t = 1 << 30
            ink_b = -(1 << 30)
            for k in range(n_line):
                lay = <_RunLayout>line[k][0]
                dy = line_base - (lay.baseline_y if lay.size != size else main_base)
                if lay.surf is None and lay.has_ink:
                    if lay.ink_top + dy < ink_t: ink_t = lay.ink_top + dy
                    if lay.ink_bot + dy > ink_b: ink_b = lay.ink_bot + dy
            push = -ink_t if ink_t < 0 else 0
            line_h += push
            if ink_b + push > line_h:
                line_h = ink_b + push
            cur_x = 0
            for k in range(n_line):
                lay = <_RunLayout>line[k][0]
                dy = line_base - (lay.baseline_y if lay.size != size else main_base) + push
                if lay.size != size and dy + lay.final_h > line_h:
                    line_h = dy + lay.final_h
                lays.append(lay)
                colors.append(line[k][1])
                seqs.append(line[k][2])
                xs.append(cur_x)
                ys.append(line_y + dy)
                cur_x += lay.logic_w
            if n_line:
                lay = <_RunLayout>line[n_line - 1][0]
                line_w = cur_x - lay.logic_w + lay.ink_w   # last run keeps its full ink
                if line_w > block_w: block_w = line_w
            block_h = line_y + line_h
            # Next line one font line height further down (the 1.5x padding
            # is kept only below the last line).
            line_y += line_h - (fixed_h - std_h)

            if idx >= n_runs:
                break
            idx += 1   # the None between two lines

        surf_h = block_h if block_h > 0 else 1
        final_surf = pygame.Surface((block_w, surf_h), pygame.SRCALPHA)
        n_line = len(lays)
        if n_line == 0:
            return final_surf

        # Ink extent of the whole block (gradient span) and per-tag boxes.
        for k in range(n_line):
            lay = <_RunLayout>lays[k]
            x = <int>xs[k]
            y = <int>ys[k]
            if lay.surf is None and lay.has_ink:
                if lay.ink_top + y < ink_top: ink_top = lay.ink_top + y
                if lay.ink_bot + y > ink_bot: ink_bot = lay.ink_bot + y
            seq = seqs[k]
            if seq:
                box = tag_box.get(seq)
                if box is None:
                    box = [x, x + lay.ink_w, 1 << 30, -(1 << 30)]
                    tag_box[seq] = box
                if x < box[0]: box[0] = x
                if x + lay.ink_w > box[1]: box[1] = x + lay.ink_w
                if lay.has_ink:
                    if lay.ink_top + y < box[2]: box[2] = lay.ink_top + y
                    if lay.ink_bot + y > box[3]: box[3] = lay.ink_bot + y
        if ink_top >= ink_bot:
            ink_top = 0
            ink_bot = std_h
        for box in tag_box.values():
            if box[2] >= box[3]:
                box[2] = ink_top
                box[3] = ink_bot

        shifts = final_surf.get_shifts()
        px_array = pygame.PixelArray(final_surf)
        px_view = px_array
        for k in range(n_line):
            lay = <_RunLayout>lays[k]
            if lay.surf is None and lay.has_ink:
                seq = seqs[k]
                if seq:
                    box = tag_box[seq]
                    self._draw_layout(lay, colors[k], px_view, block_w, surf_h,
                                      <int>xs[k], <int>ys[k], shifts,
                                      box[0], box[1] - box[0], box[2], box[3] - box[2], size)
                else:
                    self._draw_layout(lay, colors[k], px_view, block_w, surf_h,
                                      <int>xs[k], <int>ys[k], shifts,
                                      0, block_w, ink_top, ink_bot - ink_top, size)
        px_view = None
        px_array.close()

        # Pre-rendered runs (emoji) are real surfaces — blit those.
        for k in range(n_line):
            lay = <_RunLayout>lays[k]
            if lay.surf is not None:
                final_surf.blit(lay.surf, (<int>xs[k], <int>ys[k]))
        return final_surf

    cdef list _parse_render_accumulate(self, str text, object color, str face, object current_p_path, object current_f_path,
                                       bint primary_space=False, int base_dir=CP_DIR_AUTO):
        """Text -> runs to shape, in VISUAL (left-to-right) order.
        1. c_parser.c's cp_parse_text: rich-text tags -> clean text + style runs;
        2. cp_itemize: Unicode BiDi (UAX #9) and script runs (UAX #24) through
           SheenBidi -> items with one style, one direction and one script,
           reordered for display;
        3. here: each item split further where the font changes (fallback
           fonts / emoji), those pieces reversed inside right-to-left items.
        Text with line breaks ("\n", each one a BiDi paragraph end): the
        "\n" characters are dropped and a None goes between the runs of
        consecutive lines — one None per line break, so N breaks give
        N + 1 lines (empty ones included)."""
        cdef int n = <int>len(text)
        if n == 0: return []

        cdef unsigned int stack_in[512]
        cdef unsigned int stack_clean[512]
        cdef CP_Run stack_runs[128]
        cdef CP_PaletteEntry palette_table[256]
        memset(palette_table, 0, sizeof(palette_table))

        # Synchronize RICH PALETTE dynamic from Python into a C lookup table
        cdef object p_key, p_val
        cdef int p_code
        for p_key, p_val in RICH_PALETTE.items():
            if isinstance(p_key, str) and len(p_key) == 1:
                p_code = ord(p_key)
                if 0 <= p_code < 256:
                    palette_table[p_code].r = <unsigned char>p_val[0]
                    palette_table[p_code].g = <unsigned char>p_val[1]
                    palette_table[p_code].b = <unsigned char>p_val[2]
                    palette_table[p_code].is_set = 1

        cdef unsigned int* in_codes = stack_in
        cdef unsigned int* clean_codes = stack_clean
        cdef CP_Run* runs_buf = stack_runs
        cdef bint heap_in = False, heap_clean = False, heap_runs = False

        if n > 512:
            in_codes = <unsigned int*>malloc(n * sizeof(unsigned int))
            clean_codes = <unsigned int*>malloc(n * sizeof(unsigned int))
            heap_in = True
            heap_clean = True

        # Every run holds at least one visible char, so n runs is the true
        # worst case. The old n//2+8 bound (min 128) was too small for text
        # that switches script/color often (e.g. "a b c d ...", or tags every
        # word) and cp_parse_text silently DROPPED the overflowing runs'
        # text from the output.
        cdef int max_runs = 128
        cdef int calc_runs = n + 8
        if calc_runs > max_runs:
            max_runs = calc_runs
            runs_buf = <CP_Run*>malloc(max_runs * sizeof(CP_Run))
            heap_runs = True

        cdef int idx
        for idx in range(n):
            in_codes[idx] = <unsigned int>ord(text[idx])

        cdef CP_Color def_col
        # A Gradient replaces the default color: the parser gets a
        # placeholder and flags which runs use it (color_is_default).
        cdef bint is_grad = isinstance(color, Gradient)
        cdef tuple base_col = (255, 255, 255) if is_grad else <tuple>color
        def_col.r = <unsigned char><int>base_col[0]
        def_col.g = <unsigned char><int>base_col[1]
        def_col.b = <unsigned char><int>base_col[2]

        cdef bytes face_bytes = face.encode('utf-8')
        cdef const char* face_cstr = face_bytes
        cdef int clean_len = 0

        cdef int num_runs = cp_parse_text(
            in_codes, n, def_col, face_cstr, palette_table,
            clean_codes, &clean_len, runs_buf, max_runs
        )

        # BiDi + script itemization, visual order. Items <= clean chars.
        cdef CP_Run stack_items[128]
        cdef CP_Run* items = stack_items
        cdef bint heap_items = False
        cdef int max_items = clean_len + 8
        if max_items > 128:
            items = <CP_Run*>malloc(max_items * sizeof(CP_Run))
            if items == NULL:
                raise MemoryError()
            heap_items = True
        cdef int num_items = cp_itemize(clean_codes, clean_len, runs_buf, num_runs,
                                        base_dir, items, max_items if max_items > 128 else 128)
        if num_items < 0:
            if heap_items: free(items)
            raise MemoryError()

        cdef list result_runs = []
        cdef int ri, run_start, run_len, ki, sub_start, sub_len
        cdef str r_face_str, run_text
        cdef object r_color_tup
        cdef object cur_font_path, last_font_path
        cdef int aa_toggle_flag
        cdef int s_group, r_size, r_tag_seq
        cdef bint r_tag_grad, r_rtl
        cdef unsigned int cp, r_script
        cdef list item_runs
        # Clean-text positions of the line breaks. A paragraph's items are
        # contiguous in cp_itemize's output and paragraphs come in order,
        # so an item past the current break starts the next line.
        cdef list nl_pos = None
        cdef int cur_line = 0
        if '\n' in text:
            nl_pos = []
            for ki in range(clean_len):
                if clean_codes[ki] == 10:
                    nl_pos.append(ki)

        try:
            for ri in range(num_items):
                run_start = items[ri].start
                run_len = items[ri].length
                if run_len <= 0: continue
                if nl_pos is not None:
                    while cur_line < len(nl_pos) and run_start > <int>nl_pos[cur_line]:
                        result_runs.append(None)
                        cur_line += 1
                r_rtl = (items[ri].level & 1) != 0
                r_script = items[ri].script_tag
                item_runs = []

                r_tag_grad = False
                if items[ri].grad_id > 0:
                    # <color({gradient_var})=...> tag; a handle whose gradient
                    # is gone falls back to the render() color.
                    r_color_tup = _resolve_gradient(items[ri].grad_id, color)
                    r_tag_grad = isinstance(r_color_tup, Gradient)
                elif is_grad and items[ri].color_is_default:
                    r_color_tup = color
                else:
                    r_color_tup = (items[ri].color.r, items[ri].color.g, items[ri].color.b)
                r_face_str = items[ri].face.decode('utf-8', 'replace')
                if not r_face_str: r_face_str = face

                s_group = items[ri].script_group
                aa_toggle_flag = items[ri].aa_toggle   # CP_STYLE_* flags
                r_size = items[ri].size    # inline size tag, 0 = render()'s size
                r_tag_seq = items[ri].tag_seq if r_tag_grad else 0

                # Split by fallback font if CJK characters or Emojis requiring a font change are present within the same run.
                # Uses PyUnicode_FromKindAndData C-API to instantiate Python string in 1 single C call.
                last_font_path = None
                sub_start = run_start
                sub_len = 0

                for ki in range(run_len):
                    cp = clean_codes[run_start + ki]
                    if cp == 10:
                        # Line break: ends the current piece, drawn as nothing.
                        if sub_len > 0:
                            run_text = PyUnicode_FromKindAndData(PyUnicode_4BYTE_KIND, &clean_codes[sub_start], sub_len)
                            item_runs.append((run_text, last_font_path, r_color_tup, s_group, r_face_str, aa_toggle_flag, r_size, r_tag_seq, r_rtl, r_script))
                        sub_start = run_start + ki + 1
                        sub_len = 0
                        last_font_path = None
                        continue
                    if last_font_path is not None and (0x200E <= cp <= 0x200F or 0x202A <= cp <= 0x202E
                                                       or 0x2066 <= cp <= 0x2069 or cp == 0x061C):
                        # Invisible BiDi controls ride along with the text
                        # around them instead of starting a run of their own.
                        cur_font_path = last_font_path
                    else:
                        # (Spaces take the fallback font's space — see
                        # _find_best_font_path_code.)
                        cur_font_path = self._find_best_font_path_code(cp, r_face_str, primary_space)

                    if last_font_path is not None and cur_font_path != last_font_path:
                        if sub_len > 0:
                            run_text = PyUnicode_FromKindAndData(PyUnicode_4BYTE_KIND, &clean_codes[sub_start], sub_len)
                            item_runs.append((run_text, last_font_path, r_color_tup, s_group, r_face_str, aa_toggle_flag, r_size, r_tag_seq, r_rtl, r_script))
                        sub_start = run_start + ki
                        sub_len = 1
                    else:
                        sub_len += 1
                    last_font_path = cur_font_path

                if sub_len > 0:
                    run_text = PyUnicode_FromKindAndData(PyUnicode_4BYTE_KIND, &clean_codes[sub_start], sub_len)
                    item_runs.append((run_text, last_font_path, r_color_tup, s_group, r_face_str, aa_toggle_flag, r_size, r_tag_seq, r_rtl, r_script))

                # Pieces of a right-to-left item go right-to-left.
                if r_rtl:
                    item_runs.reverse()
                result_runs.extend(item_runs)

            if nl_pos is not None:
                # Breaks after the last item (trailing "\n"s): empty lines.
                while cur_line < len(nl_pos):
                    result_runs.append(None)
                    cur_line += 1

        finally:
            if heap_in: free(in_codes)
            if heap_clean: free(clean_codes)
            if heap_runs: free(runs_buf)
            if heap_items: free(items)

        return result_runs

    cpdef render_outline(self, str text, int size, object color=(255, 255, 255),
                          tuple outline_color=(0, 0, 0), int outline_width=1,
                          bint dynamic=False, str face="", bint use_primary_space=False,
                          str direction="auto"):
        """Like render() but with an outline — COMPLETELY SEPARATE from
        the original render() so it costs zero extra overhead on the
        cache-hit path of render() when outline isn't used."""
        cdef object base_surf = self.render(text, size, color, dynamic, face, use_primary_space, direction)
        cdef tuple o_key
        cdef object o_surf
        if outline_width <= 0 or outline_color is None:
            return base_surf
        if dynamic:
            return self._apply_outline(base_surf, outline_color, outline_width)
        # Static text: cache the outlined result too — building it (mask +
        # dilation blits) costs ~0.6ms+, which used to be paid on EVERY call
        # even though the plain render() underneath was a cache hit.
        o_key = ("\x00outline", text, size, color, face.lower() if face else self.init_face,
                 outline_color, outline_width, use_primary_space, direction)
        o_surf = self._text_cache.c_get(o_key)
        if o_surf is None:
            o_surf = self._apply_outline(base_surf, outline_color, outline_width)
            self._text_cache.c_set(o_key, o_surf)
        return o_surf

    cdef object _apply_outline(self, object surf, tuple outline_color, int width):
        """Draws an outline around text using a silhouette (pygame.mask)
        blitted at multiple offsets — pure pygame post-processing, doesn't touch FreeType/HarfBuzz."""
        cdef object mask, outline_shape, canvas, row
        cdef int w, h, dx, dy

        mask = pygame.mask.from_surface(surf)
        outline_shape = mask.to_surface(
            setcolor=(outline_color[0], outline_color[1], outline_color[2], 255),
            unsetcolor=(0, 0, 0, 0)
        )

        w = surf.get_width()  + width * 2
        h = surf.get_height() + width * 2

        # Square dilation is separable: smear the (fully opaque) silhouette
        # horizontally, then smear THAT vertically. 2*(2w+1) blits instead
        # of (2w+1)^2 - 1 — 10 vs 24 at width=2, 14 vs 48 at width=3 — for
        # the same outline, since the union of opaque shapes doesn't depend
        # on the order they're blitted in.
        row = pygame.Surface((w, surf.get_height()), pygame.SRCALPHA)
        for dx in range(2 * width + 1):
            row.blit(outline_shape, (dx, 0))
        canvas = pygame.Surface((w, h), pygame.SRCALPHA)
        for dy in range(2 * width + 1):
            canvas.blit(row, (0, dy))

        canvas.blit(surf, (width, width))
        return canvas

    cpdef render(self, str text, int size, object color=(255, 255, 255), bint dynamic=False, str face="",
                 bint use_primary_space=False, str direction="auto"):
        """This function has been improved to allow you to call the original pygame syntax, but will
        use the syntax from pygame.freetype!
        Example:
        font = font.render("Here is sample text", size = 20, color = (255, 255, 255), face="regular")
        screen.blit(font, (100, 200))

        NOTE: with dynamic=False the SAME cached Surface object is returned
        on every call (that's what makes a cache hit ~0.5us). Don't modify
        it in place (set_alpha, fill, blit onto it...) — that would change
        every later render of that text too. Call .copy() first:
            faded = font.render("Game Over", 40).copy(); faded.set_alpha(128)

        use_primary_space: spaces normally take the FALLBACK font's space
        width, so all spaces in mixed-script text match. Pass True to use the
        primary font's own space instead — needed for monospace fonts (e.g.
        JetBrains Mono) to keep columns aligned, and a little faster for
        Latin text (a line stays one shaped run instead of word pieces).

        color: an (R, G, B) tuple, or a gradient built with
        dynamic_font.gradient([...], angle).

        direction: "auto" (default) takes the paragraph direction from its
        first strong character, like the Unicode BiDi algorithm does — an
        Arabic / Hebrew sentence lays out right-to-left, with numbers,
        punctuation and embedded Latin text placed accordingly. "ltr" / "rtl"
        force it (e.g. a right-to-left UI whose label starts with a number).

        Line breaks: "\n" (or "\r\n") starts a new line. Lines are
        left-aligned, one font line height apart, in one Surface; tags and
        ^X colors carry across lines, and a gradient covers the whole block."""
        if not face:
            face = self.init_face
        else:
            face = face.lower()
        # HOT PATH — static text already rendered with the default options:
        # a single cache lookup and nothing else. In a game loop the CPU
        # caches are cold at the start of every frame, and each extra step
        # run before this lookup (color checks, tag scans, option parsing)
        # showed up as microseconds per call at 60 FPS. A text with named
        # color tags misses here (its cache key holds the resolved values)
        # and takes the full path below.
        cdef object _hot
        if self._palette_gen != _PALETTE_GEN:
            # RICH_PALETTE changed since this font last rendered: cached
            # text may hold the old ^X colors (one C integer compare otherwise).
            self._palette_gen = _PALETTE_GEN
            self._text_cache.clear()
        if (not dynamic and not use_primary_space and direction == "auto"
                and (type(color) is tuple or type(color) is Gradient)):
            _hot = self._text_cache.c_get((text, size, color, face))
            if _hot is not None:
                return _hot
        if type(color) is not tuple and not isinstance(color, Gradient):
            color = _normalize_color(color)
        # Color tags naming a variable (color(ORANGE)): resolve them in the
        # caller's scope first — the caches below then key on the values.
        # sys._getframe(0) is the CALLER: this compiled function has no frame.
        if '<' in text and ('olor' in text or 'OLOR' in text):
            text = _expand_color_names(text, sys._getframe(0))
        cdef int base_dir = _direction_code(direction)

        # CYTHON OPTIMIZATION: Strict C89 declarations for maximum speed and MSVC compliance.
        # === ALL cdef HERE — before the early-return, to avoid C89 errors ===
        cdef tuple cache_key = ((text, size, color, face) if not use_primary_space and base_dir == CP_DIR_AUTO
                                else (text, size, color, face, use_primary_space, base_dir))
        cdef bint multiline
        cdef object _cached
        cdef bint is_pure_ascii = True, is_printable
        cdef Py_UCS4 _ch
        cdef int std_h, total_logic_w, cur_x, w_adv, fixed_h, actual_final_w
        cdef Py_ssize_t idx, last_idx, n_surfs, t_len = len(text)
        cdef FontMetricData _std_m
        cdef object final_surf, s
        cdef object current_p_path, current_f_path, ascii_path, ch_path, word_path
        cdef object fast_runs
        cdef tuple runs_key
        cdef list runs = [], layouts = [], colors = [], tag_seqs = []
        cdef dict tag_box
        cdef object seq, box
        cdef int ink_top, ink_bot, main_base, line_base, line_h, dy
        cdef list run_dy
        cdef _RunLayout lay
        cdef object px_array, shifts
        cdef unsigned int[:, :] px_view

        # =========================================================================
        # THE EARLY EXIT: O(1) Static Text Cache Lookup — uses c_get (single dict lookup)
        # =========================================================================
        if not dynamic:
            _cached = self._text_cache.c_get(cache_key)
            if _cached is not None:
                return _cached

        self._ensure_init()

        # Line breaks: "\r\n" and a lone "\r" count as "\n". (After the
        # cache lookup, so the cache keys on the text as the caller wrote it.)
        if '\r' in text:
            text = text.replace('\r\n', '\n').replace('\r', '\n')
        multiline = '\n' in text

        # O(1) Base Path Resolution
        current_p_path = self._get_true_path(self.primary_name, face)
        current_f_path = self._get_true_path(self.fallback_name, face)

        # -----------------------------------------------------------
        # FAST PATH: Dynamic ASCII bypass
        # Routes formatted syntax (< or }) to the Full Pipeline automatically
        # -----------------------------------------------------------
        fast_runs = None
        if t_len > 0 and base_dir != CP_DIR_FORCE_RTL and not multiline:   # plain ASCII can't turn right-to-left on its own
            ascii_path = None
            is_printable = True
            for idx in range(t_len):
                _ch = text[idx]
                if _ch > 127 or _ch == '^' or _ch == '<' or _ch == '}':
                    is_pure_ascii = False
                    break
                if _ch < 32 or _ch == 127:
                    is_printable = False
            if is_pure_ascii and is_printable:
                # One font covers ALL printable ASCII (the usual case): no
                # per-character font lookup needed at all.
                ascii_path = self._ascii_font_path(face, use_primary_space)
                if ascii_path is None:
                    # Words in one font, spaces in another (the default:
                    # spaces from the fallback font): cut the word / space
                    # pieces directly instead of running the tag parser and
                    # a font lookup per character.
                    word_path = self._ascii_word_path(face)
                    if word_path is not None:
                        fast_runs = self._split_space_runs(
                            text, word_path,
                            self._find_best_font_path_code(0x20, face, use_primary_space),
                            color, face)
            if not dynamic or fast_runs is not None:
                pass   # full pipeline below (static text gets cached there)
            elif is_pure_ascii and ascii_path is None:
                for idx in range(t_len):
                    # Same font choice as the full pipeline (honours MODERN_FONT,
                    # falls back when the primary lacks the glyph).
                    ch_path = self._find_best_font_path_code(<int>text[idx], face, use_primary_space)
                    if idx == 0:
                        ascii_path = ch_path
                    elif ch_path != ascii_path:
                        is_pure_ascii = False  # mixed fonts -> full pipeline splits it
                        break

            if dynamic and fast_runs is None and is_pure_ascii:
                # The whole string is shaped as ONE HarfBuzz run. This used to
                # draw each character separately and add up per-character
                # advances rounded to whole pixels: kerning pairs ("AV", "To",
                # "Ye") were lost and rounding error piled up along the line,
                # so the same text rendered with dynamic=True and dynamic=False
                # came out different. Glyph bitmaps are cached per glyph
                # (self._glyph_cache), so this stays fast frame after frame.
                return self._render_shaped_run(text, size, color, ascii_path, face)[0]

        # -----------------------------------------------------------
        # FULL PIPELINE: Multi-language, Bidi, Inline Face & Color parsing
        # (BiDi reordering & token lexing fully handled at C-level in c_parser.c)
        # -----------------------------------------------------------
        _std_m = self._get_metrics(size, face)
        std_h = <int>_std_m.height

        if fast_runs is not None:
            runs = fast_runs
        else:
            # ^X colors come from RICH_PALETTE, which may be edited at runtime:
            # texts using them key on the palette's current contents too.
            runs_key = (text, color, face, use_primary_space, base_dir,
                        _palette_key() if '^' in text else None)
            runs = <list>self._runs_cache.c_get(runs_key)
            if runs is None:
                runs = self._parse_render_accumulate(text, color, face, current_p_path, current_f_path,
                                                     use_primary_space, base_dir)
                self._runs_cache.c_set(runs_key, runs)

        if multiline:
            final_surf = self._compose_lines(runs, size, _std_m)
            if not dynamic:
                self._text_cache.c_set(cache_key, final_surf)
            return final_surf

        # ==========================================================
        # UNIVERSAL RENDERING: lay out every run first, then draw all their
        # glyphs straight into ONE surface. (Each run used to become its own
        # SRCALPHA surface that was then alpha-blitted onto the final one —
        # those blits cost more than drawing the glyphs.)
        # ==========================================================
        total_logic_w = 0
        for r_text, r_path, r_color, _, r_face, r_aa_toggle, r_size, r_tag_seq, r_rtl, r_script in runs:
            if r_text:
                # Use r_face (the run's active_face) instead of the default face,
                # and the run's inline size tag if it has one.
                lay = self._get_layout(r_text, r_size if r_size > 0 else size, r_path, r_face, r_aa_toggle,
                                       r_rtl, r_script)
                layouts.append(lay)
                colors.append(r_color)
                tag_seqs.append(r_tag_seq)
                total_logic_w += lay.logic_w

        n_surfs = len(layouts)
        if n_surfs == 1:
            final_surf = self._layout_to_surface(<_RunLayout>layouts[0], colors[0])
        elif n_surfs == 0:
            final_surf = pygame.Surface((1, <int>(std_h * 1.5)), pygame.SRCALPHA)
        else:
            if total_logic_w <= 0: total_logic_w = 1
            # MUST match _layout_run's own final_h formula exactly.
            fixed_h = <int>(std_h * 1.5)

            # Shared baseline for runs of different sizes (inline size tags):
            # runs at render()'s size sit on its baseline (exactly as before);
            # a bigger run pushes the shared baseline down so it fits, and
            # every run is shifted down by (shared - its own) baseline.
            main_base = <int>(_std_m.asc + 0.5)
            line_base = main_base
            for idx in range(n_surfs):
                lay = <_RunLayout>layouts[idx]
                if lay.size != size and lay.baseline_y > line_base:
                    line_base = lay.baseline_y
            line_h = fixed_h + (line_base - main_base)
            run_dy = []
            for idx in range(n_surfs):
                lay = <_RunLayout>layouts[idx]
                dy = line_base - (lay.baseline_y if lay.size != size else main_base)
                run_dy.append(dy)
                if lay.size != size and dy + lay.final_h > line_h:
                    line_h = dy + lay.final_h

            # Subpixel bleeding prevention: the last run keeps its full ink width
            lay = <_RunLayout>layouts[n_surfs - 1]
            actual_final_w = (total_logic_w - lay.logic_w) + lay.ink_w
            if actual_final_w <= 0: actual_final_w = 1

            # Vertical ink extent of the whole line (glyph runs only).
            ink_top = 1 << 30
            ink_bot = -(1 << 30)
            for idx in range(n_surfs):
                lay = <_RunLayout>layouts[idx]
                dy = <int>run_dy[idx]
                if lay.surf is None and lay.has_ink:
                    if lay.ink_top + dy < ink_top: ink_top = lay.ink_top + dy
                    if lay.ink_bot + dy > ink_bot: ink_bot = lay.ink_bot + dy
            if ink_top >= ink_bot:
                ink_top = 0
                ink_bot = std_h
            # Glyphs reaching above the line (a fallback font's stacked marks
            # next to a tight .dfbmp line: "ẫ") push the whole line down;
            # glyphs reaching below it make it taller. Nothing is cut off.
            if ink_top < 0:
                dy = -ink_top
                for idx in range(n_surfs):
                    run_dy[idx] = <int>run_dy[idx] + dy
                line_h += dy
                ink_top += dy
                ink_bot += dy
            if ink_bot > line_h:
                line_h = ink_bot

            final_surf = pygame.Surface((actual_final_w, line_h), pygame.SRCALPHA)
            shifts = final_surf.get_shifts()

            # A gradient from a color TAG covers just that tag's text:
            # tag_seq -> [x0, x1, ink_top, ink_bot] over all runs of the tag.
            tag_box = {}
            cur_x = 0
            for idx in range(n_surfs):
                lay = <_RunLayout>layouts[idx]
                seq = tag_seqs[idx]
                if seq:
                    dy = <int>run_dy[idx]
                    box = tag_box.get(seq)
                    if box is None:
                        box = [cur_x, cur_x + lay.ink_w, 1 << 30, -(1 << 30)]
                        tag_box[seq] = box
                    if cur_x < box[0]: box[0] = cur_x
                    if cur_x + lay.ink_w > box[1]: box[1] = cur_x + lay.ink_w
                    if lay.has_ink:
                        if lay.ink_top + dy < box[2]: box[2] = lay.ink_top + dy
                        if lay.ink_bot + dy > box[3]: box[3] = lay.ink_bot + dy
                cur_x += lay.logic_w
            for box in tag_box.values():
                if box[2] >= box[3]:
                    box[2] = ink_top
                    box[3] = ink_bot

            px_array = pygame.PixelArray(final_surf)
            px_view = px_array
            cur_x = 0
            for idx in range(n_surfs):
                lay = <_RunLayout>layouts[idx]
                if lay.surf is None and lay.has_ink:   # spaces have nothing to draw
                    seq = tag_seqs[idx]
                    if seq:
                        # gradient from a color tag: that tag's own text
                        box = tag_box[seq]
                        self._draw_layout(lay, colors[idx], px_view, actual_final_w, line_h, cur_x,
                                          <int>run_dy[idx], shifts,
                                          box[0], box[1] - box[0], box[2], box[3] - box[2], size)
                    else:
                        # Gradient box = the whole line, so it sweeps once across all runs.
                        self._draw_layout(lay, colors[idx], px_view, actual_final_w, line_h, cur_x,
                                          <int>run_dy[idx], shifts,
                                          0, actual_final_w, ink_top, ink_bot - ink_top, size)
                cur_x += lay.logic_w
            px_view = None
            px_array.close()

            # Pre-rendered runs (emoji) are real surfaces — blit those.
            cur_x = 0
            for idx in range(n_surfs):
                lay = <_RunLayout>layouts[idx]
                if lay.surf is not None:
                    final_surf.blit(lay.surf, (cur_x, <int>run_dy[idx]))
                cur_x += lay.logic_w

        # Cache valid outputs
        if not dynamic:
            self._text_cache.c_set(cache_key, final_surf)

        # LRU Cache Eviction to prevent memory leaks
        # Eviction now happens automatically in _LRUCache.__setitem__ — no manual loop needed

        return final_surf

    cpdef get_debug_info(self, object text_input, str face="", bint use_primary_space=False,
                         str direction="auto"):
        """
        Returns detailed per-character rendering metadata — the same
        decisions render() makes (tags, fonts, BiDi, scripts).
        Fields per character:
          char        : the original character
          hex         : Unicode codepoint (U+XXXX)
          category    : Unicode category (Lu, Ll, Lo, ...)
          script      : Unicode script (UAX #24) as render() itemizes it:
                        "Latin", "Arabic", "Han", "Devanagari", ...
                        (Common/Inherited characters take the script of the
                        text around them)
          script_tag  : ISO 15924 tag of that script ("Latn", "Arab", ...)
          bidi_level  : UAX #9 embedding level (odd = right-to-left)
          direction   : "LTR" / "RTL" (from bidi_level)
          font        : actual font file name
          font_source : PRIMARY / FALLBACK / EMOJI / INTL / MISSING
          ttc_index   : index within the TTC (-1 for regular TTF)
          has_glyph   : whether the glyph exists in the font
          synthetic   : NONE / BOLD / ITALIC / BOLD+ITALIC
          render_path : SHAPED (HarfBuzz) / BITMAP (.dfbmp font) /
                        EMOJI (color emoji renderer) /
                        NEWLINE (line break) /
                        IGNORED (control character dropped before shaping)
          tag_context : the currently active face tag (if any inline tag)
          size        : the active inline size tag's size, None = render()'s size
          color       : the active color tag's (R, G, B) or gradient, None = no color tag
          is_tag      : True if this char is part of an inline tag (skipped when rendering)
        direction= is render()'s: "auto", "ltr" or "rtl".
        """
        self._ensure_init()

        if not face:
            face = self.init_face
        else:
            face = face.lower()
        cdef int base_dir = _direction_code(direction)

        cdef str text = str(text_input)
        if '<' in text and ('olor' in text or 'OLOR' in text):
            text = _expand_color_names(text, sys._getframe(0))
        cdef int n = <int>len(text)
        if n == 0:
            return []

        cdef unsigned int stack_in[512]
        cdef unsigned int stack_clean[512]
        cdef unsigned char stack_lv[512]
        cdef unsigned char stack_sc[512]
        cdef CP_DebugToken stack_tokens[512]
        cdef CP_PaletteEntry palette_table[256]
        memset(palette_table, 0, sizeof(palette_table))

        cdef object p_key, p_val
        cdef int p_code
        for p_key, p_val in RICH_PALETTE.items():
            if isinstance(p_key, str) and len(p_key) == 1:
                p_code = ord(p_key)
                if 0 <= p_code < 256:
                    palette_table[p_code].r = <unsigned char>p_val[0]
                    palette_table[p_code].g = <unsigned char>p_val[1]
                    palette_table[p_code].b = <unsigned char>p_val[2]
                    palette_table[p_code].is_set = 1

        cdef unsigned int* in_codes = stack_in
        cdef unsigned int* clean = stack_clean
        cdef unsigned char* levels = stack_lv
        cdef unsigned char* scripts = stack_sc
        cdef CP_DebugToken* tokens_buf = stack_tokens
        cdef bint heap = n > 512
        if heap:
            in_codes = <unsigned int*>malloc(n * sizeof(unsigned int))
            clean = <unsigned int*>malloc(n * sizeof(unsigned int))
            levels = <unsigned char*>malloc(n)
            scripts = <unsigned char*>malloc(n)
            tokens_buf = <CP_DebugToken*>malloc(n * sizeof(CP_DebugToken))
            if (in_codes == NULL or clean == NULL or levels == NULL
                    or scripts == NULL or tokens_buf == NULL):
                free(in_codes); free(clean); free(levels); free(scripts); free(tokens_buf)
                raise MemoryError()

        cdef list info = []
        cdef int idx, ti, ci, n_clean, num_tokens, code, sc, lv, ttc_index
        cdef unsigned int stag
        cdef bytes face_bytes = face.encode('utf-8')
        cdef CP_DebugToken* tok
        cdef const char* last_face_c = NULL
        cdef str active_f = face, ch
        cdef dict face_ctx = {}, path_ctx = {}, script_cache = {}, char_cache = {}
        cdef tuple fctx, pinfo, syn_flags, sinfo, cinfo
        cdef object path, primary_p, fallback_p, emoji_p = self.emoji_path
        cdef object pkey
        cdef str fname, font_source, synthetic_str, render_path
        cdef size_t ft_face
        cdef bint has_g
        cdef const char* sname
        cdef long long color_key, last_color_key = -(1LL << 40)
        cdef object color_val = None, last_path = None, last_pface = None, last_pinfo = None
        cdef tuple last_sinfo = None
        cdef int last_sc = -1, t_lv = 0, t_size = 0
        cdef dict template = None, d
        cdef object t_pinfo = None, t_sinfo = None, t_rpath = None, t_face = None, tkey = None
        cdef long long t_color_key = 0
        cdef dict template_cache = {}

        try:
            for idx in range(n):
                in_codes[idx] = <unsigned int>ord(text[idx])
            num_tokens = cp_parse_debug(in_codes, n, face_bytes, palette_table, tokens_buf, n)

            # The characters render() shapes (tags and ignorable controls
            # removed), analyzed exactly as render()'s itemizer sees them.
            n_clean = 0
            for ti in range(num_tokens):
                if tokens_buf[ti].is_tag == 0 and not cp_is_ignorable(tokens_buf[ti].codepoint):
                    clean[n_clean] = tokens_buf[ti].codepoint
                    n_clean += 1
            if n_clean > 0 and cp_analyze_chars(clean, n_clean, base_dir, levels, scripts) < 0:
                raise MemoryError()

            ci = 0
            for ti in range(num_tokens):
                tok = &tokens_buf[ti]
                # Face tag context: decoded only when it changes.
                if last_face_c == NULL or strcmp(last_face_c, tok.active_face) != 0:
                    last_face_c = tok.active_face
                    active_f = tok.active_face.decode('utf-8', 'replace') or face

                color_key = (tok.has_color << 24 | tok.color.r << 16 | tok.color.g << 8 | tok.color.b
                             if tok.has_color != 2 else -tok.grad_id)
                if color_key != last_color_key:
                    last_color_key = color_key
                    if tok.has_color == 2:
                        color_val = _resolve_gradient(tok.grad_id, None)
                    elif tok.has_color:
                        color_val = (tok.color.r, tok.color.g, tok.color.b)
                    else:
                        color_val = None

                if tok.is_tag != 0:
                    info.append({
                        "char": " ", "hex": "TAG",
                        "category": "TAG", "script": "-", "script_tag": "-",
                        "bidi_level": -1, "direction": "-",
                        "font": "-", "font_source": "TAG",
                        "ttc_index": -1, "has_glyph": False,
                        "synthetic": "NONE", "render_path": "-",
                        "tag_context": active_f, "is_tag": True,
                        "size": tok.size or None,
                        "color": color_val,
                        "tag_type": tok.tag_type.decode('utf-8', 'replace')
                    })
                    continue

                code = <int>tok.codepoint
                cinfo = char_cache.get(code)
                if cinfo is None:
                    ch = chr(code)
                    cinfo = (ch, f"U+{code:04X}", unicodedata.category(ch))
                    char_cache[code] = cinfo

                # Per-face context, once per call.
                fctx = face_ctx.get(active_f)
                if fctx is None:
                    fctx = (self._get_true_path(self.primary_name, active_f),
                            self._get_true_path(self.fallback_name, active_f),
                            self._get_synthetic_flags(active_f))
                    face_ctx[active_f] = fctx

                path = self._find_best_font_path_code(code, active_f, use_primary_space)

                # Per-(face, font) facts, once per call: file name, source,
                # synthetic style and the FreeType face for the glyph check.
                if path is last_path and active_f is last_pface:
                    pinfo = last_pinfo
                else:
                    pkey = (active_f, id(path))
                    pinfo = path_ctx.get(pkey)
                if pinfo is None:
                    if path and self._is_bmp_path(path):
                        fname = os.path.basename(str(self.primary_name))
                        ttc_index = -1
                        ft_face = 0
                        font_source = "PRIMARY"
                    elif path:
                        if isinstance(path, (list, tuple)):
                            fname = os.path.basename(str(path[0]))
                            ttc_index = int(path[1]) if len(path) > 1 else -1
                            ft_face = <size_t>self._get_shared_ft_face(path[0], ttc_index if ttc_index > 0 else 0)
                        else:
                            fname = os.path.basename(str(path))
                            ttc_index = -1
                            ft_face = <size_t>self._get_shared_ft_face(path, 0)
                        primary_p = fctx[0]
                        fallback_p = fctx[1]
                        if path == primary_p or (isinstance(primary_p, (list, tuple)) and path == primary_p[0]):
                            font_source = "PRIMARY"
                        elif path == fallback_p or (isinstance(fallback_p, (list, tuple)) and path == fallback_p[0]):
                            font_source = "FALLBACK"
                        elif emoji_p and (path == emoji_p or (isinstance(emoji_p, (list, tuple)) and path == emoji_p[0])):
                            font_source = "EMOJI"
                        else:
                            font_source = "INTL"
                    else:
                        fname = "NOT_FOUND"
                        ttc_index = -1
                        ft_face = 0
                        font_source = "MISSING"

                    synthetic_str = "NONE"
                    if not self._is_bmp_path(path) and self._is_synthetic_needed("", active_f, path):
                        syn_flags = fctx[2]
                        if syn_flags[0] and syn_flags[1]:
                            synthetic_str = "BOLD+ITALIC"
                        elif syn_flags[0]:
                            synthetic_str = "BOLD"
                        elif syn_flags[1]:
                            synthetic_str = "ITALIC"
                    pinfo = (fname, ttc_index, font_source, synthetic_str, ft_face,
                             "BITMAP" if self._is_bmp_path(path) else
                             "EMOJI" if font_source == "EMOJI" else "SHAPED")
                    path_ctx[pkey] = pinfo
                last_path = path
                last_pface = active_f
                last_pinfo = pinfo

                ft_face = <size_t>pinfo[4]
                if ft_face != 0:
                    has_g = FT_Get_Char_Index(<FT_Face>ft_face, <unsigned long>code) != 0
                else:
                    has_g = pinfo[5] == "BITMAP" and code in self._bmp.index

                if cp_is_ignorable(tok.codepoint):
                    render_path = "IGNORED"
                    sinfo = _DBG_NO_SCRIPT
                    lv = -1
                else:
                    render_path = "NEWLINE" if code == 10 else <str>pinfo[5]
                    sc = scripts[ci]
                    lv = levels[ci]
                    ci += 1
                    sinfo = last_sinfo if sc == last_sc else script_cache.get(sc)
                    if sinfo is None:
                        sname = cp_script_name(sc)
                        stag = cp_script_tag(sc)
                        sinfo = ((sname.decode('ascii') if sname != NULL else "Unknown"),
                                 (bytes([(stag >> 24) & 0xFF, (stag >> 16) & 0xFF, (stag >> 8) & 0xFF,
                                         stag & 0xFF]).decode('ascii') if stag else "-"))
                        script_cache[sc] = sinfo
                    last_sc = sc
                    last_sinfo = sinfo

                # Characters mostly share everything but the character
                # itself: copy a template dict (one C-level clone) and set the
                # per-character keys, instead of building all 18 keys for
                # every character. Templates are kept per combination, so
                # text alternating between fonts (words / fallback spaces)
                # doesn't rebuild them. (pinfo / sinfo live in the caches
                # above for the whole call, so their ids are stable.)
                if (template is None or pinfo is not t_pinfo or sinfo is not t_sinfo or lv != t_lv
                        or render_path is not t_rpath or active_f is not t_face
                        or tok.size != t_size or color_key != t_color_key):
                    t_pinfo = pinfo; t_sinfo = sinfo; t_lv = lv; t_rpath = render_path
                    t_face = active_f; t_size = tok.size; t_color_key = color_key
                    tkey = (id(pinfo), id(sinfo), lv, render_path, active_f, tok.size, color_key)
                    template = template_cache.get(tkey)
                if template is None:
                    template = {
                        "char": None,
                        "hex": None,
                        "category": None,
                        "script": sinfo[0],
                        "script_tag": sinfo[1],
                        "bidi_level": lv,
                        "direction": "-" if lv < 0 else ("RTL" if lv & 1 else "LTR"),
                        "font": pinfo[0],
                        "font_source": pinfo[2],
                        "ttc_index": pinfo[1],
                        "has_glyph": False,
                        "synthetic": pinfo[3],
                        "render_path": render_path,
                        "tag_context": active_f,
                        "size": tok.size or None,
                        "color": color_val,
                        "is_tag": False,
                        "tag_type": "-"
                    }
                    template_cache[tkey] = template
                d = template.copy()
                d["char"] = cinfo[0]
                d["hex"] = cinfo[1]
                d["category"] = cinfo[2]
                if has_g:
                    d["has_glyph"] = True
                info.append(d)
        finally:
            if heap:
                free(in_codes); free(clean); free(levels); free(scripts); free(tokens_buf)

        return info
      
# VARIABLE PROTECT CLASS
class _ProtectedEngine(types.ModuleType):
    
    # 1. OVERWRITING SELECTION (SET)
    def __setattr__(self, name, value):
        # Preventing the overwriting of internal system variables
        if name in PROTECTED_VARS:
            print(f"[WARNING]: The variable '{name}' is a protected local variable ( Read-Only ). Ignoring the action of overwriting its value...")
            return 

        # A whole new palette: keep it noticing its own changes, and count it.
        if name == "RICH_PALETTE":
            if not isinstance(value, dict):
                print(f"[WARNING]: Invalid value for 'RICH_PALETTE'. It must be a dict like "
                      f"{{'1': (255, 50, 50)}}. Ignoring this assignment...")
                return
            super().__setattr__(name, _Palette(value))
            _palette_changed()
            return

        # Validate the type and logical range of the exported configuration variables
        if name in _CONFIG_VALIDATORS:
            expected_type, msg = _CONFIG_VALIDATORS[name]
            
            # Strict check for boolean (since isinstance(True, int) is True in Python)
            if expected_type is bool:
                if not isinstance(value, bool):
                    print(f"[WARNING]: Invalid value for '{name}'. It must be {msg}. Ignoring this assignment...")
                    return
            else:
                if not isinstance(value, expected_type):
                    print(f"[WARNING]: Invalid value for '{name}'. It must be {msg}. Ignoring this assignment...")
                    return
                
                # Prevent negative or zero values for cache configurations
                if expected_type is int and value <= 0:
                    print(f"[WARNING]: Invalid value for '{name}'. It must be greater than 0. Ignoring this assignment...")
                    return

                # Prevent extreme values for Emoji offset
                if name == "EMOJI_OFFSET_Y" and not (-2.0 <= value <= 2.0):
                    print(f"[WARNING]: Invalid value for '{name}'. Value is outside of safe range (-2.0 to 2.0). Ignoring this assignment...")
                    return
            
        super().__setattr__(name, value)

    #2. ANTI-DELETION LOGIC
    def __delattr__(self, name):
        if name in PROTECTED_VARS:
            print(f"[WARNING]: The variable '{name}' is a protected local variable ( Read-Only ). Ignoring the action of deleting its variable...")
            return
            
        # Block the delete command for the REMAINING VARIABLES (SMOOTH_FONT, MODERN_FONT...)
        print(f"[WARNING]: The variable '{name}' is a Read-And-Write Only variable. Ignoring the action of deleting its variable...")
        return

# Call Proctect Engine
sys.modules[__name__].__class__ = _ProtectedEngine
