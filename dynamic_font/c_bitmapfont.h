#ifndef C_BITMAPFONT_H
#define C_BITMAPFONT_H

/*
 * c_bitmapfont.h — Loads .dfbmp bitmap font files (made with
 * dfbmp_builder.html).
 *
 * A .dfbmp font is a FIXED-CELL font, as on the calculator / LCD screens
 * these fonts come from: every glyph is exactly cell_w x cell_h pixels (one
 * bit per pixel at 1x), and neighbouring cells are `gap` empty pixels apart
 * — the pen moves cell_w + gap per character.
 *
 * .dfbmp v3 file layout (little-endian throughout):
 *   Header (18 bytes):
 *     magic[4]      "DFBM"
 *     version       uint16  (must be 3 — v2 files, which had per-glyph
 *                            box sizes, are converted by the builder's
 *                            "Open .dfbmp")
 *     glyph_count   uint32
 *     cell_w        uint16  every glyph's width, in pixels
 *     cell_h        uint16  every glyph's height, in pixels
 *     baseline      uint16  rows from the top of the cell down to the
 *                           baseline (ink above it: rows 0..baseline-1;
 *                           descenders below it)
 *     gap           uint16  empty pixels between neighbouring cells
 *   Glyph table (glyph_count * 4 bytes):
 *     codepoint     uint32
 *   Bitmap data (glyph_count * ceil(cell_w*cell_h/8) bytes, in glyph-table
 *   order, each glyph starting on its own byte):
 *     1 bit per pixel, row-major, MSB-first within each byte.
 *     Bit value 1 = ink (opaque), 0 = empty (transparent).
 *
 * Color is applied by the engine (the bits are coverage), exactly as for
 * FreeType's glyph bitmaps — render()'s color, tags and gradients work the
 * same way for both.
 */

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t codepoint;
    const unsigned char* bits;  /* points into DfbmpFont's own file_data —
                                  * valid as long as the font is alive */
} DfbmpGlyphEntry;

typedef struct {
    unsigned char* file_data;    /* the whole file, kept in memory */
    long file_size;
    uint32_t glyph_count;
    uint16_t cell_w;
    uint16_t cell_h;
    uint16_t baseline;
    uint16_t gap;
    DfbmpGlyphEntry* glyphs;     /* glyph_count entries, in file order */
} DfbmpFont;

/*
 * Parses a .dfbmp v3 file already read into memory (size bytes at data,
 * copied — the caller opens the file itself, since fopen() can't open
 * non-ASCII paths on Windows). Returns NULL on any failure: bad magic,
 * version other than 3, zero cell size, baseline outside the cell, a gap
 * over 255, file size not matching the header, or out of memory.
 */
DfbmpFont* dfbmp_load_memory(const unsigned char* data, long size);

/* Frees everything dfbmp_load_memory() allocated. Safe with NULL. */
void dfbmp_free(DfbmpFont* font);

#ifdef __cplusplus
}
#endif

#endif /* C_BITMAPFONT_H */
