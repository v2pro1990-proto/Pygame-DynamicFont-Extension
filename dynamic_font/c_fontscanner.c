#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif

#include "c_fontscanner.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <sys/stat.h>

#ifdef _WIN32
#include <windows.h>
#define strcasecmp _stricmp
#define strncasecmp _strnicmp
#else
#include <dirent.h>
#include <unistd.h>
#include <strings.h>  /* Required for POSIX strcasecmp on Linux/macOS */
#define _stricmp strcasecmp
#define _strnicmp strncasecmp
#endif

#include FT_SFNT_NAMES_H
#include FT_TRUETYPE_IDS_H

#ifndef TT_PLATFORM_APPLE_UNICODE
#define TT_PLATFORM_APPLE_UNICODE 0
#endif

#ifndef TT_PLATFORM_MACINTOSH
#define TT_PLATFORM_MACINTOSH 1
#endif

#ifndef TT_PLATFORM_MICROSOFT
#define TT_PLATFORM_MICROSOFT 3
#endif

static const char* FONT_SUFFIXES[] = {
    " extra bold italic", " extrabold italic", " extra light italic", " extralight italic",
    " semi bold italic", " semibold italic", " semi light italic", " semilight italic",
    " medium italic", " black italic", " thin italic", " bold italic", " light italic",
    " italic", " extra bold", " extrabold", " extra light", " extralight",
    " semi bold", " semibold", " semi light", " semilight",
    " medium", " black", " thin", " bold", " light", " regular", " normal",
    "-extrabolditalic", "-extralightitalic", "-semibolditalic", "-semilightitalic",
    "-mediumitalic", "-blackitalic", "-thinitalic", "-bolditalic", "-lightitalic",
    "-italic", "-extrabold", "-extralight", "-semibold", "-semilight",
    "-medium", "-black", "-thin", "-bold", "-light", "-regular", "-normal",
    NULL
};

static void scan_dir_recursive(FT_Library ft_lib, const char* dir_path, C_FontScanResult* out_res);


static inline int ends_with_case_insensitive(const char* str, const char* suffix) {
    size_t str_len = strlen(str);
    size_t suf_len = strlen(suffix);
    if (suf_len > str_len) return 0;
    const char* p_str = str + (str_len - suf_len);
    for (size_t i = 0; i < suf_len; ++i) {
        if (tolower((unsigned char)p_str[i]) != tolower((unsigned char)suffix[i])) return 0;
    }
    return 1;
}

static inline int is_font_extension(const char* filename) {
    size_t len = strlen(filename);
    if (len < 4) return 0;
    const char* ext = filename + len - 4;
    return (_stricmp(ext, ".ttf") == 0 || _stricmp(ext, ".otf") == 0 || _stricmp(ext, ".ttc") == 0);
}

void c_get_family_root(const char* font_name, char* out_root, int max_len) {
    if (!font_name || max_len <= 0) return;
    strncpy(out_root, font_name, max_len - 1);
    out_root[max_len - 1] = '\0';

    for (int i = 0; FONT_SUFFIXES[i] != NULL; ++i) {
        if (ends_with_case_insensitive(out_root, FONT_SUFFIXES[i])) {
            size_t suf_len = strlen(FONT_SUFFIXES[i]);
            size_t root_len = strlen(out_root) - suf_len;
            
            /* If stripping makes string empty, keep the original name */
            if (root_len == 0) break;

            out_root[root_len] = '\0';
            while (root_len > 0 && (isspace((unsigned char)out_root[root_len - 1]) || out_root[root_len - 1] == '-')) {
                out_root[--root_len] = '\0';
            }
            if (strlen(out_root) == 0) {
                strncpy(out_root, font_name, max_len - 1);
                out_root[max_len - 1] = '\0';
            }
            break;
        }
    }
}


