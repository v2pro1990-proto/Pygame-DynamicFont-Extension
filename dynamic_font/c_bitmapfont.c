#include "c_bitmapfont.h"
#include <stdlib.h>
#include <string.h>

#define DFBMP_SUPPORTED_VERSION 3
#define DFBMP_HEADER_SIZE 18   /* magic(4) + version(2) + glyph_count(4) + cell_w(2) + cell_h(2) + baseline(2) + gap(2) */
#define DFBMP_TABLE_ENTRY_SIZE 4   /* codepoint(4) */

/* Little-endian reads byte by byte: correct on any host byte order and at
 * any (unaligned) offset. */
static uint16_t read_u16le(const unsigned char* p) {
    return (uint16_t)(p[0] | (p[1] << 8));
}
static uint32_t read_u32le(const unsigned char* p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

DfbmpFont* dfbmp_load_memory(const unsigned char* data, long size) {
    unsigned char* file_data;
    DfbmpFont* font;
    uint32_t glyph_count, i;
    uint16_t cell_w, cell_h, baseline, gap;
    long glyph_bytes, table_end;

    if (!data || size < DFBMP_HEADER_SIZE) return NULL;
    if (memcmp(data, "DFBM", 4) != 0) return NULL;
    if (read_u16le(data + 4) != DFBMP_SUPPORTED_VERSION) return NULL;

    glyph_count = read_u32le(data + 6);
    cell_w = read_u16le(data + 10);
    cell_h = read_u16le(data + 12);
    baseline = read_u16le(data + 14);
    gap = read_u16le(data + 16);
    if (cell_w == 0 || cell_h == 0 || baseline > cell_h || gap > 255) return NULL;

    glyph_bytes = ((long)cell_w * cell_h + 7) / 8;
    table_end = DFBMP_HEADER_SIZE + (long)glyph_count * DFBMP_TABLE_ENTRY_SIZE;
    /* The file must be exactly header + table + bitmaps: anything else is
     * a truncated or corrupt file (checked with division, no overflow). */
    if (table_end > size || (size - table_end) / glyph_bytes != (long)glyph_count
            || (size - table_end) % glyph_bytes != 0) {
        return NULL;
    }

    file_data = (unsigned char*)malloc((size_t)size);
    if (!file_data) return NULL;
    memcpy(file_data, data, (size_t)size);

    font = (DfbmpFont*)malloc(sizeof(DfbmpFont));
    if (!font) { free(file_data); return NULL; }
    font->glyphs = (DfbmpGlyphEntry*)malloc(sizeof(DfbmpGlyphEntry) * (glyph_count ? glyph_count : 1));
    if (!font->glyphs) { free(font); free(file_data); return NULL; }

    for (i = 0; i < glyph_count; i++) {
        font->glyphs[i].codepoint = read_u32le(file_data + DFBMP_HEADER_SIZE + (long)i * DFBMP_TABLE_ENTRY_SIZE);
        font->glyphs[i].bits = file_data + table_end + (long)i * glyph_bytes;
    }
    font->file_data = file_data;
    font->file_size = size;
    font->glyph_count = glyph_count;
    font->cell_w = cell_w;
    font->cell_h = cell_h;
    font->baseline = baseline;
    font->gap = gap;
    return font;
}

void dfbmp_free(DfbmpFont* font) {
    if (!font) return;
    free(font->glyphs);
    free(font->file_data);
    free(font);
}
