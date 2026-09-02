#ifndef COLRV1_RENDER_H
#define COLRV1_RENDER_H

/*
 * colrv1_render.h — Renders COLRv1 glyphs.
 *
 * Supported paint graph nodes: PaintColrLayers, PaintGlyph, PaintSolid,
 *   PaintLinearGradient, PaintRadialGradient, PaintSweepGradient,
 *   PaintTransform, PaintTranslate, PaintScale, PaintComposite (SRC_OVER
 *   and DEST_OVER modes via sequential compositing; SRC_IN via isolated
 *   buffer intersection, including the bare-PaintSolid special cases for
 *   both source and backdrop).
 * NOT supported (returns code 3, caller falls back cleanly):
 *   PaintRotate/Skew (and their AroundCenter variants), PaintColrGlyph,
 *   PaintComposite modes other than SRC_OVER/DEST_OVER/SRC_IN.
 *
 * Design principle: if ANY unsupported paint type is encountered ANYWHERE
 * in the paint graph — even after some layers were already collected — the
 * WHOLE render is aborted (nothing partial is returned). A glyph is either
 * rendered fully correctly, or not rendered at all by this function; never
 * partially/incorrectly. The caller is expected to fall back to COLRv0 or
 * pygame.font when this returns anything other than 0.
 *
 * Requires FreeType built with FT_CONFIG_OPTION_USE_COLOR (same requirement
 * as colrv0_render.c) — no additional build dependency beyond that.
 */

#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_COLOR_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * apply_italic: non-zero applies a synthetic oblique slant to EVERY
 * PaintGlyph leaf's outline in the paint graph before rasterizing —
 * propagated automatically to nested subtrees (gradient fills, composite
 * source/backdrop) since it lives on the shared ColrV1Ctx, not passed
 * per-call. See colrv0_render.h's own apply_italic for the same
 * reasoning applied to the simpler COLRv0 format.
 *
 * Return codes:
 *   0 = success
 *   1 = font has no CPAL palette (FT_Palette_Select failed)
 *   2 = glyph has no COLRv1 paint at all (not a COLRv1 glyph)
 *   3 = paint graph uses an unsupported feature (gradient/transform/
 *       composite/colr_glyph) — caller should fall back to COLRv0/pygame.font
 *   4 = paint graph resolved but produced zero renderable layers
 *   5 = computed bounding box is invalid
 *   6 = memory allocation failure
 *
 * out_top: device-pixel distance from the text baseline UP to the TOP row
 * of out_rgba (same convention as FreeType's own bitmap_top). The caller
 * needs this for correct positioning — the canvas is a TIGHT crop around
 * the glyph's actual ink, so its top edge does NOT necessarily sit at the
 * font's ascent line (a ligature sub-part positioned below the main shape
 * is a real, observed case — Segoe UI Emoji's multi-piece family glyphs).
 * out_left: device-pixel distance from the glyph's pen position (x=0) to
 * the LEFT edge of out_rgba (same convention as FreeType's bitmap_left) —
 * the horizontal counterpart of out_top, needed for the same reason.
 */
int render_colrv1_glyph(
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

#endif /* COLRV1_RENDER_H */
