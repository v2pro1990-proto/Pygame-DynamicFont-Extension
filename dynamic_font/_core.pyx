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
import uharfbuzz as hb
import gc
from collections import OrderedDict
from libc.string cimport memset, memcpy
from libc.stdlib cimport malloc, realloc, free

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
MAX_GLYPH_CACHE = 2500
MAX_FONT_OBJ_CACHE = 256    # distinct (path,index,size,face) font-object combos
MAX_HB_FONT_CACHE  = 64     # distinct (path,index) HarfBuzz fonts — far fewer than sizes
MAX_PATH_CACHE     = 4000   # distinct (char,face) -> font-path resolutions

#======================================================================
"""This variable is an API that informs the main game program that it is scanning for fonts in the system.
It can read the value of this variable to display the loading screen, avoiding the
"Not Responding" error window which is aesthetically unpleasing!"""
# NOTE: THIS VARIABLE CAN ONLY BE READ FROM THE MAIN PROGRAM! IMPOSSIBLE TO OVERWRITE ITS VALUE TO AVOID SYSTEM ERRORS!!!
cdef bint _is_scanning = False
# This tuple is initialized for comparison in the protection mechanism.

#=====================================================================
# NEW IN V1.3 : Now embbeded FreeType to Extension
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

RICH_PALETTE = {
    '0': (255, 255, 255), '1': (255, 50, 50),   '2': (50, 255, 50),
    '3': (80, 150, 255),  '4': (255, 255, 50),  '5': (255, 50, 255),
    '6': (50, 255, 255),  '7': (200, 200, 200), '8': (100, 100, 100),
    '9': (0, 0, 0), 'a': (102, 178, 255)
}

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
        if low.endswith((".ttf", ".otf", ".ttc")) or os.sep in name or "/" in name:
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

    try:
        ft_lib = _ensure_ft_library()
        if sys.platform == "win32":
            font_dirs = [
                r"C:/Windows/Fonts",
                os.path.expanduser(r"~/AppData/Local/Microsoft/Windows/Fonts")
            ]
        elif sys.platform == "linux":
            font_dirs = ["/usr/share/fonts", "/usr/local/share/fonts", os.path.expanduser("~/.local/share/fonts")]
        elif sys.platform == "darwin":
            font_dirs = ["/Library/Fonts", os.path.expanduser("~/Library/Fonts")]

        c_dir_bytes = [d.encode('utf-8') for d in font_dirs if os.path.exists(d)]
        num_dirs = <int>len(c_dir_bytes)
        for i in range(num_dirs):
            dir_ptrs[i] = c_dir_bytes[i]

        print("[SYSTEM] Scanning and indexing system fonts...")
        c_scan_system_fonts(ft_lib, dir_ptrs, num_dirs, &scan_res)

        for i in range(scan_res.count):
            font_name_str = scan_res.entries[i].full_name.decode('utf-8', errors='ignore')
            norm_name_str = scan_res.entries[i].norm_name.decode('utf-8', errors='ignore')
            path_str = scan_res.entries[i].file_path.decode('utf-8', errors='ignore')
            face_idx = scan_res.entries[i].face_index

            paths[font_name_str.lower()] = [path_str, face_idx]
            if norm_name_str.lower() != font_name_str.lower():
                names[norm_name_str.lower()] = font_name_str.lower()

        c_free_font_scan_result(&scan_res)
        print(f"[SUCCESS] Scan Finished {len(paths)} Font faces!")
        return {"paths": paths, "names": names}
    finally:
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

    c_dir_bytes = [d.encode('utf-8') for d in font_dirs if os.path.exists(d)]
    num_dirs = <int>len(c_dir_bytes)
    if num_dirs == 0:
        return ""

    for i in range(num_dirs):
        dir_ptrs[i] = c_dir_bytes[i]

    c_get_fonts_fingerprint(dir_ptrs, num_dirs, fingerprint_buf, 1024)
    return fingerprint_buf.decode('utf-8')

def load_or_update_font_map():
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

    ctypedef struct CP_DebugToken:
        unsigned int codepoint
        int is_tag
        char tag_type[32]
        char active_face[32]
        int script_group

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


cpdef get_engine_version(bint include_cython=False):
    cdef unsigned char hex_bytes[15]
    hex_bytes[0] = 0x76   # v
    hex_bytes[1] = 0x31   # 1
    hex_bytes[2] = 0x2e   # .
    hex_bytes[3] = 0x32   # 2
    hex_bytes[4] = 0x2e   # .
    hex_bytes[5] = 0x33   # 3
    hex_bytes[6] = 0x2d   # -
    hex_bytes[7] = 0x72   # r
    hex_bytes[8] = 0x65   # e
    hex_bytes[9] = 0x6c   # l
    hex_bytes[10] = 0x65  # e
    hex_bytes[11] = 0x61  # a
    hex_bytes[12] = 0x73  # s
    hex_bytes[13] = 0x65  # e
    hex_bytes[14] = 0x00  # null terminator
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
    size_t buf_off

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


