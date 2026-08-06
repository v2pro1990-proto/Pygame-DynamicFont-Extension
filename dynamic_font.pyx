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
cimport cython
import emoji
from fontTools.ttLib import TTFont, TTCollection
import uharfbuzz as hb
import freetype
# FreeType load flags
_FT_LOAD_RENDER     = 0x4
_FT_LOAD_NO_HINTING = 0x2
_FT_LOAD_AA         = _FT_LOAD_RENDER | _FT_LOAD_NO_HINTING  # = 6, antialiased
_FT_LOAD_MONO       = _FT_LOAD_RENDER | 0x20000               # FT_LOAD_TARGET_MONO = (2<<16)
_FT_LOAD_COLOR      = 0x100000
_FT_LOAD_COLOR_RENDER = _FT_LOAD_COLOR | _FT_LOAD_RENDER
import unicodedata
from collections import OrderedDict

MODERN_FONT = True
SMOOTH_FONT = True   # Enable/Disable baseline alignment
ANTI_ALIAS = True
EMOJI_OFFSET_Y = 0.15
MAX_TEXT_CACHE = 1200
TEXT_CACHE_CLEAN_COUNT = 100
MAX_GLYPH_CACHE = 2500
GLYPH_CACHE_CLEAN_COUNT = 100

#======================================================================
"""This variable is an API that informs the main game program that it is scanning for fonts in the system.
It can read the value of this variable to display the loading screen, avoiding the
"Not Responding" error window which is aesthetically unpleasing!"""
# NOTE: THIS VARIABLE CAN ONLY BE READ FROM THE MAIN PROGRAM! IMPOSSIBLE TO OVERWRITE ITS VALUE TO AVOID SYSTEM ERRORS!!!
cdef bint _is_scanning = False
# This tuple is initialized for comparison in the protection mechanism.
# Load FreeType C-API cho synthetic embolden
import ctypes, ctypes.util, sys as _sys
_ft_lib = None
try:
    if _sys.platform == "win32":
        _ft_lib = ctypes.cdll.LoadLibrary("freetype.dll")
    else:
        _ft_name = ctypes.util.find_library("freetype")
        if _ft_name:
            _ft_lib = ctypes.cdll.LoadLibrary(_ft_name)
    if _ft_lib:
        # FT_GlyphSlot_Embolden(FT_GlyphSlot slot) → void
        _FT_GlyphSlot_Embolden = _ft_lib.FT_GlyphSlot_Embolden
        _FT_GlyphSlot_Embolden.restype  = None
        _FT_GlyphSlot_Embolden.argtypes = [ctypes.c_void_p]
        # FT_GlyphSlot_Oblique(FT_GlyphSlot slot) → void
        _FT_GlyphSlot_Oblique = _ft_lib.FT_GlyphSlot_Oblique
        _FT_GlyphSlot_Oblique.restype  = None
        _FT_GlyphSlot_Oblique.argtypes = [ctypes.c_void_p]
except Exception as _e:
    _ft_lib = None
    print(f"[DynamicFont] FreeType C-API unavailable: {_e}")

_SYNTHETIC_FACE_MAP = {
    "bold":        (True,  False),
    "italic":      (False, True),
    "oblique":     (False, True),
    "bold italic": (True,  True),
    "bold_italic": (True,  True),
    "bolditalic":  (True,  True),
    "italic bold": (True,  True),
}

cdef tuple PROTECTED_VARS = ("is_scanning", "_is_scanning", "_ft_lib", "_FT_GlyphSlot_Embolden", "_FT_GlyphSlot_Oblique", "_SYNTHETIC_FACE_MAP")
#======================================================================

RICH_PALETTE = {
    '0': (255, 255, 255), '1': (255, 50, 50),   '2': (50, 255, 50),
    '3': (80, 150, 255),  '4': (255, 255, 50),  '5': (255, 50, 255),
    '6': (50, 255, 255),  '7': (200, 200, 200), '8': (100, 100, 100),
    '9': (0, 0, 0), 'a': (102, 178, 255)
}

# =====================================================================
# DECLARING GLOBAL FONT_SUFFIXES TUPLE (Initialized only once when importing the library)
# =====================================================================
cdef tuple FONT_SUFFIXES = (
    " bold italic", " light italic", " semibold italic", " extrabold italic",
    " extralight italic", " medium italic", " black italic", " semilight italic",
    " italic", " bold", " regular", " light", " thin", " semibold",
    " extrabold", " extralight", " medium", " black", " semilight",
    "-bolditalic", "-lightitalic", "-semibolditalic", "-extrabolditalic",
    "-extralightitalic", "-mediumitalic", "-blackitalic", "-semilightitalic",
    "-italic", "-bold", "-regular", "-light", "-thin", "-semibold",
    "-extrabold", "-extralight", "-medium", "-black", "-semilight"
)

cdef dict EMOJI_DATA_REF = emoji.EMOJI_DATA
cdef dict _EMOJI_CACHE = {}

# Configuration metadata for type validation
cdef dict _CONFIG_VALIDATORS = {
    "MODERN_FONT": (bool, "a Boolean value (True/False)"),
    "SMOOTH_FONT": (bool, "a Boolean value (True/False)"),
    "ANTI_ALIAS": (bool, "a Boolean value (True/False)"),
    "EMOJI_OFFSET_Y": ((int, float), "a Float or Int value"),
    "MAX_TEXT_CACHE": (int, "a positive Integer value"),
    "TEXT_CACHE_CLEAN_COUNT": (int, "a positive Integer value"),
    "MAX_GLYPH_CACHE": (int, "a positive Integer value"),
    "GLYPH_CACHE_CLEAN_COUNT": (int, "a positive Integer value"),
}

pygame.freetype.init()


def is_scanning() -> bool:
    """Read-Only API: Returns the font scanning status of the Engine"""
    global _is_scanning
    return _is_scanning

