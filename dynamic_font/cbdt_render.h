#ifndef CBDT_RENDER_H
#define CBDT_RENDER_H

/*
 * cbdt_render.h — Renders a CBDT (embedded PNG color bitmap) glyph
 * directly via FreeType's own PNG decoder (FT_LOAD_COLOR | FT_LOAD_RENDER
 * on a face with FT_PIXEL_MODE_BGRA output).
 *
 * Requires FreeType built WITH PNG support (FT_REQUIRE_PNG=ON, linked
 * against libpng + zlib) — without this, FT_Load_Glyph on a CBDT glyph
 * fails with error 7 (Unimplemented_Feature). This is the whole reason
 * this file exists as a SEPARATE renderer from colrv0_render.c: COLRv0
 * doesn't need PNG at all (it's vector layers), CBDT is PNG bitmaps only.
 */

#include <ft2build.h>
#include FT_FREETYPE_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Renders one CBDT glyph into an RGBA bitmap (8-bit/channel, NOT
 * premultiplied — same convention as colrv0_render.c/colrv1_render.c).
 *
 * face            : an FT_Face already loaded (pixel size does NOT need
 *                   to be pre-set by the caller — see requested_size).
 * glyph_index     : the glyph's index (from FT_Get_Char_Index).
 * requested_size  : the pixel size the caller actually wants. CBDT fonts
 *                   only embed bitmaps at a FIXED set of "strike" sizes
 *                   (e.g. only 109px for some NotoColorEmoji builds) —
 *                   this function scans face->available_sizes itself and
 *                   selects the CLOSEST one via FT_Select_Size, rather
 *                   than relying on the caller having already called
 *                   FT_Set_Pixel_Sizes with an arbitrary value. That
 *                   matters because FT_Set_Pixel_Sizes on a face with NO
 *                   scalable outline (bitmap-only, as CBDT-only fonts
 *                   often are) can silently fail or misbehave for sizes
 *                   that don't closely match any embedded strike.
 * out_rgba        : (output) RGBA buffer allocated via malloc() by this
 *                   function — CALLER MUST free() it after use.
 * out_w, out_h    : (output) the actual bitmap dimensions (may differ
 *                   from requested_size — the caller is responsible for
 *                   scaling the resulting surface if exact-size output
 *                   is required).
 * out_top         : (output) device-pixel distance from the text baseline
 *                   UP to the TOP row of out_rgba (FreeType's bitmap_top).
 * out_left        : (output) device-pixel distance from the glyph's pen
 *                   position to the LEFT edge of out_rgba (bitmap_left).
 *
 * Returns: 0 on success, non-zero on error:
 *   1 = FT_Load_Glyph failed (font has no CBDT, or PNG support missing —
 *       error 7 specifically means FreeType was built without PNG)
 *   2 = glyph loaded but isn't a color bitmap (pixel_mode != BGRA)
 *   3 = zero-sized bitmap
 *   4 = memory allocation failure
 *   5 = face has no embedded bitmap strikes at all (not a CBDT font)
 */
int render_cbdt_glyph(
    FT_Face face,
    FT_UInt glyph_index,
    int requested_size,
    unsigned char** out_rgba,
    int* out_w,
    int* out_h,
    int* out_top,
    int* out_left
);

#ifdef __cplusplus
}
#endif

#endif /* CBDT_RENDER_H */