cdef class DynamicFont:
    """(primary_name, fallback_name, fallback_dir, emoji_path, init_face)
    Intalize DynamicFont Object to Render -> Compas"""
    cdef str primary_name, fallback_name, fallback_dir, emoji_path
    cdef object _primary_path   # [path, index] if primary is a bundled file
    cdef object _fallback_path  # [path, index] if fallback is a bundled file
    cdef bint _anti_alias       # set at init time, doesn't change at runtime
    cdef _LRUCache _font_objs, _hb_fonts, _path_cache, _glyph_check_faces
    cdef dict _pg_font_cache
    cdef dict _std_metrics, _font_map, _path_resolve_cache
    cdef list _intl_font_paths
    cdef public dict emoji_fallback_engine
    cdef FT_Face _emoji_ft_face      # real FT_Face pointer (not via freetype-py)
    cdef bint _emoji_colr_checked   # whether the emoji font's COLR support has been checked
    cdef bint _emoji_has_colr       # result: emoji font DOES support COLRv0
    cdef bint _emoji_has_colrv1     # result: emoji font DOES support COLRv1 (Solid + LinearGradient)
    cdef bint _emoji_has_cbdt       # result: emoji font DOES support CBDT (embedded PNG bitmap)
    cdef public _LRUCache _glyph_cache, _text_cache
    cdef bint _initialized
    cdef object _cached_p_path
    cdef object _cached_f_path_std
    cdef public str init_face
    

    def __init__(self, 
                 primary_name="Arial", 
                 fallback_name="Times New Roman", 
                 fallback_dir=None, 
                 emoji_path=None,
                 init_face="regular"):
        # fallback_dir/emoji_path default to None (not a hardcoded
        # relative path) specifically so "the caller didn't specify
        # this" is unambiguous — auto-detection only kicks in for the
        # genuine default case, never silently overriding a path the
        # caller actually passed (including an intentional empty
        # string, which stays as-is rather than being auto-replaced).
        if fallback_dir is None:
            fallback_dir = _get_bundled_fallback_dir()
        if emoji_path is None:
            emoji_path = _auto_detect_emoji_path()

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
        self._hb_fonts = _LRUCache(MAX_HB_FONT_CACHE)
        self._path_cache = _LRUCache(MAX_PATH_CACHE)
        self._glyph_check_faces = _LRUCache(MAX_FONT_OBJ_CACHE)
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
        if self._fallback_path is None:
            check_f_path = self._get_true_path(self.fallback_name, self.init_face)
            if check_f_path:
                if isinstance(check_f_path, (list, tuple)):
                    check_p = <str>check_f_path[0]
                else:
                    check_p = <str>check_f_path
                if not os.path.exists(check_p):
                    self.fallback_name = ""

        if os.path.exists(self.fallback_dir):
            self._intl_font_paths = [os.path.join(self.fallback_dir, f) 
                                     for f in os.listdir(self.fallback_dir) 
                                     if f.lower().endswith((".ttf", ".otf", ".ttc"))]
        self._anti_alias = <bint>ANTI_ALIAS
        self._initialized = True

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
        cdef int result, err
        cdef bytes py_bytes
        cdef object surf
        cdef bytes path_bytes
        cdef FT_Face _tmp_face

        if not self._emoji_colr_checked:
            self._emoji_colr_checked = True
            try:
                path_bytes = self.emoji_path.encode("utf-8")
                err = FT_New_Face(_ensure_ft_library(), path_bytes, 0, &_tmp_face)
                if err != 0:
                    self._emoji_ft_face = NULL
                    self._emoji_has_colr = False
                    self._emoji_has_colrv1 = False
                    self._emoji_has_cbdt = False
                else:
                    self._emoji_ft_face = _tmp_face
                    FT_Set_Pixel_Sizes(self._emoji_ft_face, 0, size)
                    self._emoji_has_colr = True
                    self._emoji_has_colrv1 = True
                    self._emoji_has_cbdt = True
            except Exception:
                self._emoji_ft_face = NULL
                self._emoji_has_colr = False
                self._emoji_has_colrv1 = False
                self._emoji_has_cbdt = False

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

        py_bytes = (<char*>rgba_buf)[:w * h * 4]
        free(rgba_buf)
        surf = pygame.image.frombuffer(py_bytes, (w, h), "RGBA").convert_alpha()
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
        cdef bytes py_bytes
        cdef object surf

        if not self._emoji_has_colrv1 or self._emoji_ft_face == NULL or glyph_id == 0:
            return None, 0, 0

        FT_Set_Pixel_Sizes(self._emoji_ft_face, 0, size)
        result = render_colrv1_glyph(self._emoji_ft_face, glyph_id, <int>apply_italic, &rgba_buf, &w, &h, &top, &left)
        if result != 0 or rgba_buf == NULL or w <= 0 or h <= 0:
            return None, 0, 0

        py_bytes = (<char*>rgba_buf)[:w * h * 4]
        free(rgba_buf)
        surf = pygame.image.frombuffer(py_bytes, (w, h), "RGBA").convert_alpha()
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
        cdef int result, err
        cdef bytes py_bytes
        cdef object surf
        cdef bytes path_bytes
        cdef FT_Face _tmp_face

        if not self._emoji_colr_checked:
            self._emoji_colr_checked = True
            try:
                path_bytes = self.emoji_path.encode("utf-8")
                err = FT_New_Face(_ensure_ft_library(), path_bytes, 0, &_tmp_face)
                if err != 0:
                    self._emoji_ft_face = NULL
                    self._emoji_has_colr = False
                    self._emoji_has_colrv1 = False
                    self._emoji_has_cbdt = False
                else:
                    self._emoji_ft_face = _tmp_face
                    FT_Set_Pixel_Sizes(self._emoji_ft_face, 0, size)
                    # Optimistic — both self-correct to False on first real
                    # render_colrv0_glyph()/render_colrv1_glyph() failure
                    # with a "not supported" result code (see below).
                    self._emoji_has_colr = True
                    self._emoji_has_colrv1 = True
                    self._emoji_has_cbdt = True
            except Exception:
                self._emoji_ft_face = NULL
                self._emoji_has_colr = False
                self._emoji_has_colrv1 = False
                self._emoji_has_cbdt = False

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

        py_bytes = (<char*>rgba_buf)[:w * h * 4]
        free(rgba_buf)
        surf = pygame.image.frombuffer(py_bytes, (w, h), "RGBA").convert_alpha()
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
        cdef bytes py_bytes
        cdef object surf

        if not self._emoji_has_colr or self._emoji_ft_face == NULL or glyph_id == 0:
            return None, 0, 0

        FT_Set_Pixel_Sizes(self._emoji_ft_face, 0, size)
        result = render_colrv0_glyph(self._emoji_ft_face, glyph_id, <int>apply_italic, &rgba_buf, &w, &h, &top, &left)
        if result != 0 or rgba_buf == NULL or w <= 0 or h <= 0:
            if result == 1 or result == 2:
                self._emoji_has_colr = False
            return None, 0, 0

        py_bytes = (<char*>rgba_buf)[:w * h * 4]
        free(rgba_buf)
        surf = pygame.image.frombuffer(py_bytes, (w, h), "RGBA").convert_alpha()
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
        embeds (e.g. only 128px for one common NotoColorEmoji build) —
        render_cbdt_glyph() itself picks the closest available strike
        (see cbdt_render.c), which will generally NOT match `size`
        exactly. The mismatch is corrected here via smoothscale, so the
        caller always gets back a surface sized for the requested `size`
        — quality at sizes far from the embedded strike will be softer
        than COLRv1/COLRv0's vector output, an inherent property of
        bitmap-based color glyphs, not a bug in this renderer."""
        cdef int code = ord(ch)
        cdef unsigned int glyph_index
        cdef unsigned char* rgba_buf = NULL
        cdef int w = 0, h = 0, top = 0, left = 0
        cdef int result
        cdef bytes py_bytes
        cdef object surf
        cdef double scale

        if not self._emoji_colr_checked:
            # Shares the SAME init block as COLRv0/COLRv1 — a throwaway
            # call to _render_colrv1_emoji triggers it if this is somehow
            # reached first (mirrors _render_colrv1_by_id's own pattern).
            self._render_colrv1_emoji(ch, size)

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

        py_bytes = (<char*>rgba_buf)[:w * h * 4]
        free(rgba_buf)
        surf = pygame.image.frombuffer(py_bytes, (w, h), "RGBA").convert_alpha()

        # The embedded strike's own pixel height rarely matches the
        # requested `size` exactly (CBDT has no vector scaling). Only
        # resize when the mismatch is large enough to matter — smoothscale
        # (bilinear) measurably softens sharp cartoon-style edges even for
        # SMALL scale factors (confirmed via direct sharpness measurement:
        # a mere ~6% resize cut edge contrast by ~97%), so for a
        # well-populated multi-strike font (close strikes only a few
        # pixels apart, e.g. Apple Color Emoji's 12 strikes) skipping the
        # unnecessary resize keeps CBDT output visibly crisp instead of
        # blurring away exactly the quality multiple strikes are meant to
        # preserve. Only scale when actually needed (sparse-strike fonts,
        # or a size genuinely outside the embedded range).
        if h > 0 and abs(h - size) > <int>(size * 0.15):
            scale = <double>size / <double>h
            surf = pygame.transform.smoothscale(surf, (max(1, <int>(w * scale)), max(1, <int>(h * scale))))
            top = <int>(top * scale)
            left = <int>(left * scale)

        return surf, top, left

    cdef tuple _render_cbdt_by_id(self, unsigned int glyph_id, int size):
        """Same as _render_cbdt_emoji but takes an ALREADY-RESOLVED glyph
        ID directly (e.g. from HarfBuzz shaping) — see _render_colrv1_by_id
        for why this exists."""
        cdef unsigned char* rgba_buf = NULL
        cdef int w = 0, h = 0, top = 0, left = 0
        cdef int result
        cdef bytes py_bytes
        cdef object surf
        cdef double scale

        if not self._emoji_has_cbdt or self._emoji_ft_face == NULL or glyph_id == 0:
            return None, 0, 0

        result = render_cbdt_glyph(self._emoji_ft_face, glyph_id, size, &rgba_buf, &w, &h, &top, &left)
        if result != 0 or rgba_buf == NULL or w <= 0 or h <= 0:
            if result == 1 or result == 5:
                self._emoji_has_cbdt = False
            return None, 0, 0

        py_bytes = (<char*>rgba_buf)[:w * h * 4]
        free(rgba_buf)
        surf = pygame.image.frombuffer(py_bytes, (w, h), "RGBA").convert_alpha()

        # See _render_cbdt_emoji for why this only scales past a 15%
        # mismatch threshold instead of on every non-exact match.
        if h > 0 and abs(h - size) > <int>(size * 0.15):
            scale = <double>size / <double>h
            surf = pygame.transform.smoothscale(surf, (max(1, <int>(w * scale)), max(1, <int>(h * scale))))
            top = <int>(top * scale)
            left = <int>(left * scale)

        return surf, top, left
        
        
    cdef FT_Face _get_shared_ft_face(self, str real_path, int index) except NULL:
        """Master FT_Face Pool — loads font file from disk ONCE and caches the FT_Face pointer in memory.
        Completely eliminates multi-millisecond disk I/O latency spikes during render."""
        cdef tuple key = (real_path, max(0, index))
        cdef object cached_val = self._glyph_check_faces.c_get(key)
        cdef FT_Face face_ptr
        cdef bytes path_bytes
        cdef int err

        if cached_val is not None:
            if <size_t>cached_val == 0:
                return NULL
            return <FT_Face><void*><size_t>cached_val

        try:
            path_bytes = real_path.encode("utf-8")
            err = FT_New_Face(_ensure_ft_library(), path_bytes, max(0, index), &face_ptr)
            if err != 0:
                self._glyph_check_faces.c_set(key, 0)
                return NULL
            self._glyph_check_faces.c_set(key, <size_t>face_ptr)
            return face_ptr
        except Exception:
            self._glyph_check_faces.c_set(key, 0)
            return NULL


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

    cdef bint _has_glyph(self, object path_data, int code):
        if not path_data: return False
        
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

    cdef object _find_best_font_path_code(self, int code, str face):
        """Direct integer codepoint cascade search with immediate O(1) cache check at line 1.
        Prevents millions of heap tuple allocations per minute."""
        cdef tuple cache_key = (code, face)
        cdef object _cached_path = self._path_cache.c_get(cache_key)
        if _cached_path is not None:
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
                
        self._path_cache.c_set(cache_key, path)
        return path

    cdef object _find_best_font_path(self, str ch, str face):
        """Cascade Search: Finds the best font file that contains the requested glyph."""
        return self._find_best_font_path_code(ord(ch), face)

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
        cdef str real_path
        cdef int index = 0
        
        if isinstance(path_data, (list, tuple)):
            real_path = path_data[0]
            index = path_data[1]
        else:
            real_path = path_data

        # Use the tuple (path, index) as the key for the HarfBuzz cache.
        cdef tuple hb_cache_key = (real_path, index)
        cdef object _cached_hb = self._hb_fonts.c_get(hb_cache_key)

        if _cached_hb is None:
            try:
                with open(real_path, 'rb') as f:
                    font_data = f.read()
                
                # HarfBuzz Face supports the index parameter to select fonts from a .ttc collection.
                face = hb.Face(font_data, max(0, index))
                hb_font = hb.Font(face)
                
                # Save the entire set so that font_data is not freed from memory (avoid segfault errors)
                _cached_hb = (hb_font, font_data)
                self._hb_fonts.c_set(hb_cache_key, _cached_hb)
                
            except Exception as e:
                print(f"Error loading HarfBuzz font at {real_path}, (index {index}): {e}")
                return None
                
        return _cached_hb[0]

    cdef object _render_emoji_run(self, str text, int size, double f_asc, int final_h, bint apply_italic=False):
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
        cdef object hb_font, buf
        cdef double scale, x_adv, x_off, y_off, fcur_x
        cdef bint all_ok
        cdef unsigned int glyph_id
        cdef int left_off
        cdef list glyph_surfs = []
        cdef Py_ssize_t n_glyphs, gi
        cdef list g_infos, g_positions
        cdef object info_obj, pos_obj

        # Stack buffer for glyph geometry (replaces 3 separate Python lists)
        cdef EmojiGlyphPos pos_stack[64]
        cdef EmojiGlyphPos* g_pos = pos_stack
        cdef bint heap_pos = False
        cdef int valid_glyphs = 0

        baseline_y = <int>(f_asc + 0.5)

        # Ensure the emoji FT_Face is loaded (guarded init lives inside
        # _render_colrv1_emoji — a throwaway call on the first char
        # triggers it if this is the very first emoji touched this run).
        if not self._emoji_colr_checked:
            self._render_colrv1_emoji(text[0], size)

        hb_font = self._get_hb_font(self.emoji_path)
        all_ok = False
        fcur_x = 0.0

        if hb_font is not None:
            buf = hb.Buffer()
            buf.add_str(text)
            buf.guess_segment_properties()
            hb.shape(hb_font, buf)
            scale = size / <double>hb_font.face.upem

            g_infos = buf.glyph_infos
            g_positions = buf.glyph_positions
            n_glyphs = len(g_infos)

            if n_glyphs > 64:
                g_pos = <EmojiGlyphPos*>malloc(n_glyphs * sizeof(EmojiGlyphPos))
                if g_pos == NULL: raise MemoryError()
                heap_pos = True

            all_ok = True
            for gi in range(n_glyphs):
                info_obj = g_infos[gi]
                pos_obj = g_positions[gi]
                glyph_id = info_obj.codepoint
                x_adv = pos_obj.x_advance * scale
                x_off = pos_obj.x_offset * scale
                y_off = pos_obj.y_offset * scale

                surf_raw, top_off, left_off = self._render_colrv1_by_id(glyph_id, size, apply_italic)
                if surf_raw is None:
                    surf_raw, top_off, left_off = self._render_colrv0_by_id(glyph_id, size, apply_italic)
                if surf_raw is None:
                    surf_raw, top_off, left_off = self._render_cbdt_by_id(glyph_id, size)

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

    cdef object _render_shaped_run(self, str text, int size, tuple color, object font_path, str face, bint aa_toggle=False):
        """
        Performance-optimized version:
        - Uses a static color mapping table for 256 Alpha values ​​to avoid calling `surf.map_rgb` in the pixel loop.
        - Casts PixelArray to Cython 2D Typed Memoryview to perform direct pixel overwrite operations at the C level.
        - Uses a contiguous C Memory Arena buffer for raw glyph bitmaps to avoid Python bytes allocation overhead.
        - Shares Master FT_Face instances across all sizes (FT_Set_Pixel_Sizes) to eliminate disk I/O spikes.
        """
        cdef object hb_font, buf, surf, px_array
        cdef FT_Face face_obj
        cdef int _bmp_size
        cdef double f_asc, f_h, scale, cur_x, min_x, max_x, glyph_x, glyph_right, logical_x1, logical_x2, start_x, base_x
        cdef int baseline_y, final_h, final_w, dy
        cdef int glyph_id, px, py, bmp_x, bmp_y, alpha_val, r, g, b
        cdef int w_bmp, h_bmp, pitch, abs_pitch, p_idx
        cdef double x_adv, x_off, y_off, draw_x, draw_y
        cdef str real_path
        cdef FontMetricData metrics
        # --- Glyph metadata buffer: stack for <=256 glyphs, heap for longer runs ---
        cdef GlyphMeta meta_stack[256]
        cdef GlyphMeta* g_meta
        cdef bint _heap_alloc = False
        cdef Py_ssize_t n_glyphs, gi
        cdef int index = 0, space_w = 0, logic_w = 0
        cdef double total_adv = 0.0

        # Declaring variables for optimization using C native
        cdef unsigned int mapped_colors[256]
        cdef int a
        cdef unsigned int[:, :] px_view

        # C Memory Arena for raw bitmap buffers (eliminates Python bytes allocations in hot path)
        cdef unsigned char arena_stack[8192]
        cdef unsigned char* arena_buf = arena_stack
        cdef size_t arena_cap = 8192
        cdef size_t arena_used = 0
        cdef bint _heap_arena = False
        cdef unsigned char* bmp_ptr

        metrics = self._get_metrics(size, face)
        f_asc = metrics.asc
        f_h   = metrics.height
        baseline_y = <int>(f_asc + 0.5)
        final_h = <int>(f_h * 1.5)

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
            return self._render_emoji_run(text, size, f_asc, final_h, _syn_italic)

        if isinstance(font_path, (list, tuple)):
            real_path = font_path[0]
            index = font_path[1]
            if index < 0: index = 0
        else:
            real_path = font_path

        hb_font = self._get_hb_font(font_path)
        if hb_font is None:
            return pygame.Surface((1, final_h), pygame.SRCALPHA), 1

        buf = hb.Buffer()
        buf.add_str(text)
        buf.guess_segment_properties()
        hb.shape(hb_font, buf)
        scale = size / <double>hb_font.face.upem

        cdef list g_infos = buf.glyph_infos
        cdef list g_positions = buf.glyph_positions
        n_glyphs = len(g_infos)

        if n_glyphs > 256:
            g_meta = <GlyphMeta*>malloc(n_glyphs * sizeof(GlyphMeta))
            if g_meta == NULL: raise MemoryError()
            _heap_alloc = True
        else:
            g_meta = meta_stack

        face_obj = self._get_shared_ft_face(real_path, index)
        if face_obj == NULL:
            if _heap_alloc: free(g_meta)
            return pygame.Surface((1, final_h), pygame.SRCALPHA), 1

        FT_Set_Pixel_Sizes(face_obj, 0, size)

        cdef FT_GlyphSlot _slot_ptr
        cdef bint _aa = (not self._anti_alias) if aa_toggle else self._anti_alias

        cur_x = 0.0
        min_x = 999999.0
        max_x = -999999.0

        cdef object info_obj, pos_obj
        for gi in range(n_glyphs):
            info_obj = g_infos[gi]
            pos_obj = g_positions[gi]
            glyph_id = info_obj.codepoint
            x_adv = pos_obj.x_advance * scale
            x_off = pos_obj.x_offset * scale
            y_off = pos_obj.y_offset * scale
            total_adv += x_adv
            base_x = cur_x
            cur_x += x_adv

            if _syn_bold or _syn_italic:
                FT_Load_Glyph(face_obj, glyph_id, _FT_LOAD_NO_HINTING)
                _slot_ptr = face_obj.glyph
                if _syn_bold:   FT_GlyphSlot_Embolden(_slot_ptr)
                if _syn_italic: FT_GlyphSlot_Oblique(_slot_ptr)
                FT_Render_Glyph(face_obj.glyph, 0 if _aa else 2)
            else:
                FT_Load_Glyph(face_obj, glyph_id, _FT_LOAD_AA if _aa else _FT_LOAD_MONO)

            w_bmp = face_obj.glyph.bitmap.width
            h_bmp = face_obj.glyph.bitmap.rows
            pitch = face_obj.glyph.bitmap.pitch
            left = face_obj.glyph.bitmap_left
            top = face_obj.glyph.bitmap_top

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
            g_meta[gi].h_bmp = h_bmp
            g_meta[gi].pitch = pitch
            g_meta[gi].left  = left
            g_meta[gi].top   = top
            g_meta[gi].x     = base_x + x_off
            g_meta[gi].y_off = y_off

            if w_bmp > 0:
                _bmp_size = (pitch if pitch >= 0 else -pitch) * h_bmp
                if arena_used + _bmp_size > arena_cap:
                    arena_cap = (arena_used + _bmp_size) * 2
                    if not _heap_arena:
                        arena_buf = <unsigned char*>malloc(arena_cap)
                        memcpy(arena_buf, arena_stack, arena_used)
                        _heap_arena = True
                    else:
                        arena_buf = <unsigned char*>realloc(arena_buf, arena_cap)
                memcpy(arena_buf + arena_used, face_obj.glyph.bitmap.buffer, _bmp_size)
                g_meta[gi].buf_off = arena_used
                arena_used += _bmp_size
            else:
                g_meta[gi].buf_off = 0

        if min_x > max_x:
            if _heap_alloc: free(g_meta)
            if _heap_arena: free(arena_buf)
            space_w = max(1, <int>(total_adv + 0.5))
            return pygame.Surface((space_w, final_h), pygame.SRCALPHA), space_w

        start_x = -min_x if min_x < 0 else 0.0
        logic_w = <int>(total_adv + 0.5)
        final_w = max(1, <int>(max_x + start_x + 1.0))

        if logic_w > final_w:
            final_w = logic_w

        # Native hardware-aligned Pygame SRCALPHA surface
        surf = pygame.Surface((final_w, final_h), pygame.SRCALPHA)
        r = color[0]; g = color[1]; b = color[2]
        
        cdef unsigned int base_rgb = (<unsigned int>r << 16) | (<unsigned int>g << 8) | (<unsigned int>b)
        for a in range(256):
            mapped_colors[a] = (<unsigned int>a << 24) | base_rgb

        px_array = pygame.PixelArray(surf)
        px_view = px_array

        for gi in range(n_glyphs):
            w_bmp = g_meta[gi].w_bmp
            if w_bmp <= 0: continue

            h_bmp = g_meta[gi].h_bmp
            pitch = g_meta[gi].pitch
            abs_pitch = pitch if pitch > 0 else -pitch
            bmp_ptr = arena_buf + g_meta[gi].buf_off

            draw_x = g_meta[gi].x + g_meta[gi].left + start_x
            draw_y = baseline_y - g_meta[gi].top - g_meta[gi].y_off

            if _aa:
                for bmp_y in range(h_bmp):
                    for bmp_x in range(w_bmp):
                        p_idx = bmp_y * pitch + bmp_x if pitch > 0 else (h_bmp - 1 - bmp_y) * abs_pitch + bmp_x
                        alpha_val = bmp_ptr[p_idx]
                        if alpha_val > 0:
                            px = <int>(draw_x + bmp_x + 0.5)
                            py = <int>(draw_y + bmp_y + 0.5)
                            if 0 <= px < final_w and 0 <= py < final_h:
                                px_view[px, py] = mapped_colors[alpha_val]
            else:
                for bmp_y in range(h_bmp):
                    for bmp_x in range(w_bmp):
                        p_idx = bmp_y * pitch + bmp_x // 8 if pitch > 0 else (h_bmp - 1 - bmp_y) * abs_pitch + bmp_x // 8
                        alpha_val = 255 if (bmp_ptr[p_idx] >> (7 - (bmp_x & 7))) & 1 else 0
                        if alpha_val > 0:
                            px = <int>(draw_x + bmp_x + 0.5)
                            py = <int>(draw_y + bmp_y + 0.5)
                            if 0 <= px < final_w and 0 <= py < final_h:
                                px_view[px, py] = mapped_colors[alpha_val]

        px_array.close()
        if _heap_alloc: free(g_meta)
        if _heap_arena: free(arena_buf)
        return surf, logic_w


    cdef list _parse_render_accumulate(self, str text, tuple color, str face, object current_p_path, object current_f_path):
        """The parser loop — delegated to C parser (c_parser.c) for maximum speed.
        Extracts tags, classifies scripts, performs BiDi reordering, and groups text runs."""
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

        cdef int max_runs = 128
        cdef int calc_runs = n // 2 + 8
        if calc_runs > max_runs:
            max_runs = calc_runs
            runs_buf = <CP_Run*>malloc(max_runs * sizeof(CP_Run))
            heap_runs = True

        cdef int idx
        for idx in range(n):
            in_codes[idx] = <unsigned int>ord(text[idx])

        cdef CP_Color def_col
        def_col.r = <unsigned char>color[0]
        def_col.g = <unsigned char>color[1]
        def_col.b = <unsigned char>color[2]

        cdef bytes face_bytes = face.encode('utf-8')
        cdef const char* face_cstr = face_bytes
        cdef int clean_len = 0

        cdef int num_runs = cp_parse_text(
            in_codes, n, def_col, face_cstr, palette_table,
            clean_codes, &clean_len, runs_buf, max_runs
        )

        cdef list result_runs = []
        cdef int ri, run_start, run_len, ki, sub_start, sub_len
        cdef str r_face_str, run_text, ch
        cdef tuple r_color_tup
        cdef object cur_font_path, last_font_path
        cdef bint aa_toggle_flag
        cdef int s_group

        try:
            for ri in range(num_runs):
                run_start = runs_buf[ri].start
                run_len = runs_buf[ri].length
                if run_len <= 0: continue

                r_color_tup = (runs_buf[ri].color.r, runs_buf[ri].color.g, runs_buf[ri].color.b)
                r_face_str = runs_buf[ri].face.decode('utf-8')
                if not r_face_str: r_face_str = face

                s_group = runs_buf[ri].script_group
                aa_toggle_flag = <bint>(runs_buf[ri].aa_toggle != 0)

                # For whitespace, point directly to the fallback font.
                # Uses PyUnicode_FromKindAndData C-API to instantiate Python string in 1 single C call.
                if s_group == 0:
                    run_text = PyUnicode_FromKindAndData(PyUnicode_4BYTE_KIND, &clean_codes[run_start], run_len)
                    cur_font_path = self._get_true_path(self.fallback_name, r_face_str)
                    result_runs.append((run_text, cur_font_path, r_color_tup, s_group, r_face_str, aa_toggle_flag))
                    continue

                # Split by fallback font if CJK characters or Emojis requiring a font change are present within the same run.
                last_font_path = None
                sub_start = run_start
                sub_len = 0

                for ki in range(run_len):
                    ch = chr(clean_codes[run_start + ki])
                    cur_font_path = self._find_best_font_path(ch, r_face_str)

                    if last_font_path is not None and cur_font_path != last_font_path:
                        if sub_len > 0:
                            run_text = PyUnicode_FromKindAndData(PyUnicode_4BYTE_KIND, &clean_codes[sub_start], sub_len)
                            result_runs.append((run_text, last_font_path, r_color_tup, s_group, r_face_str, aa_toggle_flag))
                        sub_start = run_start + ki
                        sub_len = 1
                    else:
                        sub_len += 1
                    last_font_path = cur_font_path

                if sub_len > 0:
                    run_text = PyUnicode_FromKindAndData(PyUnicode_4BYTE_KIND, &clean_codes[sub_start], sub_len)
                    result_runs.append((run_text, last_font_path, r_color_tup, s_group, r_face_str, aa_toggle_flag))

        finally:
            if heap_in: free(in_codes)
            if heap_clean: free(clean_codes)
            if heap_runs: free(runs_buf)

        return result_runs

    cpdef render_outline(self, str text, int size, tuple color=(255, 255, 255),
                          tuple outline_color=(0, 0, 0), int outline_width=1,
                          bint dynamic=False, str face=""):
        """Like render() but with an outline — COMPLETELY SEPARATE from
        the original render() so it costs zero extra overhead on the
        cache-hit path of render() when outline isn't used."""
        cdef object base_surf = self.render(text, size, color, dynamic, face)
        if outline_width <= 0 or outline_color is None:
            return base_surf
        return self._apply_outline(base_surf, outline_color, outline_width)

    cdef object _apply_outline(self, object surf, tuple outline_color, int width):
        """Draws an outline around text using a silhouette (pygame.mask)
        blitted at multiple offsets — pure pygame post-processing, doesn't touch FreeType/HarfBuzz."""
        cdef object mask, outline_shape, canvas
        cdef int w, h, dx, dy

        mask = pygame.mask.from_surface(surf)
        outline_shape = mask.to_surface(
            setcolor=(outline_color[0], outline_color[1], outline_color[2], 255),
            unsetcolor=(0, 0, 0, 0)
        )

        w = surf.get_width()  + width * 2
        h = surf.get_height() + width * 2
        canvas = pygame.Surface((w, h), pygame.SRCALPHA)

        for dx in range(-width, width + 1):
            for dy in range(-width, width + 1):
                if dx == 0 and dy == 0:
                    continue
                canvas.blit(outline_shape, (width + dx, width + dy))

        canvas.blit(surf, (width, width))
        return canvas

    cpdef render(self, str text, int size, tuple color=(255, 255, 255), bint dynamic=False, str face=""):
        """This function has been improved to allow you to call the original pygame syntax, but will
        use the syntax from pygame.freetype!
        Example:
        font = font.render("Here is sample text", size = 20, color = (255, 255, 255), face="regular")
        screen.blit(font, (100, 200))"""
        if not face:
            face = self.init_face
        else:
            face = face.lower()

        # CYTHON OPTIMIZATION: Strict C89 declarations for maximum speed and MSVC compliance.
        # === ALL cdef HERE — before the early-return, to avoid C89 errors ===
        cdef tuple cache_key = (text, size, color, face)
        cdef object _cached, _gc_val
        cdef bint is_pure_ascii = True
        cdef str _ch
        cdef tuple glyph_key
        cdef int std_h, total_logic_w, cur_x, w_adv, fixed_h, actual_final_w
        cdef Py_ssize_t idx, last_idx, n_surfs, t_len = len(text)
        cdef FontMetricData _std_m
        cdef object final_surf, s
        cdef object current_p_path, current_f_path
        cdef list runs = [], surfs = [], logic_widths = []

        # Buffer for ASCII Fast Path (caches surface references to avoid 2nd LRU lookup & tuple alloc)
        cdef list ascii_surfs = []
        cdef int ascii_advs_stack[256]
        cdef int* ascii_advs = ascii_advs_stack
        cdef bint heap_ascii = False

        # =========================================================================
        # THE EARLY EXIT: O(1) Static Text Cache Lookup — uses c_get (single dict lookup)
        # =========================================================================
        if not dynamic:
            _cached = self._text_cache.c_get(cache_key)
            if _cached is not None:
                return _cached

        self._ensure_init()
        
        # O(1) Base Path Resolution
        current_p_path = self._get_true_path(self.primary_name, face)
        current_f_path = self._get_true_path(self.fallback_name, face)

        # -----------------------------------------------------------
        # FAST PATH: Dynamic ASCII bypass
        # Routes formatted syntax (< or }) to the Full Pipeline automatically
        # -----------------------------------------------------------
        if dynamic and t_len > 0:
            for idx in range(t_len):
                _ch = text[idx]
                if ord(_ch) > 127 or _ch == '^' or _ch == '<' or _ch == '}': 
                    is_pure_ascii = False
                    break
            
            if is_pure_ascii:
                if t_len > 256:
                    ascii_advs = <int*>malloc(t_len * sizeof(int))
                    heap_ascii = True

                # try/finally: _render_shaped_run below can raise (missing
                # font file, decode error, etc.) — without this, an
                # exception mid-loop would skip the free(ascii_advs) at
                # the end entirely, leaking the heap buffer on every such
                # error. Mirrors the same protection _parse_render_accumulate
                # already has for its own heap buffers.
                try:
                    actual_final_w = 0
                    for idx in range(t_len):
                        _ch = text[idx]
                        glyph_key = (_ch, size, color, face)
                        _gc_val = self._glyph_cache.c_get(glyph_key)
                        if _gc_val is None:
                            _gc_val = self._render_shaped_run(_ch, size, color, current_p_path, face)
                            self._glyph_cache.c_set(glyph_key, _gc_val)

                        s = _gc_val[0]
                        w_adv = <int>_gc_val[1]
                        ascii_surfs.append(s)
                        ascii_advs[idx] = w_adv
                        actual_final_w += w_adv

                    _std_m = self._get_metrics(size, face)
                    std_h = <int>_std_m.height
                    fixed_h = <int>(std_h * 1.5)
                    if actual_final_w <= 0: actual_final_w = 1

                    final_surf = pygame.Surface((actual_final_w, fixed_h), pygame.SRCALPHA)
                    cur_x = 0
                    for idx in range(t_len):
                        final_surf.blit(ascii_surfs[idx], (cur_x, 0))
                        cur_x += ascii_advs[idx]
                finally:
                    if heap_ascii:
                        free(ascii_advs)

                # Eviction now happens automatically in _LRUCache.__setitem__
                return final_surf

        # -----------------------------------------------------------
        # FULL PIPELINE: Multi-language, Bidi, Inline Face & Color parsing
        # (BiDi reordering & token lexing fully handled at C-level in c_parser.c)
        # -----------------------------------------------------------
        _std_m = self._get_metrics(size, face)
        std_h = <int>_std_m.height

        runs = self._parse_render_accumulate(text, color, face, current_p_path, current_f_path)

        # ==========================================================
        # UNIVERSAL RENDERING & BLITTING
        # ==========================================================
        total_logic_w = 0
        for r_text, r_path, r_color, _, r_face, r_aa_toggle in runs:
            if r_text:
                # Use r_face (the run's active_face) instead of the default face
                s, w_adv = self._render_shaped_run(r_text, size, r_color, r_path, r_face, r_aa_toggle)
            else: 
                continue
            
            surfs.append(s)
            logic_widths.append(w_adv)
            total_logic_w += w_adv

        n_surfs = len(surfs)
        if n_surfs == 1:
            final_surf = surfs[0]
        elif n_surfs == 0:
            final_surf = pygame.Surface((1, <int>(std_h * 1.5)), pygame.SRCALPHA)
        else:
            if total_logic_w <= 0: total_logic_w = 1
            # MUST match _render_shaped_run's own final_h formula exactly
            # (both now just <int>(f_h*1.5)/<int>(std_h*1.5), plain and
            # unconditional — the margin mechanism was removed entirely,
            # see _render_shaped_run's comment for why).
            fixed_h = <int>(std_h * 1.5)
            actual_final_w = 0
            
            # Subpixel bleeding prevention
            if logic_widths:
                last_idx = len(logic_widths) - 1
                actual_final_w = (total_logic_w - <int>logic_widths[last_idx]) + <int>surfs[last_idx].get_width()
            else:
                actual_final_w = total_logic_w

            final_surf = pygame.Surface((actual_final_w, fixed_h), pygame.SRCALPHA)
            cur_x = 0
            for idx in range(n_surfs):
                final_surf.blit(surfs[idx], (cur_x, 0))
                cur_x += <int>logic_widths[idx]

        # Cache valid outputs
        if not dynamic:
            self._text_cache.c_set(cache_key, final_surf)

        # LRU Cache Eviction to prevent memory leaks
        # Eviction now happens automatically in _LRUCache.__setitem__ — no manual loop needed

        return final_surf

    cpdef get_debug_info(self, object text_input, str face=""):
        """
        Returns detailed per-character rendering metadata.
        Fields per character:
          char        : the original character
          hex         : Unicode codepoint (U+XXXX)
          category    : Unicode category (Lu, Ll, Lo, ...)
          script      : script group (Latin/CJK/Arabic/Hebrew/Indic/Thai/Tibetan/Khmer)
          font_file   : actual font file name
          font_source : PRIMARY / FALLBACK / EMOJI / MISSING
          ttc_index   : index within the TTC (-1 for regular TTF)
          has_glyph   : whether the glyph exists in the font
          synthetic   : NONE / BOLD / ITALIC / BOLD+ITALIC
          render_path : SHAPED / SIMPLE / CHAR (predicted from script)
          tag_context : the currently active face tag (if any inline tag)
          is_tag      : True if this char is part of an inline tag (skipped when rendering)
        """
        self._ensure_init()

        if not face:
            face = self.init_face
        else:
            face = face.lower()

        cdef str text = str(text_input)
        cdef int n = <int>len(text)
        if n == 0:
            return []

        cdef unsigned int stack_in[512]
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
        cdef CP_DebugToken* tokens_buf = stack_tokens
        cdef bint heap_in = False
        cdef bint heap_tok = False

        if n > 512:
            in_codes = <unsigned int*>malloc(n * sizeof(unsigned int))
            tokens_buf = <CP_DebugToken*>malloc(n * sizeof(CP_DebugToken))
            heap_in = True
            heap_tok = True

        cdef int idx
        for idx in range(n):
            in_codes[idx] = <unsigned int>ord(text[idx])

        cdef bytes face_bytes = face.encode('utf-8')
        cdef const char* face_cstr = face_bytes

        cdef int num_tokens = cp_parse_debug(
            in_codes, n, face_cstr, palette_table, tokens_buf, n
        )

        cdef dict script_label = {
            0: "Space", 1: "Hebrew", 2: "Arabic",
            3: "Indic", 4: "Thai", 5: "Tibetan",
            6: "Khmer", 7: "Latin/CJK"
        }
        cdef dict render_path_map = {
            0: "SIMPLE", 1: "SHAPED", 2: "SHAPED",
            3: "SHAPED", 4: "SHAPED", 5: "SHAPED",
            6: "SHAPED", 7: "SIMPLE"
        }

        cdef list info = []
        cdef int ti, code, ttc_index, s_group
        cdef str ch, active_f, fname, font_source, synthetic_str
        cdef object path, primary_p, fallback_p, emoji_p
        cdef tuple syn_flags
        cdef bint has_g

        try:
            for ti in range(num_tokens):
                active_f = tokens_buf[ti].active_face.decode('utf-8')
                if not active_f:
                    active_f = face

                if tokens_buf[ti].is_tag != 0:
                    info.append({
                        "char": " ", "hex": "TAG",
                        "category": "TAG", "script": "-",
                        "font": "-", "font_source": "TAG",
                        "ttc_index": -1, "has_glyph": False,
                        "synthetic": "NONE", "render_path": "-",
                        "tag_context": active_f, "is_tag": True,
                        "tag_type": tokens_buf[ti].tag_type.decode('utf-8')
                    })
                    continue

                code = <int>tokens_buf[ti].codepoint
                ch = chr(code)
                s_group = tokens_buf[ti].script_group
                path = self._find_best_font_path(ch, active_f)

                if path:
                    if isinstance(path, (list, tuple)):
                        fname = os.path.basename(str(path[0]))
                        ttc_index = int(path[1]) if len(path) > 1 else -1
                    else:
                        fname = os.path.basename(str(path))
                        ttc_index = -1

                    has_g = self._has_glyph(path, code)
                    primary_p = self._get_true_path(self.primary_name, active_f)
                    fallback_p = self._get_true_path(self.fallback_name, active_f)
                    emoji_p = getattr(self, 'emoji_path', None)

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
                    has_g = False
                    font_source = "MISSING"

                syn_flags = self._get_synthetic_flags(active_f)
                if self._is_synthetic_needed("", active_f, path):
                    if syn_flags[0] and syn_flags[1]:
                        synthetic_str = "BOLD+ITALIC"
                    elif syn_flags[0]:
                        synthetic_str = "BOLD"
                    elif syn_flags[1]:
                        synthetic_str = "ITALIC"
                    else:
                        synthetic_str = "NONE"
                else:
                    synthetic_str = "NONE"

                info.append({
                    "char": ch,
                    "hex": f"U+{code:04X}",
                    "category": unicodedata.category(ch),
                    "script": script_label.get(s_group, "Unknown"),
                    "font": fname,
                    "font_source": font_source,
                    "ttc_index": ttc_index,
                    "has_glyph": has_g,
                    "synthetic": synthetic_str,
                    "render_path": render_path_map.get(s_group, "SIMPLE"),
                    "tag_context": active_f,
                    "is_tag": False,
                    "tag_type": "-"
                })
        finally:
            if heap_in: free(in_codes)
            if heap_tok: free(tokens_buf)

        return info
      
# VARIABLE PROTECT CLASS
class _ProtectedEngine(types.ModuleType):
    
    # 1. OVERWRITING SELECTION (SET)
    def __setattr__(self, name, value):
        # Preventing the overwriting of internal system variables
        if name in PROTECTED_VARS:
            print(f"[WARNING]: The variable '{name}' is a protected local variable ( Read-Only ). Ignoring the action of overwriting its value...")
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