def _parse_font_input(name):
    """Parse font input — can be:
      - Font name: "JetBrains Mono"      → (name, None)
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
                # TTC without index → auto-detect: use index 0 (first face)
                # If user wants a specific face, pass [path, index] directly
                return [name, 0], True
            return [name, -1], True
    return name, False

def get_family_root(font_name: str) -> str:
    name = font_name.strip()
    low_name = name.lower()
    
    # Use the global Tuple directly for super-fast speed
    for suffix in FONT_SUFFIXES:
        if low_name.endswith(suffix):
            return name[:-len(suffix)].strip()
            
    return name


def normalize_font_name(font_name: str, family_files: list) -> str:
    name = font_name.strip()
    low_name = name.lower()
    
    if len(family_files) == 1:
        # Global Tuple Reuse
        for suffix in FONT_SUFFIXES:
            if low_name.endswith(suffix):
                return name[:-len(suffix)].strip()
    else:
        # Declare tuple inline() instead of list[] for optimal performance.
        for suffix in (" regular", "-regular"):
            if low_name.endswith(suffix):
                return name[:-len(suffix)].strip()
                
    return name

def build_font_map():
    global _is_scanning
    _is_scanning = True # At this point, the variable is only used internally within the Extension.
    try:       
        # Cross-platform directory listing
        font_dirs = []
        if sys.platform == "win32":
            font_dirs = [
                r"C:/Windows/Fonts",
                os.path.expanduser(r"~/AppData/Local/Microsoft/Windows/Fonts")
            ]
        elif sys.platform == "linux":
            font_dirs = ["/usr/share/fonts", "/usr/local/share/fonts", os.path.expanduser("~/.local/share/fonts")]
        elif sys.platform == "darwin":
            font_dirs = ["/Library/Fonts", os.path.expanduser("~/Library/Fonts")]

        paths = {}
        names = {}
        family_dict = {}

        for d in font_dirs:
            if not os.path.exists(d): continue
            print(f"[DEBUG] Scanning...: {d}") 
            
            # Perform a recursive scan using os.walk to ensure Linux/macOS compatibility.
            for root, _, files in os.walk(d):
                for f in files:
                    if not f.lower().endswith((".ttf", ".otf", ".ttc")): continue
                    path = os.path.join(root, f)
                    
                    try:
                        if f.lower().endswith(".ttc"):
                            # Index reader
                            with TTCollection(path) as ttc:
                                for i, tt in enumerate(ttc.fonts):
                                    try:
                                        faces = [record.toUnicode().strip() for record in tt['name'].names if record.nameID == 4]
                                        if not faces: continue
                                        font_name = faces[0]
                                        family_root = get_family_root(font_name)
                                        
                                        # Save [original path, index]
                                        family_dict.setdefault(family_root, []).append((font_name, [path, i]))
                                    except: continue
                        else:
                            # Lazy Mode for TTF/OTF
                            with TTFont(path, fontNumber=-1, lazy=True) as tt:
                                faces = [record.toUnicode().strip() for record in tt['name'].names if record.nameID == 4]
                                if faces:
                                    font_name = faces[0]
                                    family_root = get_family_root(font_name)
                                    # Index -1 to indicate a single file
                                    family_dict.setdefault(family_root, []).append((font_name, [path, -1]))
                    except Exception:
                        continue 

        # Create map paths and names
        for family, items in family_dict.items():
            names_in_family = [n for n, _ in items]
            for font_name, path_data in items:
                # paths[font_name.lower()] will now return a List [path, index]
                paths[font_name.lower()] = path_data
                norm_name = normalize_font_name(font_name, names_in_family)
                if norm_name.lower() != font_name.lower():
                    names[norm_name.lower()] = font_name.lower()

        print(f"[SUCCESS] Scan Finished {len(paths)} Font faces!.")
        return {"paths": paths, "names": names}
    finally:
        _is_scanning = False

def get_fonts_timestamp():
    # Use the same dirs list as build_font_map for synchronization
    font_dirs = []
    if sys.platform == "win32":
        font_dirs = [r"C:/Windows/Fonts", os.path.expanduser(r"~/AppData/Local/Microsoft/Windows/Fonts")]
    elif sys.platform == "linux":
        font_dirs = ["/usr/share/fonts", "/usr/local/share/fonts", os.path.expanduser("~/.local/share/fonts")]
    elif sys.platform == "darwin":
        font_dirs = ["/Library/Fonts", os.path.expanduser("~/Library/Fonts")]

    fingerprint = []
    for d in font_dirs:
        if os.path.exists(d):
            dir_mtime = os.path.getmtime(d)
            # Count all font files (including those in subfolders)
            f_count = 0
            for root, _, files in os.walk(d):
                f_count += sum(1 for f in files if f.lower().endswith((".ttf", ".otf", ".ttc")))
            fingerprint.append(f"{dir_mtime}_{f_count}")
    return "|".join(fingerprint)

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

cdef inline bint is_emoji(str ch):
    # Quick check cache (O(1))
    if ch in _EMOJI_CACHE:
        return <bint>_EMOJI_CACHE[ch]

    cdef int code = ord(ch)
    cdef bint res = False

    # 1. BLOCK: Alphanumerics (Ⓐ-ⓩ)
    if 0x24B6 <= code <= 0x24EA:
        res = False
    #2. SPECIAL AMNESTY: Sun, Deck of Cards, Retro Smiley Face
    elif (0x2600 <= code <= 0x2604) or \
         (0x2660 <= code <= 0x2667) or \
         (0x2639 <= code <= 0x263B):
        res = True
    # 3. BLOCK: Chess piece
    elif 0x2654 <= code <= 0x265F:
        res = False
    #4. ACCEPT: Emoji data
    else:
        res = (ch in emoji.EMOJI_DATA or code == 0x200D or code == 0xFE0F)

    # Save for later
    _EMOJI_CACHE[ch] = res
    return res

# Classify group Function
cdef inline int _classify_script(int code) noexcept:
    """Classify language groups using inline functions at C-level."""
    if 0x0590 <= code <= 0x05FF:
        return 1  # Hebrew
    if 0x0600 <= code <= 0x08FF or 0xFB50 <= code <= 0xFDFF or 0xFE70 <= code <= 0xFEFF:
        return 2  # Arabic
    if 0x0900 <= code <= 0x0DFF:
        return 3  # Indic
    if 0x0E00 <= code <= 0x0EFF:
        return 4  # Thai
    if 0x0F00 <= code <= 0x109F:
        return 5  # Tibetan
    if 0x1780 <= code <= 0x17FF:
        return 6  # Khmer
    if code == 0x20 or code == 0x00A0:
        return 0  # Space
    return 7  # Latin/CJK/Other


cpdef get_engine_version():
        cdef unsigned char hex_bytes[15]
        hex_bytes[0] = 0x76
        hex_bytes[1] = 0x31
        hex_bytes[2] = 0x2e
        hex_bytes[3] = 0x32
        hex_bytes[4] = 0x2e
        hex_bytes[5] = 0x32
        hex_bytes[6] = 0x2e
        hex_bytes[7] = 0x35
        hex_bytes[8] = 0x2d
        hex_bytes[9] = 0x70
        hex_bytes[10] = 0x61
        hex_bytes[11] = 0x74
        hex_bytes[12] = 0x63
        hex_bytes[13] = 0x68
        hex_bytes[14] = 0x00
        cdef str version = bytes(hex_bytes).decode('utf-8')
        return version

#PATCH v1.2 : Multiple Faces each Suface
cdef class DynamicFont:
    """(primary_name, fallback_name, fallback_dir, emoji_path, init_face)
    Intalize DynamicFont Object to Render -> Compas"""
    cdef str primary_name, fallback_name, fallback_dir, emoji_path
    cdef object _primary_path   # [path, index] if primary is a bundled file
    cdef object _fallback_path  # [path, index] if fallback is a bundled file
    cdef bint _anti_alias       # set at init, does not change at runtime
    cdef dict _font_objs, _hb_fonts, _path_cache, _cmap_cache, _pg_font_cache
    cdef dict _std_metrics, _font_map, _path_resolve_cache
    cdef list _intl_font_paths
    cdef public dict _glyph_cache, _text_cache, emoji_fallback_engine
    cdef bint _initialized
    cdef object _cached_p_path
    cdef object _cached_f_path_std
    cdef public str init_face

    def __init__(self, 
                 primary_name="Arial", 
                 fallback_name="Times New Roman", 
                 fallback_dir="assets/fonts/fallback", 
                 emoji_path="assets/fonts/NotoEmoji-Regular.ttf",
                 init_face="regular"):
        # 1. INPUT SANITIZATION
        # Detect if primary/fallback is a bundled file path → don't strip the name
        cdef object _p_parsed, _f_parsed
        cdef bint _p_is_path, _f_is_path
        _p_parsed, _p_is_path = _parse_font_input(primary_name)
        _f_parsed, _f_is_path = _parse_font_input(fallback_name)

        if _p_is_path:
            # primary_name is a file path → store directly, skip get_family_root
            self.primary_name   = _p_parsed[0]  # path string for identification
            self._primary_path  = _p_parsed      # [path, index] to load
        else:
            self.primary_name   = get_family_root(primary_name)
            self._primary_path  = None

        if _f_is_path:
            self.fallback_name  = _f_parsed[0]
            self._fallback_path = _f_parsed
        else:
            self.fallback_name  = get_family_root(fallback_name)
            self._fallback_path = None

        self.fallback_dir  = fallback_dir
        self.emoji_path    = emoji_path
        self._anti_alias   = True  # snapshot from ANTI_ALIAS at _ensure_init
        
        # 2. FACE EXTRACTION: Safely extract the font face if it was accidentally 
        # included in the primary_name parameter.
        cdef str p_lower = primary_name.lower().strip()
        cdef str extracted_face = "regular"
        for suffix in FONT_SUFFIXES:
            if p_lower.endswith(suffix):
                # Remove the leading hyphen or space (e.g., "-bold" -> "bold")
                extracted_face = suffix.strip("-").strip()
                break
                
        # Prioritize explicitly passed init_face, otherwise use the extracted one
        if init_face != "regular":
            self.init_face = init_face.lower()
        else:
            self.init_face = extracted_face

        # Core Engine States & Memory Caches
        self._font_objs = {}
        self._hb_fonts = {}
        self._path_cache = {}
        self._pg_font_cache = {}
        self._cmap_cache = {}
        self._std_metrics = {}
        self._glyph_cache = {}
        self._text_cache = {}
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
        # If fallback is a bundled path → skip system check
        if self._fallback_path is None:
            check_f_path = self._get_true_path(self.fallback_name, self.init_face)
            if check_f_path:
                if isinstance(check_f_path, (list, tuple)):
                    check_p = <str>check_f_path[0]
                else:
                    check_p = <str>check_f_path
                if not os.path.exists(check_p):
                    self.fallback_name = ""


        # Load international fallback fonts (Layer 3)
        if os.path.exists(self.fallback_dir):
            self._intl_font_paths = [os.path.join(self.fallback_dir, f) 
                                     for f in os.listdir(self.fallback_dir) 
                                     if f.lower().endswith((".ttf", ".otf", ".ttc"))]
        # Snapshot ANTI_ALIAS once — don't read the global on every render
        self._anti_alias = <bint>ANTI_ALIAS
        self._initialized = True

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
        """True = no real font file → synthetic needed.
        Logic: nếu _get_true_path(name, face) == _get_true_path(name, regular)
               → no real face found → synthetic needed.
        actual_path: the path currently being rendered, used to find the matching font_name.
        """
        cdef object path_with_face, path_regular
        cdef str font_name
        if not face:
            return False
        if face.lower() not in _SYNTHETIC_FACE_MAP:
            return False
        # Determine font_name from actual_path if available
        if actual_path is not None:
            # Compare: real face's path vs regular's path
            # If equal → no real face → synthetic needed
            # Use primary_name and fallback_name to check
            path_with_face = self._get_true_path(self.primary_name, face)
            path_regular   = self._get_true_path(self.primary_name, self.init_face)
            if path_with_face != path_regular:
                # Primary has a real face
                # Check whether actual_path is primary
                if actual_path == path_with_face or actual_path == path_regular:
                    return False  # Using primary → not synthetic
            path_with_face = self._get_true_path(self.fallback_name, face)
            path_regular   = self._get_true_path(self.fallback_name, self.init_face)
            if path_with_face != path_regular:
                # Fallback has a real face
                if actual_path == path_with_face or actual_path == path_regular:
                    return False  # Using fallback → not synthetic
            # actual_path doesn't belong to primary/fallback (intl font) → check separately
            # Intl fonts usually have only 1 face → always needs synthetic
            return True
        # No actual_path → check by name
        if not name:
            return False
        path_with_face = self._get_true_path(name, face)
        path_regular   = self._get_true_path(name, self.init_face)
        return path_with_face == path_regular

    cdef bint _has_glyph(self, object path_data, int code):
        if not path_data: return False
        
        #1. Separate paths and indexes from input data.
        cdef str real_path
        cdef int index = -1
        
        if isinstance(path_data, (list, tuple)):
            real_path = path_data[0]
            index = path_data[1]
        else:
            real_path = path_data

        #2. The key cache must include the index to distinguish between faces within the same TTC file.
        cdef tuple cache_key = (real_path, index)
        
        if cache_key not in self._cmap_cache:
            try:
                #3. Use fontNumber to open the correct Face in the gallery.
                # lazy=True is extremely important to avoid wasting RAM when only reading character sets.
                with TTFont(real_path, fontNumber=index, lazy=True) as tt:
                    self._cmap_cache[cache_key] = tt.getBestCmap()
            except Exception:
                self._cmap_cache[cache_key] = {}
        
        #4. Lookup in RAM - Maximum speed
        return code in self._cmap_cache[cache_key]

    cdef object _find_best_font_path(self, str ch, str face):
        """Cascade Search: Finds the best font file that contains the requested glyph."""
        cdef tuple cache_key = (ch, face)
        if cache_key in self._path_cache:
            return self._path_cache[cache_key]
            
        cdef int code = ord(ch)
        cdef object path = None
        cdef object current_p_path = self._get_true_path(self.primary_name, face)
        
        # Priority 1: Emoji Handling
        if is_emoji(ch):
            if self._has_glyph(self.emoji_path, code):
                path = self.emoji_path
                
        if not path:
            # Priority 2: Primary Font
            if MODERN_FONT and self._has_glyph(current_p_path, code):
                path = current_p_path
            else:
                # Priority 3: Fallback Layers (Standard -> International)
                path = self._search_fallback_layers(code, face)
                
        self._path_cache[cache_key] = path
        return path

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
        if cache_key in self._font_objs:
            return self._font_objs[cache_key]

        cdef object f_obj
        cdef bint syn_bold, syn_italic
        cdef tuple syn_flags
        try:
            # Use pygame.freetype instead of pygame.font
            if real_path.lower().endswith(".ttc"):
                # TTC: use index if available, default to 0 if not
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

            self._font_objs[cache_key] = f_obj
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

    cdef tuple _get_metrics(self, int size, str face):
        """Calculates and caches the standard ascender and height based on the specific font face."""
        cdef tuple cache_key = (size, face)
        cdef object f_fallback, current_f_path
        cdef double asc, height
        
        if cache_key not in self._std_metrics:
            try:
                current_f_path = self._get_true_path(self.fallback_name, face)
                f_fallback = self._get_font_obj(current_f_path, size, face)
                asc = float(f_fallback.get_sized_ascender())
                height = float(f_fallback.get_sized_height())
                self._std_metrics[cache_key] = (asc, height, f_fallback)
            except Exception:
                # Ultimate fallback to default Pygame system font
                f_fallback = self._get_font_obj(None, size, face)
                asc = float(f_fallback.get_sized_ascender())
                height = float(f_fallback.get_sized_height())
                self._std_metrics[cache_key] = (asc, height, f_fallback)
        return self._std_metrics[cache_key]

    cdef tuple _render_char(self, str ch, int size, tuple color, str face):
        """Low-level single character renderer with cache integration."""
        cdef tuple key, result
        cdef double f_asc, f_h, target_h, ratio
        cdef int baseline_y, final_h, actual_step, draw_x, dy
        cdef int w_with_A, w_AA, w_adv, final_w
        cdef object font_obj, surf, surf_raw, rect, old_font
        cdef object path

        key = (ch, size, color, MODERN_FONT, SMOOTH_FONT, EMOJI_OFFSET_Y, face)
        if key in self._glyph_cache: return self._glyph_cache[key]

        cdef tuple metrics = self._get_metrics(size, face)
        f_asc = <double>metrics[0]
        f_h = <double>metrics[1]
        final_h = <int>(f_h * 1.5)

        path = self._find_best_font_path(ch, face)
        font_obj = self._get_font_obj(path, size, face)

        # Apply the SMOOTH_FONT toggle (Sync baselines globally or use native peaks)
        baseline_y = <int>(f_asc + 0.5) if SMOOTH_FONT else <int>(font_obj.get_sized_ascender(size) + 9)

        if is_emoji(ch):
            old_font = self._get_old_engine(size)
            surf_raw = old_font.render(ch, self._anti_alias, (255, 255, 255))
            target_h = f_asc * 1.1
            ratio = 1.0
            if surf_raw.get_height() != int(target_h):
                ratio = target_h / <float>surf_raw.get_height()
                surf_raw = pygame.transform.smoothscale(
                    surf_raw, (max(1, int(surf_raw.get_width() * ratio)), int(target_h))
                )
            final_w = surf_raw.get_width()
            if final_w <= 0: final_w = 1
            surf = pygame.Surface((final_w, final_h), pygame.SRCALPHA)
            
            # Apply SMOOTH_FONT vertical alignment to Emojis
            dy = (<int>(f_asc + 0.5) - old_font.get_ascent() - <int>(size * EMOJI_OFFSET_Y)) if SMOOTH_FONT else 0
            if dy < 0: dy = 0
            surf.blit(surf_raw, (0, dy))
            actual_step = final_w
        else:
            w_with_A = font_obj.get_rect("A" + ch + "A", size=size).width
            w_AA = font_obj.get_rect("AA", size=size).width
            
            w_adv = w_with_A - w_AA
            font_obj.origin = True
            rect = font_obj.get_rect(ch, size=size)
            
            final_w = max(w_adv, <int>rect.width)
            if final_w <= 0: final_w = 1
            
            surf = pygame.Surface((final_w, final_h), pygame.SRCALPHA)
            draw_x = -<int>rect.x if <int>rect.x < 0 else 0
            if self._anti_alias:
                font_obj.render_to(surf, (draw_x, baseline_y), ch, color, size=size)
            else:
                font_obj.antialiased = False
                glyph_surf, _ = font_obj.render(ch, color, size=size)
                font_obj.antialiased = True
                surf.blit(glyph_surf, (draw_x, baseline_y - <int>(f_asc + 0.5)))
            font_obj.origin = False
            font_obj.origin = False
            
            actual_step = final_w

        result = (surf, actual_step)
        self._glyph_cache[key] = result
        return result

    cdef tuple _render_simple_run(self, str text, int size, tuple color, object font_path, str face):
        """
        THE AWAKENING OF THE TEXTURE ATLAS (ZERO FREETYPE OVERHEAD)
        Generates a fast surface array without HarfBuzz overhead for pure ASCII texts.
        """
        cdef int final_h, total_w = 0, cur_x = 0
        cdef double f_h
        cdef object s, surf
        cdef int adv
        cdef str ch
        cdef list char_surfs = []
        cdef list char_advs = []
        cdef Py_ssize_t i = 0

        cdef tuple metrics = self._get_metrics(size, face)
        f_h = <double>metrics[1]
        final_h = <int>(f_h * 1.5)

        for ch in text:
            s, adv = self._render_char(ch, size, color, face)
            char_surfs.append(s)
            char_advs.append(adv)
            total_w += adv

        if total_w <= 0: total_w = 1

        surf = pygame.Surface((total_w, final_h), pygame.SRCALPHA)
        for i in range(len(char_surfs)):
            surf.blit(char_surfs[i], (cur_x, 0))
            cur_x += <int>char_advs[i]

        return surf, total_w

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
        
        if hb_cache_key not in self._hb_fonts:
            try:
                with open(real_path, 'rb') as f:
                    font_data = f.read()
                
                # HarfBuzz Face supports the index parameter to select fonts from a .ttc collection.
                face = hb.Face(font_data, max(0, index))
                hb_font = hb.Font(face)
                
                # Save the entire set so that font_data is not freed from memory (avoid segfault errors)
                self._hb_fonts[hb_cache_key] = (hb_font, font_data)
                
            except Exception as e:
                print(f"Error loading HarfBuzz font at {real_path}, (index {index}): {e}")
                return None
                
        return self._hb_fonts[hb_cache_key][0]

    cdef object _render_shaped_run(self, str text, int size, tuple color, object font_path, str face):
        """
        Performance-optimized version:
        - Uses a static color mapping table for 256 Alpha values ​​to avoid calling `surf.map_rgb` in the pixel loop.
        - Casts PixelArray to Cython 2D Typed Memoryview to perform direct pixel overwrite operations at the C level.
        """
        cdef object hb_font, buf, raw, surf, old_font, face_obj, px_array
        cdef double f_asc, f_h, scale, cur_x, min_x, max_x, glyph_x, glyph_right, logical_x1, logical_x2, start_x
        cdef double base_x
        cdef int baseline_y, final_h, final_w, dy
        cdef int glyph_id, px, py, bmp_x, bmp_y, alpha_val, r, g, b
        cdef int w_bmp, h_bmp, pitch, abs_pitch, p_idx
        cdef double x_adv, x_off, y_off, draw_x, draw_y
        cdef str real_path
        cdef tuple metrics, ft_key, g_data
        cdef list glyph_render_data = []
        cdef bytes bmp_buffer
        cdef int index = 0
        cdef int space_w = 0
        cdef int logic_w = 0
        cdef double total_adv = 0.0

        # Declaring variables for optimization using C native
        cdef unsigned int mapped_colors[256]
        cdef int a
        cdef unsigned int[:, :] px_view

        metrics = self._get_metrics(size, face)
        f_asc = <double>metrics[0]
        f_h = <double>metrics[1]
        baseline_y = <int>(f_asc + 0.5)
        final_h = <int>(f_h * 1.5)
        
        # Quickly process emojis if the emoji font matches.
        if isinstance(font_path, (list, tuple)) and font_path[0] == self.emoji_path or font_path == self.emoji_path:
            old_font = self._get_old_engine(size)
            raw = old_font.render(text, self._anti_alias, (255, 255, 255))
            final_w = raw.get_width()
            if final_w <= 0: final_w = 1
            surf = pygame.Surface((final_w, final_h), pygame.SRCALPHA)
            dy = (<int>(f_asc + 0.5) - old_font.get_ascent() - <int>(size * EMOJI_OFFSET_Y)) if SMOOTH_FONT else 0
            if dy < 0: dy = 0
            surf.blit(raw, (0, dy))
            return surf, final_w

        if isinstance(font_path, (list, tuple)):
            real_path = font_path[0]
            index = font_path[1]
            if index < 0: index = 0
        else:
            real_path = font_path

        hb_font = self._get_hb_font(font_path)
        if hb_font is None:
            return pygame.Surface((1, final_h), pygame.SRCALPHA), 1

        # Creating and formatting text using HarfBuzz
        buf = hb.Buffer()
        buf.add_str(text)
        buf.guess_segment_properties()
        hb.shape(hb_font, buf)
        scale = size / <double>hb_font.face.upem

        ft_key = ("FT", real_path, index, size, face)
        if ft_key not in self._font_objs:
            try:
                face_obj = freetype.Face(real_path, max(0, index))
                face_obj.set_pixel_sizes(0, size)
                self._font_objs[ft_key] = face_obj
            except Exception:
                return pygame.Surface((1, final_h), pygame.SRCALPHA), 1

        face_obj = self._font_objs[ft_key]

        cdef bint _syn_bold = False, _syn_italic = False
        cdef tuple _syn_flags
        cdef bint _aa = self._anti_alias
        if face and self._is_synthetic_needed("", face, font_path):
            _syn_flags = self._get_synthetic_flags(face)
            _syn_bold   = <bint>_syn_flags[0]
            _syn_italic = <bint>_syn_flags[1]

        cur_x = 0.0
        min_x = 999999.0
        max_x = -999999.0
        glyph_render_data = []

        # Collect data from FreeType based on coordinate results from HarfBuzz
        for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
            glyph_id = info.codepoint
            x_adv = pos.x_advance * scale
            x_off = pos.x_offset * scale
            y_off = pos.y_offset * scale
            total_adv += x_adv
            base_x = cur_x
            cur_x += x_adv

            if (_syn_bold or _syn_italic) and _ft_lib is not None:
                face_obj.load_glyph(glyph_id, _FT_LOAD_NO_HINTING)
                _slot_ptr = ctypes.cast(face_obj.glyph._FT_GlyphSlot, ctypes.c_void_p)
                if _syn_bold:   _FT_GlyphSlot_Embolden(_slot_ptr)
                if _syn_italic: _FT_GlyphSlot_Oblique(_slot_ptr)
                face_obj.glyph.render(freetype.FT_RENDER_MODE_NORMAL if _aa else 2)
            else:
                face_obj.load_glyph(glyph_id, _FT_LOAD_AA if _aa else _FT_LOAD_MONO)

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

            glyph_render_data.append((
                bytes(face_obj.glyph.bitmap.buffer) if w_bmp > 0 else b"",
                w_bmp, h_bmp, pitch, left, top,
                base_x + x_off, y_off
            ))

        if min_x > max_x:
            space_w = max(1, <int>(total_adv + 0.5))
            return pygame.Surface((space_w, final_h), pygame.SRCALPHA), space_w

        start_x = -min_x if min_x < 0 else 0.0
        logic_w = <int>(total_adv + 0.5)
        final_w = max(1, <int>(max_x + start_x + 1.0))

        if logic_w > final_w:
            final_w = logic_w

        surf = pygame.Surface((final_w, final_h), pygame.SRCALPHA)
        r = color[0]; g = color[1]; b = color[2]
        
        # OPTIMIZATION 1: Pre-calc 32-bit color format for all 256 Alpha values
        for a in range(256):            
            mapped_colors[a] = <unsigned int>(<long>surf.map_rgb(r, g, b, a))

        px_array = pygame.PixelArray(surf)
        # OPTIMIZATION 2: Cast PixelArray to 2D MemoryView unsigned integer type at C-level
        px_view = px_array

        # Draw glyphs onto the surface using C-speed loops
        for g_data in glyph_render_data:
            w_bmp = g_data[1]
            if w_bmp <= 0: continue

            bmp_buffer = g_data[0]
            h_bmp = g_data[2]
            pitch = g_data[3]
            abs_pitch = pitch if pitch > 0 else -pitch

            draw_x = g_data[6] + g_data[4] + start_x
            draw_y = baseline_y - g_data[5] - g_data[7]

            if _aa:
                for bmp_y in range(h_bmp):
                    for bmp_x in range(w_bmp):
                        if pitch > 0:
                            p_idx = bmp_y * pitch + bmp_x
                        else:
                            p_idx = (h_bmp - 1 - bmp_y) * abs_pitch + bmp_x
                        alpha_val = bmp_buffer[p_idx]
                        if alpha_val > 0:
                            px = <int>(draw_x + bmp_x + 0.5)
                            py = <int>(draw_y + bmp_y + 0.5)
                            if 0 <= px < final_w and 0 <= py < final_h:
                                # Assign color values ​​directly from a pre-existing spreadsheet to the cache
                                px_view[px, py] = mapped_colors[alpha_val]
            else:
                for bmp_y in range(h_bmp):
                    for bmp_x in range(w_bmp):
                        if pitch > 0:
                            p_idx = bmp_y * pitch + bmp_x // 8
                        else:
                            p_idx = (h_bmp - 1 - bmp_y) * abs_pitch + bmp_x // 8
                        alpha_val = 255 if (bmp_buffer[p_idx] >> (7 - (bmp_x & 7))) & 1 else 0
                        if alpha_val > 0:
                            px = <int>(draw_x + bmp_x + 0.5)
                            py = <int>(draw_y + bmp_y + 0.5)
                            if 0 <= px < final_w and 0 <= py < final_h:
                                px_view[px, py] = mapped_colors[alpha_val]

        del px_array  # Unlock the surface lock of PixelArray
        return surf, logic_w

    cpdef render(self, str text, int size, tuple color=(255, 255, 255), bint dynamic=False, str face=""): #Convert def to cpdef
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
        cdef Py_ssize_t i = 0, j = 0, idx = 0, start = 0, end = 0, last_idx = 0, n = len(text)
        cdef tuple cache_key = (text, size, color, MODERN_FONT, SMOOTH_FONT, EMOJI_OFFSET_Y, face)

        # =========================================================================
        # 🚀 THE EARLY EXIT: O(1) Static Text Cache Lookup
        # Maintains ~0.03ms render speed for static UI elements.
        # =========================================================================
        if not dynamic and cache_key in self._text_cache: 
            return self._text_cache[cache_key]

        cdef bint is_pure_ascii = True
        cdef str _ch, ch, cmd, cat, active_face
        cdef tuple glyph_key
        cdef int std_ascent, std_h, total_logic_w, cur_x, w_adv, fixed_h, actual_final_w, code
        cdef Py_ssize_t eq_idx
        cdef object fallback_obj, final_surf, s, p, last_path = None 
        cdef object current_p_path, current_f_path, active_p_path, active_f_path
        cdef list current_run_chars = [], runs = [], surfs = [], logic_widths = []
        cdef list run_dirs = []
        cdef str prev_dir, next_dir
        cdef bint is_inheritable
        cdef tuple current_color = color
        cdef int current_script_group = -1, script_group

        self._ensure_init()
        
        # O(1) Base Path Resolution
        current_p_path = self._get_true_path(self.primary_name, face)
        current_f_path = self._get_true_path(self.fallback_name, face)
        
        # State Machine Initialization
        active_face = face
        active_p_path = current_p_path
        active_f_path = current_f_path

        # -----------------------------------------------------------
        # FAST PATH: Dynamic ASCII bypass
        # Routes formatted syntax (< or }) to the Full Pipeline automatically
        # -----------------------------------------------------------
        if dynamic and text:
            for _ch in text:
                if ord(_ch) > 127 or _ch == '^' or _ch == '<' or _ch == '}': 
                    is_pure_ascii = False
                    break
            
            if is_pure_ascii:
                actual_final_w = 0
                for _ch in text:
                    glyph_key = (_ch, size, color, MODERN_FONT, SMOOTH_FONT, EMOJI_OFFSET_Y, face)
                    if glyph_key not in self._glyph_cache:
                        self._glyph_cache[glyph_key] = self._render_shaped_run(_ch, size, color, current_p_path, face)
                    actual_final_w += <int>self._glyph_cache[glyph_key][1]
                
                std_ascent, std_h, fallback_obj = self._get_metrics(size, face)
                fixed_h = <int>(std_h * 1.5)
                if actual_final_w <= 0: actual_final_w = 1
                
                final_surf = pygame.Surface((actual_final_w, fixed_h), pygame.SRCALPHA)
                cur_x = 0
                
                for _ch in text:
                    glyph_key = (_ch, size, color, MODERN_FONT, SMOOTH_FONT, EMOJI_OFFSET_Y, face)
                    s, w_adv = self._glyph_cache[glyph_key]
                    final_surf.blit(s, (cur_x, 0))
                    cur_x += w_adv
                
                while len(self._glyph_cache) > MAX_GLYPH_CACHE:
                    self._glyph_cache.pop(next(iter(self._glyph_cache)), None)
                return final_surf

        # -----------------------------------------------------------
        # FULL PIPELINE: Multi-language, Bidi, Inline Face & Color parsing
        # -----------------------------------------------------------
        std_ascent, std_h, fallback_obj = self._get_metrics(size, face)

        while i < n:
            ch = text[i]
            
            # 1. INLINE COLOR PARSER (e.g., ^1 for Red)
            if ch == '^' and i + 1 < n:
                cmd = text[i+1]
                if cmd in RICH_PALETTE or cmd == 'r':
                    if current_run_chars:
                        runs.append(("".join(current_run_chars), last_path, current_color, current_script_group, active_face))
                        current_run_chars.clear()
                    current_color = RICH_PALETTE[cmd] if cmd != 'r' else color
                    i += 2
                    continue

            # 2. INLINE FACE OPEN PARSER (Supports both <bold={ and </bold={)
            if ch == '<':
                eq_idx = text.find('={', i)
                # Ensure valid syntax and a reasonable face name length (max 30 chars)
                if eq_idx != -1 and (eq_idx - i) < 30:
                    if current_run_chars:
                        runs.append(("".join(current_run_chars), last_path, current_color, current_script_group, active_face))
                        current_run_chars.clear()
                        
                    # Handle optional forward slash safely
                    if i + 1 < n and text[i+1] == '/':
                        active_face = text[i+2:eq_idx].lower().strip()
                    else:
                        active_face = text[i+1:eq_idx].lower().strip()
                        
                    active_p_path = self._get_true_path(self.primary_name, active_face)
                    active_f_path = self._get_true_path(self.fallback_name, active_face)
                    
                    i = eq_idx + 2
                    last_path = None # Force path re-evaluation for the new font face
                    continue

            # 3. INLINE FACE CLOSE PARSER (e.g., }>)
            if ch == '}' and i + 1 < n and text[i+1] == '>':
                if current_run_chars:
                    runs.append(("".join(current_run_chars), last_path, current_color, current_script_group, active_face))
                    current_run_chars.clear()
                    
                # Revert to default engine face
                active_face = face
                active_p_path = current_p_path
                active_f_path = current_f_path
                
                i += 2
                last_path = None # Force path re-evaluation
                continue

            code = ord(ch)
            cat = unicodedata.category(ch)

            # Skip control characters and invisible formatting tags
            if cat == 'Cc' or code in (0x200B, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 0x061C):
                i += 1
                continue

            # Script Group Classification ( Now will be intersect to _classify_script func )
            script_group = _classify_script(code)

            is_inheritable = (cat.startswith('M') or cat == 'Cf')

            # Font path resolution utilizing the active dynamically parsed face
            if is_inheritable and last_path is not None and current_script_group != 0:
                p = last_path
                script_group = current_script_group
            elif code in (0x20, 0x00A0):
                p = active_f_path
            else:
                p = self._find_best_font_path(ch, active_face)

            # Break run if font path or script group changes
            if current_run_chars and ((p is not last_path and p != last_path) or (script_group != current_script_group)):
                runs.append(("".join(current_run_chars), last_path, current_color, current_script_group, active_face))
                current_run_chars = [ch]
                current_script_group = script_group
                last_path = p
            else:
                if not current_run_chars: 
                    current_script_group = script_group
                current_run_chars.append(ch)
                last_path = p
            i += 1
            
        if current_run_chars: 
            runs.append(("".join(current_run_chars), last_path, current_color, current_script_group, active_face))

        # ==========================================================
        # LIGHTWEIGHT BIDI REORDERING
        # ==========================================================
        for _, _, _, s_group, _ in runs:
            if s_group in (1, 2, 6):
                run_dirs.append('RTL')
            elif s_group == 0:
                run_dirs.append('N')
            else:
                run_dirs.append('LTR')
                
        for idx in range(len(run_dirs)):
            if run_dirs[idx] == 'N':
                prev_dir = 'LTR'
                for j in range(idx-1, -1, -1):
                    if run_dirs[j] != 'N':
                        prev_dir = run_dirs[j]
                        break
                next_dir = 'LTR'
                for j in range(idx+1, len(run_dirs)):
                    if run_dirs[j] != 'N':
                        next_dir = run_dirs[j]
                        break
                if prev_dir == next_dir:
                    run_dirs[idx] = prev_dir
                else:
                    run_dirs[idx] = 'LTR'
                    
        start = 0
        while start < len(runs):
            if run_dirs[start] == 'RTL':
                end = start
                while end < len(runs) and run_dirs[end] == 'RTL':
                    end += 1
                runs[start:end] = list(reversed(runs[start:end]))
                start = end
            else:
                start += 1

        # ==========================================================
        # UNIVERSAL RENDERING & BLITTING
        # ==========================================================
        total_logic_w = 0
        for r_text, r_path, r_color, _, r_face in runs:
            if r_text:
                # Use r_face (the run's active_face) instead of the default face
                s, w_adv = self._render_shaped_run(r_text, size, r_color, r_path, r_face)
            else: 
                continue
            
            surfs.append(s)
            logic_widths.append(w_adv)
            total_logic_w += w_adv

        if len(surfs) == 1:
            final_surf = surfs[0]
        elif len(surfs) == 0:
            final_surf = pygame.Surface((1, <int>(std_h*1.5)), pygame.SRCALPHA)
        else:
            if total_logic_w <= 0: total_logic_w = 1
            fixed_h = <int>(std_h*1.5)
            actual_final_w = 0
            
            # Subpixel bleeding prevention
            if logic_widths:
                last_idx = len(logic_widths) - 1
                actual_final_w = (total_logic_w - <int>logic_widths[last_idx]) + <int>surfs[last_idx].get_width()
            else:
                actual_final_w = total_logic_w

            final_surf = pygame.Surface((actual_final_w, fixed_h), pygame.SRCALPHA)
            cur_x = 0
            for idx in range(len(surfs)):
                final_surf.blit(surfs[idx], (cur_x, 0))
                cur_x += <int>logic_widths[idx]

        # Cache valid outputs
        if not dynamic:
            self._text_cache[cache_key] = final_surf
            
        # LRU Cache Eviction to prevent memory leaks
        while len(self._text_cache) > MAX_TEXT_CACHE:
            self._text_cache.pop(next(iter(self._text_cache)), None)

        while len(self._glyph_cache) > MAX_GLYPH_CACHE:
            self._glyph_cache.pop(next(iter(self._glyph_cache)), None)

        return final_surf

    cpdef get_debug_info(self, object text_input, str face=""):
        """
        Returns detailed per-character rendering metadata.
        Fields per character:
          char        : the original character
          hex         : Unicode codepoint (U+XXXX)
          category    : Unicode category (Lu, Ll, Lo, ...)
          script      : script group (Latin/CJK/Arabic/Hebrew/Indic/Thai/Tibetan/Khmer)
          font_file   : the actual font file name
          font_source : PRIMARY / FALLBACK / EMOJI / MISSING
          ttc_index   : index within the TTC (-1 for a regular TTF)
          has_glyph   : whether the glyph exists in the font
          synthetic   : NONE / BOLD / ITALIC / BOLD+ITALIC
          render_path : SHAPED / SIMPLE / CHAR (predicted from script)
          tag_context : the currently active face tag (if there's an inline tag)
          is_tag      : True if this char is part of an inline tag (skipped when rendering)
        """
        self._ensure_init()

        if not face:
            face = self.init_face
        else:
            face = face.lower()

        cdef str text = str(text_input)
        cdef str ch, real_path, font_source, synthetic, render_path, tag_context
        cdef str active_face, cat
        cdef int code, ttc_index, script_group
        cdef bint has_g, is_tag
        cdef object path
        cdef list info = []
        cdef Py_ssize_t i = 0, n = len(text), eq_idx

        # Script group int → label
        _SCRIPT_LABEL = {
            0: "Space", 1: "Hebrew", 2: "Arabic",
            3: "Indic", 4: "Thai", 5: "Tibetan",
            6: "Khmer", 7: "Latin/CJK"
        }
        # Render path predicted from script group
        _RENDER_PATH = {
            0: "SIMPLE", 1: "SHAPED", 2: "SHAPED",
            3: "SHAPED", 4: "SHAPED", 5: "SHAPED",
            6: "SHAPED", 7: "SIMPLE"
        }

        active_face = face  # face currently active per inline tag

        while i < n:
            ch   = text[i]
            code = ord(ch)

            # --- Parse inline tags (mark only, not added to info) ---
            # Tag ^X (color)
            if code == 0x5E and i + 1 < n and (text[i+1] in RICH_PALETTE or text[i+1] == 'r'):
                info.append({
                    "char": " ", "hex": "TAG",
                    "category": "TAG", "script": "-",
                    "font": "-", "font_source": "TAG",
                    "ttc_index": -1, "has_glyph": False,
                    "synthetic": "NONE", "render_path": "-",
                    "tag_context": active_face, "is_tag": True,
                    "tag_type": f"COLOR:{text[i+1]}"
                })
                i += 2; continue

            # Tag <face={ ... (open face tag)
            if code == 0x3C:
                eq_idx = text.find('={', i)
                if eq_idx != -1 and (eq_idx - i) < 30:

                    if i + 1 < n and text[i+1] == '/':
                        active_face = text[i+2:eq_idx].lower().strip()
                    else:
                        active_face = text[i+1:eq_idx].lower().strip()
                    # Find closing }



                    info.append({
                        "char": " ", "hex": "TAG",
                        "category": "TAG", "script": "-",
                        "font": "-", "font_source": "TAG", "ttc_index": -1, "has_glyph": False,
                        "synthetic": "NONE", "render_path": "-",
                        "tag_context": active_face, "is_tag": True,
                        "tag_type": f"FACE_OPEN:{active_face}"
                    })
                    i = eq_idx + 2; continue

            # Tag }> (close face tag)
            if code == 0x7D and i + 1 < n and text[i+1] == '>':
                active_face = face  # reset về face gốc
                info.append({
                    "char": " ", "hex": "TAG",
                    "category": "TAG", "script": "-",
                    "font": "-", "font_source": "TAG",
                    "ttc_index": -1, "has_glyph": False,
                    "synthetic": "NONE", "render_path": "-",
                    "tag_context": active_face, "is_tag": True,
                    "tag_type": "FACE_CLOSE"
                })
                i += 2; continue

            # --- Regular character ---
            cat          = unicodedata.category(ch)
            if code == 0x20 or code == 0x00A0:   script_group = 0
            elif 0x0590 <= code <= 0x05FF:        script_group = 1
            elif (0x0600 <= code <= 0x08FF or
                  0xFB50 <= code <= 0xFDFF or
                  0xFE70 <= code <= 0xFEFF):      script_group = 2
            elif 0x0900 <= code <= 0x0DFF:        script_group = 3
            elif 0x0E00 <= code <= 0x0EFF:        script_group = 4
            elif 0x0F00 <= code <= 0x109F:        script_group = 5
            elif 0x1780 <= code <= 0x17FF:        script_group = 6
            else:                                 script_group = 7
            path         = self._find_best_font_path(ch, active_face)

            # Font file + source
            if path:
                if isinstance(path, (list, tuple)):
                    real_path = str(path[0])
                    ttc_index = int(path[1]) if len(path) > 1 else -1
                else:
                    real_path = str(path)
                    ttc_index = -1

                fname = os.path.basename(real_path)
                has_g = self._has_glyph(path, code)

                # Determine source
                primary_p = self._get_true_path(self.primary_name, active_face)
                fallback_p = self._get_true_path(self.fallback_name, active_face)
                emoji_p    = getattr(self, '_emoji_path', None)

                if path == primary_p or real_path == str(primary_p[0] if isinstance(primary_p, (list,tuple)) else primary_p):
                    font_source = "PRIMARY"
                elif path == fallback_p or real_path == str(fallback_p[0] if isinstance(fallback_p, (list,tuple)) else fallback_p):
                    font_source = "FALLBACK"
                elif emoji_p and real_path == str(emoji_p[0] if isinstance(emoji_p, (list,tuple)) else emoji_p):
                    font_source = "EMOJI"
                else:
                    font_source = "INTL"
            else:
                fname      = "NOT_FOUND"
                ttc_index  = -1
                has_g      = False
                font_source = "MISSING"

            # Synthetic flag
            syn_flags = self._get_synthetic_flags(active_face)
            if self._is_synthetic_needed("", active_face, path):
                if syn_flags[0] and syn_flags[1]:
                    synthetic = "BOLD+ITALIC"
                elif syn_flags[0]:
                    synthetic = "BOLD"
                elif syn_flags[1]:
                    synthetic = "ITALIC"
                else:
                    synthetic = "NONE"
            else:
                synthetic = "NONE"

            info.append({
                "char":        ch,
                "hex":         f"U+{code:04X}",
                "category":    cat,
                "script":      _SCRIPT_LABEL.get(script_group, "Unknown"),
                "font":        fname,
                "font_source": font_source,
                "ttc_index":   ttc_index,
                "has_glyph":   has_g,
                "synthetic":   synthetic,
                "render_path": _RENDER_PATH.get(script_group, "SIMPLE"),
                "tag_context": active_face,
                "is_tag":      False,
                "tag_type":    "-"
            })
            i += 1

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