static void decode_sfnt_name(FT_SfntName* sfnt, char* out_buf, int max_len) {
    if (!out_buf || max_len <= 0) return;
    out_buf[0] = '\0';
    if (!sfnt || !sfnt->string || sfnt->string_len == 0) return;

    char temp[256];
    int out_idx = 0;
    int limit = (max_len < 250) ? max_len : 250;

    if (sfnt->platform_id == TT_PLATFORM_MICROSOFT || sfnt->platform_id == TT_PLATFORM_APPLE_UNICODE || sfnt->platform_id == 0) {
        /* UTF-16BE decode */
        for (unsigned int i = 0; i + 1 < sfnt->string_len && out_idx < limit; i += 2) {
            unsigned char hi = sfnt->string[i];
            unsigned char lo = sfnt->string[i + 1];
            if (hi == 0 && lo >= 0x20 && lo <= 0x7E) {
                temp[out_idx++] = (char)lo;
            }
        }
    } else {
        /* ASCII / Latin / MacRoman decode */
        for (unsigned int i = 0; i < sfnt->string_len && out_idx < limit; ++i) {
            unsigned char c = sfnt->string[i];
            if (c >= 0x20 && c <= 0x7E) {
                temp[out_idx++] = (char)c;
            }
        }
    }
    temp[out_idx] = '\0';

    /* Trim leading and trailing whitespaces safely */
    char* start = temp;
    while (*start && isspace((unsigned char)*start)) start++;

    char* end = start + strlen(start);
    while (end > start && isspace((unsigned char)*(end - 1))) {
        end--;
    }
    *end = '\0';

    if (strlen(start) > 0) {
        strncpy(out_buf, start, max_len - 1);
        out_buf[max_len - 1] = '\0';
    }
}

static int extract_face_name(FT_Library ft_lib, const char* path, int face_index, char* out_name, int max_len) {
    if (!ft_lib || !path || !out_name || max_len <= 0) return 0;
    out_name[0] = '\0';

    FT_Face face = NULL;
    if (FT_New_Face(ft_lib, path, face_index, &face) != 0 || !face) {
        return 0;
    }

    FT_UInt count = FT_Get_Sfnt_Name_Count(face);
    FT_SfntName sfnt;
    char candidate[128];

    /* Pass 1: Match NameID 4 (Full Name) with US English (0x0409) */
    for (FT_UInt i = 0; i < count; ++i) {
        if (FT_Get_Sfnt_Name(face, i, &sfnt) != 0 || !sfnt.string || sfnt.string_len == 0) continue;
        if (sfnt.name_id == 4 && sfnt.language_id == 0x0409) {
            decode_sfnt_name(&sfnt, out_name, max_len);
            if (out_name[0] != '\0') {
                FT_Done_Face(face);
                return 1;
            }
        }
    }

    /* Pass 2: Match any NameID 4 (Full Name) */
    for (FT_UInt i = 0; i < count; ++i) {
        if (FT_Get_Sfnt_Name(face, i, &sfnt) != 0 || !sfnt.string || sfnt.string_len == 0) continue;
        if (sfnt.name_id == 4) {
            decode_sfnt_name(&sfnt, candidate, sizeof(candidate));
            if (candidate[0] != '\0') {
                strncpy(out_name, candidate, max_len - 1);
                out_name[max_len - 1] = '\0';
                FT_Done_Face(face);
                return 1;
            }
        }
    }

    /* Pass 3: Fallback to NameID 1 (Family Name) */
    for (FT_UInt i = 0; i < count; ++i) {
        if (FT_Get_Sfnt_Name(face, i, &sfnt) != 0 || !sfnt.string || sfnt.string_len == 0) continue;
        if (sfnt.name_id == 1) {
            decode_sfnt_name(&sfnt, candidate, sizeof(candidate));
            if (candidate[0] != '\0') {
                strncpy(out_name, candidate, max_len - 1);
                out_name[max_len - 1] = '\0';
                FT_Done_Face(face);
                return 1;
            }
        }
    }

    /* Pass 4: Fallback to FreeType internal family_name */
    if (face->family_name && face->family_name[0] != '\0') {
        strncpy(out_name, face->family_name, max_len - 1);
        out_name[max_len - 1] = '\0';
    }

    FT_Done_Face(face);
    return (out_name[0] != '\0');
}

static void add_font_entry(C_FontScanResult* res, const char* name, const char* path, int face_index) {
    if (res->count >= res->capacity) {
        res->capacity = (res->capacity == 0) ? 256 : res->capacity * 2;
        res->entries = (C_FontEntry*)realloc(res->entries, res->capacity * sizeof(C_FontEntry));
    }
    C_FontEntry* e = &res->entries[res->count++];
    strncpy(e->full_name, name, 127);
    e->full_name[127] = '\0';
    strncpy(e->file_path, path, 259);
    e->file_path[259] = '\0';
    e->face_index = face_index;

    /* Extract family root by stripping all suffixes */
    c_get_family_root(e->full_name, e->family_root, 128);

    /* Initialize norm_name with full_name (will be processed in 2nd pass) */
    strncpy(e->norm_name, e->full_name, 127);
    e->norm_name[127] = '\0';
}

