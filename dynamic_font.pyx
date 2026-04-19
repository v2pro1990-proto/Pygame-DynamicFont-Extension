# DynamicFont Extension For Pygame and Pygame-CE !
# Author : v2pro1990
# Email : v2pro1990@gmail.com
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
from collections import OrderedDict

MODERN_FONT = True
SMOOTH_FONT = True   # Bật/tắt cơ chế căn chỉnh baseline
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
cdef tuple PROTECTED_VARS = ("is_scanning", "_is_scanning")
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

pygame.freetype.init()


def is_scanning() -> bool:
    """Read-Only API: Returns the font scanning status of the Engine"""
    global _is_scanning
    return _is_scanning

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

cdef class DynamicFont:
    cdef str primary_name, fallback_name, fallback_dir, emoji_path
    cdef dict _font_objs, _hb_fonts, _path_cache, _cmap_cache, _pg_font_cache
    cdef dict _std_metrics, _font_map
    cdef list _intl_font_paths
    cdef public dict _glyph_cache, _text_cache, emoji_fallback_engine
    cdef bint _initialized
    cdef object _cached_p_path
    cdef object _cached_f_path_std

    def __init__(self,
                 primary_name="Arial",
                 fallback_name="Times New Roman",
                 fallback_dir="assets/fonts/fallback",
                 emoji_path="assets/fonts/NotoEmoji-Regular.ttf"):
        self.primary_name = primary_name
        self.fallback_name = fallback_name
        self.fallback_dir = fallback_dir
        self.emoji_path = emoji_path
        
        self._font_objs = {}      
        self._hb_fonts = {}
        self._path_cache = {}
        self._pg_font_cache = {}
        self._cmap_cache = {}
        self._std_metrics = {}    
        self._glyph_cache = {}
        self._text_cache = {}
        self._font_map = {}
        self._intl_font_paths = []
        self._initialized = False
        self.emoji_fallback_engine = {} # Separate cache for old fonts

    cdef void _ensure_init(self):
        if self._initialized: return
        
        #1. Load the system's map font.
        self._font_map = load_or_update_font_map()
        
        #2. Get the actual paths of the Primary Font and Fallback Font.
        self._cached_p_path = self._get_true_path(self.primary_name)
        self._cached_f_path_std = self._get_true_path(self.fallback_name)
        
        #3. CHECK THE EXITS OF THE SECONDARY FONT (BYPASS LOGIC)
        cdef str check_p = ""
        if self._cached_f_path_std:
            # Tách đường dẫn nếu nó là định dạng [path, index] của TTC
            if isinstance(self._cached_f_path_std, (list, tuple)):
                check_p = <str>self._cached_f_path_std[0]
            else:
                check_p = <str>self._cached_f_path_std
            
            # If the file does not exist on the hard drive, assign None to bypass Layer 2.
            if not os.path.exists(check_p):
                self._cached_f_path_std = None

        #4. Load the list of international fonts from the fallback folder (Layer 3)
        if os.path.exists(self.fallback_dir):
            self._intl_font_paths = [os.path.join(self.fallback_dir, f) 
                                     for f in os.listdir(self.fallback_dir) 
                                     if f.lower().endswith((".ttf", ".otf", ".ttc"))]
        
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

    cdef object _get_true_path(self, str name):
        # Returns an object to preserve the [path, index] structure for TTC.
        if os.path.exists(name): 
            return name
            
        cdef dict names = self._font_map.get("names", {})
        cdef dict paths = self._font_map.get("paths", {})
        cdef str low_name = name.lower()
        
        # Find the original name (target) from the alias
        cdef str target = names.get(low_name, low_name)
        
        # Returns list [path, index] if it exists in the map, otherwise returns the original str name
        return paths.get(target, name)

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

    cdef object _find_best_font_path(self, str ch):
        cdef int code = ord(ch)
        cdef object path = None

        if ch in self._path_cache:
            return self._path_cache[ch]

        if is_emoji(ch):
            if self._has_glyph(self.emoji_path, code):
                path = self.emoji_path

        if not path:
            if MODERN_FONT and self._has_glyph(self._cached_p_path, code):
                path = self._cached_p_path
            else:
                path = self._search_fallback_layers(code)

        self._path_cache[ch] = path
        return path

    cdef object _search_fallback_layers(self, int code):
        # If _cached_f_path_std is None (already handled in init), this check will skip layer 2 altogether.
        if self._cached_f_path_std and self._has_glyph(self._cached_f_path_std, code):
            return self._cached_f_path_std
        
        # Reviewing the International List (Layer 3)
        cdef object f_path 
        for f_path in self._intl_font_paths:
            if self._has_glyph(f_path, code):
                return f_path
                
        # FINAL NOTE: If nothing is found, revert to the Primary Font (Layer 1) as a last resort.
        # Never return None here to avoid causing problems with the font loading function behind it.
        return self._cached_p_path

    cdef object _get_font_obj(self, object path_data, int size):
        cdef str real_path
        cdef int index = 0
        
        # Extracting paths and indexes from data
        if isinstance(path_data, (list, tuple)):
            real_path = path_data[0]
            index = path_data[1]
        else:
            real_path = path_data

        # Check your cache to avoid reloading existing fonts.
        cdef tuple cache_key = (real_path, index, size)
        if cache_key in self._font_objs:
            return self._font_objs[cache_key]

        cdef object f_obj
        try:
            # Use pygame.freetype instead of pygame.font
            if real_path.lower().endswith(".ttc"):
                # FreeType supports font_index directly and is extremely stable.
                # FreeType handles file reading very well.
                f_obj = pygame.freetype.Font(real_path, size, font_index=index)
            else:
                f_obj = pygame.freetype.Font(real_path, size)
                
            # Additional configuration to make the font look better (optional)
            f_obj.antialiased = ANTI_ALIAS
            f_obj.use_bitmap_strikes = True
            #f_obj.origin = True
            
            self._font_objs[cache_key] = f_obj
            return f_obj
            
        except Exception as e:
            pass
            # Fallback to system fonts but still using FreeType
            try:
                # Use FreeType's SysFont to synchronize object types
                f_obj = pygame.freetype.SysFont("arial", size)
                f_obj.antialiased = ANTI_ALIAS
                return f_obj
            except:
                # If even the system doesn't have Arial, use Pygame's default font.
                # Note: pygame.freetype.Font(None) will load the module's default font.
                return pygame.freetype.Font(None, size)

    cdef tuple _get_metrics(self, int size):
        cdef object f_fallback
        cdef double asc, height
        
        if size not in self._std_metrics:
            try:
                # FORCED: Use parameters from FALLBACK as a standard template for the entire Engine
                # self._cached_f_path_fallback has been optimized for Pygame UI.
                f_fallback = self._get_font_obj(self._cached_f_path_std, size)
                
                asc = float(f_fallback.get_sized_ascender())
                height = float(f_fallback.get_sized_height())
                
                # Save the fallback font parameters to the cache
                self._std_metrics[size] = (asc, height, f_fallback)
                
            except Exception as e:
                # Final fallback (System Default) if path fails
                f_fallback = self._get_font_obj(None, size)
                asc = float(f_fallback.get_sized_ascender())
                height = float(f_fallback.get_sized_height())
                self._std_metrics[size] = (asc, height, f_fallback)
                        
        return self._std_metrics[size]

    cdef _render_char(self, str ch, int size, tuple color):
        cdef tuple key, result
        cdef double f_asc, f_h, target_h, ratio
        cdef int baseline_y, final_h, actual_step, draw_x, dy
        cdef int w_with_A, w_AA, w_adv, final_w
        cdef object font_obj, surf, surf_raw, rect, old_font
        cdef object path
        
        key = (ch, size, color, MODERN_FONT, SMOOTH_FONT, EMOJI_OFFSET_Y)
        if key in self._glyph_cache: return self._glyph_cache[key]

        cdef tuple metrics = self._get_metrics(size)
        f_asc = <double>metrics[0]
        f_h = <double>metrics[1]
        final_h = <int>(f_h * 1.5)

        path = self._find_best_font_path(ch)
        font_obj = self._get_font_obj(path, size)

        # Apply the SMOOTH_FONT switch (Take either the common Baseline or its own Peak)
        baseline_y = <int>(f_asc + 0.5) if SMOOTH_FONT else <int>(font_obj.get_sized_ascender(size) + 3 )

        if is_emoji(ch):
            old_font = self._get_old_engine(size)
            surf_raw = old_font.render(ch, ANTI_ALIAS, (255, 255, 255))
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
            
            # Apply SMOOTH_FONT to Emoji
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
            font_obj.render_to(surf, (draw_x, baseline_y), ch, color, size=size)
            font_obj.origin = False
            
            actual_step = final_w

        result = (surf, actual_step)
        self._glyph_cache[key] = result
        return result

    cdef tuple _render_simple_run(self, str text, int size, tuple color, object font_path):
        # ========================================================
        # THE AWAKENING OF THE TEXTURE ATLAS (ZERO FREETYPE OVERHEAD)
        # ========================================================
        cdef int final_h, total_w = 0, cur_x = 0
        cdef double f_h
        cdef object s, surf
        cdef int adv
        cdef str ch
        cdef list char_surfs = []
        cdef list char_advs = []

        # 1. Lấy thông số chiều cao chuẩn
        cdef tuple metrics = self._get_metrics(size)
        f_h = <double>metrics[1]
        final_h = <int>(f_h * 1.5)

        for ch in text:
            s, adv = self._render_char(ch, size, color)
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
                face = hb.Face(font_data, index)
                hb_font = hb.Font(face)
                
                # Save the entire set so that font_data is not freed from memory (avoid segfault errors)
                self._hb_fonts[hb_cache_key] = (hb_font, font_data)
                
            except Exception as e:
                print(f"Error loading HarfBuzz font at {real_path}, (index {index}): {e}")
                return None
                
        return self._hb_fonts[hb_cache_key][0]

    cdef object _render_shaped_run(self, str text, int size, tuple color, object font_path):
        cdef object hb_font, buf, raw, surf, old_font, pos, pg_font
        cdef double f_asc, f_h, scale, total_adv
        cdef int baseline_y, final_h, final_w, dy, w_adv, actual_step
        cdef str real_path
         
        f_asc = <float>self._get_metrics(size)[0]
        f_h = <float>self._get_metrics(size)[1]
        baseline_y = <int>(f_asc + 0.5)
        final_h = <int>(f_h * 1.5)

        if isinstance(font_path, (list, tuple)) and font_path[0] == self.emoji_path or font_path == self.emoji_path:
            old_font = self._get_old_engine(size)
            raw = old_font.render(text, ANTI_ALIAS, (255, 255, 255))
            final_w = raw.get_width()
            if final_w <= 0: final_w = 1
            surf = pygame.Surface((final_w, final_h), pygame.SRCALPHA)
            
            # Áp dụng SMOOTH_FONT cho Emoji
            dy = (<int>(f_asc + 0.5) - old_font.get_ascent() - <int>(size * EMOJI_OFFSET_Y)) if SMOOTH_FONT else 0
            if dy < 0: dy = 0
            surf.blit(raw, (0, dy))
            return surf, final_w

        hb_font = self._get_hb_font(font_path)
        buf = hb.Buffer()
        buf.add_str(text)
        buf.guess_segment_properties()
        hb.shape(hb_font, buf)
        
        scale = size / <float>hb_font.face.upem
        total_adv = 0.0
        for pos in buf.glyph_positions:
            total_adv += pos.x_advance * scale
        w_adv = <int>(total_adv + 0.5)

        if isinstance(font_path, (list, tuple)): real_path = font_path[0]
        else: real_path = font_path
            
        # FIX FPS DROP: Cấp lại cơ chế Cache RAM y hệt V1 để ngắt hoàn toàn I/O Ổ cứng!
        cdef tuple pg_key = (real_path, size)
        if pg_key not in self._pg_font_cache:
            try: 
                self._pg_font_cache[pg_key] = pygame.font.Font(real_path, size)
            except Exception: 
                self._pg_font_cache[pg_key] = pygame.font.SysFont(self.fallback_name, size)
                
        pg_font = self._pg_font_cache[pg_key]
            
        raw = pg_font.render(text, ANTI_ALIAS, color)

        # KEY: Force final_w to encompass the entire drawing.
        final_w = max(w_adv, raw.get_width())
        if final_w <= 0: final_w = 1

        surf = pygame.Surface((final_w, final_h), pygame.SRCALPHA)
        
        # Apply SMOOTH_FONT to Shaped Run using get_ascent()
        dy = (<int>(f_asc + 0.5) - pg_font.get_ascent()) if SMOOTH_FONT else 0
        if dy < 0: dy = 0
        surf.blit(raw, (0, dy))

        # Return the Step that has been filled with additional padding.
        actual_step = final_w
        return surf, actual_step


    def render(self, str text, int size, tuple color=(255, 255, 255), bint dynamic=False):
        """This function has been improved to allow you to call the original pygame syntax, but will
        use the syntax from pygame.freetype!
        Example:
        font = font.render("Here is sample text", size = 20, color = (255, 255, 255))
        screen.blit(font, (100, 200))"""
        # ==========================================================
        # 0. TOP-LEVEL CDEF DECLARATIONS FOR CYTHON COMPLIANCE
        # ==========================================================
        cdef bint is_pure_ascii = True
        cdef str _ch
        cdef tuple cache_key, glyph_key
        cdef int std_ascent, std_h, total_logic_w, cur_x, w_adv, fixed_h, actual_final_w, last_idx
        cdef object fallback_obj, final_surf, s
        cdef str ch, cmd
        cdef list current_run_chars = []
        cdef object p, last_path = None 
        cdef bint run_is_complex = False, char_is_complex
        cdef list runs = [], surfs = [], logic_widths = []
        cdef tuple current_color = color
        cdef Py_ssize_t i = 0, n = len(text)
        cdef int code

        self._ensure_init()

        # ==========================================================
        # 1. SUPER FAST-PATH: BITMAP FONT TECHNIQUE FOR DYNAMIC TEXT
        # Cache text at the Character (Glyph) level instead of the String level!
        # ==========================================================
        if dynamic and text:
            for _ch in text:
                if ord(_ch) > 127 or _ch == '^': 
                    is_pure_ascii = False
                    break
            
            if is_pure_ascii:
                actual_final_w = 0
                
                # Pass 1: Calculate total width and populate Glyph Cache
                for _ch in text:
                    glyph_key = (_ch, size, color, MODERN_FONT, SMOOTH_FONT, EMOJI_OFFSET_Y)
                    if glyph_key not in self._glyph_cache:
                        self._glyph_cache[glyph_key] = self._render_simple_run(_ch, size, color, self._cached_p_path)
                    actual_final_w += <int>self._glyph_cache[glyph_key][1]
                
                # Prepare the main Surface
                std_ascent, std_h, fallback_obj = self._get_metrics(size)
                fixed_h = <int>(std_h * 1.5)
                if actual_final_w <= 0: actual_final_w = 1
                
                final_surf = pygame.Surface((actual_final_w, fixed_h), pygame.SRCALPHA)
                cur_x = 0
                
                # Pass 2: Blit pre-rendered glyphs (Lightning fast, Zero FreeType overhead)
                for _ch in text:
                    glyph_key = (_ch, size, color, MODERN_FONT, SMOOTH_FONT, EMOJI_OFFSET_Y)
                    s, w_adv = self._glyph_cache[glyph_key]
                    final_surf.blit(s, (cur_x, 0))
                    cur_x += w_adv
                
                # O(1) Eviction for Glyph Cache
                while len(self._glyph_cache) > MAX_GLYPH_CACHE:
                    self._glyph_cache.pop(next(iter(self._glyph_cache)), None)
                    
                return final_surf

        # ==========================================================
        # 2. CHECK CACHE (Only applies to static text)
        # ==========================================================
        cache_key = (text, size, color, MODERN_FONT, SMOOTH_FONT, EMOJI_OFFSET_Y)
        if not dynamic and cache_key in self._text_cache: 
            return self._text_cache[cache_key]

        std_ascent, std_h, fallback_obj = self._get_metrics(size)

        # ==========================================================
        # 3. DIVIDING TEXT INTO SECTIONS (RUNS)
        # ==========================================================
        while i < n:
            ch = text[i]
            
            # Handle Rich Text Palette
            if ch == '^' and i + 1 < n:
                cmd = text[i+1]
                if cmd in RICH_PALETTE or cmd == 'r':
                    if current_run_chars:
                        runs.append(("".join(current_run_chars), last_path, run_is_complex, current_color))
                        current_run_chars.clear()
                    current_color = RICH_PALETTE[cmd] if cmd != 'r' else color
                    i += 2
                    continue

            code = ord(ch)
            # Inherit font for spaces to prevent run fragmentation
            p = self._cached_f_path_std if code == 0x20 else self._find_best_font_path(ch)
            
            char_is_complex = (is_emoji(ch) or (0x0E00 <= code <= 0x0FFF) or 
                               (0x0600 <= code <= 0x06FF) or (0x0900 <= code <= 0x0DFF))
            
            # Break run if font path or complexity changes
            if (p is not last_path and p != last_path or char_is_complex != run_is_complex) and current_run_chars:
                runs.append(("".join(current_run_chars), last_path, run_is_complex, current_color))
                current_run_chars = [ch]
                run_is_complex = char_is_complex
                last_path = p
            else:
                if not current_run_chars: 
                    run_is_complex = char_is_complex
                current_run_chars.append(ch)
                last_path = p
            
            last_path = p
            i += 1
            
        if current_run_chars: 
            runs.append(("".join(current_run_chars), last_path, run_is_complex, current_color))

        # ==========================================================
        # 4. RENDER IN SECTIONS
        # ==========================================================
        total_logic_w = 0
        for r_text, r_path, is_complex, r_color in runs:
            if is_complex:
                s, w_adv = self._render_shaped_run(r_text, size, r_color, r_path)
            else:
                if r_text:
                    s, w_adv = self._render_simple_run(r_text, size, r_color, r_path)
                else:
                    continue
            
            surfs.append(s)
            logic_widths.append(w_adv)
            total_logic_w += w_adv

        # ==========================================================
        # 5. SURFACE ASSEMBLY
        # ==========================================================
        if len(surfs) == 1:
            final_surf = surfs[0]
        else:
            if total_logic_w <= 0: total_logic_w = 1
            fixed_h = <int>(std_h*1.5)
            
            actual_final_w = 0
            if logic_widths:
                last_idx = <int>len(logic_widths) - 1
                actual_final_w = (total_logic_w - <int>logic_widths[last_idx]) + <int>surfs[last_idx].get_width()
            else:
                actual_final_w = total_logic_w

            final_surf = pygame.Surface((actual_final_w, fixed_h), pygame.SRCALPHA)
            cur_x = 0
            for idx in range(len(surfs)):
                final_surf.blit(surfs[idx], (cur_x, 0))
                cur_x += <int>logic_widths[idx]

        # ==========================================================
        # 6. CACHE MANAGEMENT (DO NOT CACHE DYNAMIC TEXT TO PREVENT GC SPIKES)
        # ==========================================================
        if not dynamic:
            self._text_cache[cache_key] = final_surf
            
        # O(1) Drip eviction to prevent Stuttering/Micro-stutters
        while len(self._text_cache) > MAX_TEXT_CACHE:
            self._text_cache.pop(next(iter(self._text_cache)), None)

        while len(self._glyph_cache) > MAX_GLYPH_CACHE:
            self._glyph_cache.pop(next(iter(self._glyph_cache)), None)

        return final_surf
        
    def get_debug_info(self, object text_input):
        """This function returns detailed character information for error checking, supporting both TTC and Emoji."""
        self._ensure_init()
        import os
        
        # Ensure the input is a string for iteration
        cdef str text = str(text_input)
        cdef str ch, fname, real_path
        cdef int code
        cdef bint has_g
        cdef object path  # Keep it as an object because it could be a list [path, index]
        cdef list info = []
        
        for ch in text:
            code = ord(ch)
            path = self._find_best_font_path(ch)
            
            if path:
                # If it's TTC, the path is a list [path, index] -> get index 0
                if isinstance(path, (list, tuple)):
                    real_path = str(path[0])
                else:
                    real_path = str(path)
                
                fname = os.path.basename(real_path)
                has_g = self._has_glyph(path, code)
            else:
                fname = "NOT_FOUND"
                has_g = False
                
            info.append({
                "char": ch,
                "hex": hex(code).upper(),
                "font": fname,
                "has_glyph": has_g
            })
        return info
              
# VARIABLE PROTECT CLASS
class _ProtectedEngine(types.ModuleType):
    
    # 1. OVERWRITING SELECTION (SET)
    def __setattr__(self, name, value):
        # Preventing the overwriting of internal system variables
        if name in PROTECTED_VARS:
            print(f"[WARNING]: The variable '{name}' is a protected local variable ( Read-Only ). Ignoring the action of overwriting its value...")
            return 
            
        # 1.2 Configurations (SMOOTH_FONT, MODERN_FONT...) can be assigned freely.
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
