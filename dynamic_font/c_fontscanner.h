#ifndef C_FONTSCANNER_H
#define C_FONTSCANNER_H

#include <stdint.h>
#include <ft2build.h>
#include FT_FREETYPE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char full_name[128];
    char family_root[128];
    char norm_name[128];
    char file_path[260];
    int face_index;     /* -1 for single TTF/OTF, 0..N-1 for TTC face index */
} C_FontEntry;

typedef struct {
    C_FontEntry* entries;
    int count;
    int capacity;
} C_FontScanResult;

/* Computes directory modification timestamp and font file count fingerprint */
int c_get_fonts_fingerprint(const char** dirs, int num_dirs, char* out_fingerprint, int max_len);

/* Scans font directories recursively and extracts all font faces via FreeType */
int c_scan_system_fonts(FT_Library ft_lib, const char** dirs, int num_dirs, C_FontScanResult* out_result);

/* Frees allocated memory in C_FontScanResult */
void c_free_font_scan_result(C_FontScanResult* result);

/* Strips style suffix from font name (e.g. "Arial Bold Italic" -> "Arial") */
void c_get_family_root(const char* font_name, char* out_root, int max_len);

#ifdef __cplusplus
}
#endif

#endif /* C_FONTSCANNER_H */