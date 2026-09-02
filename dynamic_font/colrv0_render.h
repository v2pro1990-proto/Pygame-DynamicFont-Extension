#ifndef COLRV0_RENDER_H
#define COLRV0_RENDER_H

/*
 * colrv0_render.h — Renders a COLRv0 (multi-layer color) glyph directly
 * via the FreeType C API (FT_Get_Color_Glyph_Layer + FT_Palette_Select),
 * bypassing pygame.font entirely.
 *
 * Requires FreeType >= 2.10 built with TT_CONFIG_OPTION_COLOR_LAYERS
 * (on by default in most distro/official builds, but not guaranteed for
 * every FreeType bundled with pygame — verify separately if unsure).
 */

#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_COLOR_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Renders one COLRv0 glyph into an RGBA bitmap (8-bit/channel, NOT
 * premultiplied).
 *
 * face         : an FT_Face already loaded, with pixel size/char size set.
 * glyph_index  : the base glyph's index (from FT_Get_Char_Index).
 * apply_italic : non-zero applies a synthetic oblique slant to EACH layer's
 *                outline before rasterizing — the same visual effect
 *                FT_GlyphSlot_Oblique gives regular (non-color) glyphs.
 *                Only meaningful for layers that actually have a scalable
 *                outline; CBDT-style embedded bitmaps have no vector data
 *                to slant, which is a separate, unrelated code path
 *                (cbdt_render.c) and unaffected by this flag.
 * out_rgba     : (output) RGBA buffer allocated via malloc() by this
 *                function — CALLER MUST free() it after use.
 * out_w, out_h : (output) the actual bitmap dimensions.
 * out_top      : (output) device-pixel distance from the text baseline UP
 *                to the TOP row of out_rgba (same convention as
 *                FreeType's own bitmap_top) — needed by the caller to
 *                position this bitmap correctly, since it's a TIGHT crop
 *                around the glyph's actual ink and its top edge does NOT
 *                necessarily sit at the font's ascent line (e.g. a
 *                composite ligature sub-part positioned below the main
 *                shape, as seen with Segoe UI Emoji's family glyphs).
 * out_left     : (output) device-pixel distance from the glyph's pen
 *                position (x=0) to the LEFT edge of out_rgba (same
 *                convention as FreeType's own bitmap_left) — the
 *                horizontal counterpart of out_top, needed for the same
 *                reason: this is a tight crop, so its left edge does NOT
 *                necessarily sit at the pen position.
 *
 * Returns: 0 on success, non-zero on error (font has no COLR, glyph has
 * no color layer, or a memory allocation failure).
 */
int render_colrv0_glyph(
    FT_Face face,
    FT_UInt glyph_index,
    int apply_italic,
    unsigned char** out_rgba,
    int* out_w,
    int* out_h,
    int* out_top,
    int* out_left
);

#ifdef __cplusplus
}
#endif

#endif /* COLRV0_RENDER_H */