static void normalize_font_entries(C_FontScanResult* res) {
    /* 2nd Pass: Two-pass family grouping matching the original Python normalize_font_name logic */
    if (!res || res->count == 0) return;

    for (int i = 0; i < res->count; ++i) {
        const char* fam = res->entries[i].family_root;
        int fam_count = 0;

        /* Ignore empty family roots */
        if (!fam || fam[0] == '\0') continue;

        /* Count total faces belonging to this family root */
        for (int j = 0; j < res->count; ++j) {
            if (_stricmp(fam, res->entries[j].family_root) == 0) {
                fam_count++;
            }
        }

        if (fam_count == 1) {
            /* Case 1: Family has ONLY 1 face -> strip ALL suffixes (norm_name = family_root) */
            if (strlen(res->entries[i].family_root) > 0) {
                strncpy(res->entries[i].norm_name, res->entries[i].family_root, 127);
                res->entries[i].norm_name[127] = '\0';
            }
        } else {
            /* Case 2: Family has multiple faces -> strip ONLY "regular" or "-regular" */
            strncpy(res->entries[i].norm_name, res->entries[i].full_name, 127);
            res->entries[i].norm_name[127] = '\0';

            if (ends_with_case_insensitive(res->entries[i].norm_name, " regular")) {
                res->entries[i].norm_name[strlen(res->entries[i].norm_name) - 8] = '\0';
            } else if (ends_with_case_insensitive(res->entries[i].norm_name, "-regular")) {
                res->entries[i].norm_name[strlen(res->entries[i].norm_name) - 8] = '\0';
            }
        }
    }
}

int c_scan_system_fonts(FT_Library ft_lib, const char** dirs, int num_dirs, C_FontScanResult* out_result) {
    out_result->entries = NULL;
    out_result->count = 0;
    out_result->capacity = 0;

    for (int i = 0; i < num_dirs; ++i) {
        if (dirs[i] && dirs[i][0] != '\0') {
            scan_dir_recursive(ft_lib, dirs[i], out_result);
        }
    }

    /* Perform two-pass family grouping and normalization */
    normalize_font_entries(out_result);

    return out_result->count;
}

static void scan_dir_recursive_impl(FT_Library ft_lib, const char* dir_path, C_FontScanResult* out_res, int depth) {
    if (depth > 8 || !dir_path || !out_res) return;

#ifdef _WIN32
    char search_path[MAX_PATH];
    if (snprintf(search_path, MAX_PATH, "%s\\*.*", dir_path) >= MAX_PATH) return;

    WIN32_FIND_DATAA fd;
    HANDLE hFind = FindFirstFileA(search_path, &fd);
    if (hFind == INVALID_HANDLE_VALUE) return;

    do {
        if (strcmp(fd.cFileName, ".") == 0 || strcmp(fd.cFileName, "..") == 0) continue;

        char full_item_path[MAX_PATH];
        if (snprintf(full_item_path, MAX_PATH, "%s\\%s", dir_path, fd.cFileName) >= MAX_PATH) continue;

        /* Prevent infinite recursion on junctions and symlinks */
        if ((fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) && !(fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
            scan_dir_recursive_impl(ft_lib, full_item_path, out_res, depth + 1);
        } else if (is_font_extension(fd.cFileName)) {
            char font_name[128];
            size_t flen = strlen(fd.cFileName);
            if (flen >= 4 && _stricmp(fd.cFileName + flen - 4, ".ttc") == 0) {
                FT_Face tmp_face = NULL;
                if (FT_New_Face(ft_lib, full_item_path, 0, &tmp_face) == 0 && tmp_face) {
                    int num_faces = (int)tmp_face->num_faces;
                    FT_Done_Face(tmp_face);
                    for (int i = 0; i < num_faces; ++i) {
                        if (extract_face_name(ft_lib, full_item_path, i, font_name, sizeof(font_name))) {
                            add_font_entry(out_res, font_name, full_item_path, i);
                        }
                    }
                }
            } else {
                if (extract_face_name(ft_lib, full_item_path, 0, font_name, sizeof(font_name))) {
                    add_font_entry(out_res, font_name, full_item_path, -1);
                }
            }
        }
    } while (FindNextFileA(hFind, &fd));
    FindClose(hFind);
#else
    DIR* dir = opendir(dir_path);
    if (!dir) return;
    struct dirent* entry;
    char path[1024];

    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        snprintf(path, sizeof(path), "%s/%s", dir_path, entry->d_name);

        struct stat st;
        /* lstat(), NOT stat() — stat() follows symlinks, so a symlink
         * pointing back at an ancestor directory (a real-world case,
         * not just theoretical) would make S_ISDIR() true and recurse
         * into it forever (bounded only by the depth<=8 guard as a
         * last resort, which is a safety net, not a real fix). lstat()
         * reports the symlink itself, so S_ISDIR() is false for it and
         * we simply don't recurse through it — this does mean a
         * symlinked font directory (a valid, non-looping setup some
         * users might have) won't be scanned, but that's a deliberate
         * trade-off: safety from infinite recursion over completeness
         * for a fairly rare setup. */
        if (lstat(path, &st) == 0) {
            if (S_ISDIR(st.st_mode)) {
                scan_dir_recursive_impl(ft_lib, path, out_res, depth + 1);
            } else if (is_font_extension(entry->d_name)) {
                char font_name[128];
                size_t len = strlen(entry->d_name);
                if (len >= 4 && _stricmp(entry->d_name + len - 4, ".ttc") == 0) {
                    FT_Face tmp_face = NULL;
                    if (FT_New_Face(ft_lib, path, 0, &tmp_face) == 0 && tmp_face) {
                        int num_faces = (int)tmp_face->num_faces;
                        FT_Done_Face(tmp_face);
                        for (int i = 0; i < num_faces; ++i) {
                            if (extract_face_name(ft_lib, path, i, font_name, sizeof(font_name))) {
                                add_font_entry(out_res, font_name, path, i);
                            }
                        }
                    }
                } else {
                    if (extract_face_name(ft_lib, path, 0, font_name, sizeof(font_name))) {
                        add_font_entry(out_res, font_name, path, -1);
                    }
                }
            }
        }
    }
    closedir(dir);
#endif
}

static void scan_dir_recursive(FT_Library ft_lib, const char* dir_path, C_FontScanResult* out_res) {
    scan_dir_recursive_impl(ft_lib, dir_path, out_res, 0);
}

void c_free_font_scan_result(C_FontScanResult* result) {
    if (result && result->entries) {
        free(result->entries);
        result->entries = NULL;
        result->count = 0;
        result->capacity = 0;
    }
}

static int count_fonts_in_dir_impl(const char* dir_path, int depth) {
    if (depth > 8 || !dir_path) return 0;
    int total = 0;

#ifdef _WIN32
    char search_path[MAX_PATH];
    if (snprintf(search_path, MAX_PATH, "%s\\*.*", dir_path) >= MAX_PATH) return 0;

    WIN32_FIND_DATAA fd;
    HANDLE hFind = FindFirstFileA(search_path, &fd);
    if (hFind == INVALID_HANDLE_VALUE) return 0;

    do {
        if (strcmp(fd.cFileName, ".") == 0 || strcmp(fd.cFileName, "..") == 0) continue;

        char full_item_path[MAX_PATH];
        if (snprintf(full_item_path, MAX_PATH, "%s\\%s", dir_path, fd.cFileName) >= MAX_PATH) continue;

        if ((fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) && !(fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
            total += count_fonts_in_dir_impl(full_item_path, depth + 1);
        } else if (is_font_extension(fd.cFileName)) {
            total++;
        }
    } while (FindNextFileA(hFind, &fd));
    FindClose(hFind);
#else
    DIR* dir = opendir(dir_path);
    if (!dir) return 0;
    struct dirent* entry;
    char path[1024];

    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        snprintf(path, sizeof(path), "%s/%s", dir_path, entry->d_name);
        struct stat st;
        /* lstat(), not stat() — same symlink-loop reasoning as in
         * scan_dir_recursive_impl above. */
        if (lstat(path, &st) == 0) {
            if (S_ISDIR(st.st_mode)) {
                total += count_fonts_in_dir_impl(path, depth + 1);
            } else if (is_font_extension(entry->d_name)) {
                total++;
            }
        }
    }
    closedir(dir);
#endif
    return total;
}

static int count_fonts_in_dir(const char* dir_path) {
    return count_fonts_in_dir_impl(dir_path, 0);
}

int c_get_fonts_fingerprint(const char** dirs, int num_dirs, char* out_fingerprint, int max_len) {
    if (!out_fingerprint || max_len <= 0) return 0;
    out_fingerprint[0] = '\0';
    int offset = 0;

    for (int i = 0; i < num_dirs; ++i) {
        if (!dirs[i] || dirs[i][0] == '\0') continue;
        struct stat st;
        if (stat(dirs[i], &st) == 0) {
            int f_count = count_fonts_in_dir(dirs[i]);
            int written = snprintf(out_fingerprint + offset, max_len - offset, "%lld_%d|", (long long)st.st_mtime, f_count);
            if (written > 0 && offset + written < max_len) {
                offset += written;
            } else {
                break;
            }
        }
    }
    return offset;
}