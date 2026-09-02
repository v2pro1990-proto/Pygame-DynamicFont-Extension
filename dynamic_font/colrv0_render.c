#include "colrv0_render.h"
#include <stdlib.h>
#include <string.h>
#include FT_SYNTHESIS_H  /* FT_GlyphSlot_Oblique — same header the .pyx
                           * already uses for regular (non-color) glyphs,
                           * via "freetype/ftsynth.h" */

#define COLRV0_MAX_LAYERS 32   /* Real-world COLRv0 rarely exceeds a few layers/glyph */

/* One rendered layer's own copy — separated from the glyph slot because
 * the slot gets overwritten the moment FreeType loads the next layer. */
typedef struct {
    unsigned char* buf;
    int width, rows, pitch;
    int left, top;              /* bitmap_left / bitmap_top straight from FreeType */
    unsigned char r, g, b, a;   /* color from the CPAL table for this layer */
} ColrLayer;

int render_colrv0_glyph(
    FT_Face face,
    FT_UInt glyph_index,
    int apply_italic,
    unsigned char** out_rgba,
    int* out_w,
    int* out_h,
    int* out_top,
    int* out_left
) {
    FT_LayerIterator iterator;
    FT_UInt layer_glyph_index;
    FT_UInt layer_color_index;
    FT_Color* palette = NULL;
    FT_Error err;
    ColrLayer layers[COLRV0_MAX_LAYERS];
    int n_layers = 0;
    int min_left, max_right, max_top, min_bottom;
    int canvas_w, canvas_h;
    unsigned char* canvas;
    int i;

    *out_rgba = NULL;
    *out_w = 0;
    *out_h = 0;
    *out_top = 0;
    *out_left = 0;

    /* Select the default palette (index 0). Font has no CPAL, or
     * FreeType was built without TT_CONFIG_OPTION_COLOR_LAYERS -> fail. */
    err = FT_Palette_Select(face, 0, &palette);
    if (err || palette == NULL) {
        return 1;
    }

    iterator.p = NULL;
    if (!FT_Get_Color_Glyph_Layer(face, glyph_index, &layer_glyph_index,
                                   &layer_color_index, &iterator)) {
        return 2;  /* This glyph has no color layer (not COLRv0) */
    }

    min_left = 1000000; max_right = -1000000;
    max_top  = -1000000; min_bottom = 1000000;

    /* --- PASS 1: render each layer, copy its buffer, accumulate the bounding box --- */
    do {
        FT_GlyphSlot slot;
        FT_Bitmap* bmp;
        int buf_size;
        unsigned char* copy;

        if (n_layers >= COLRV0_MAX_LAYERS) break;

        /* Split into two steps (load outline, then render) instead of
         * the single FT_LOAD_RENDER flag — FT_GlyphSlot_Oblique only
         * works on an unrasterized outline, so it MUST run between
         * these two calls. FT_LOAD_RENDER would rasterize immediately,
         * leaving no outline left to slant by the time apply_italic is
         * checked. */
        err = FT_Load_Glyph(face, layer_glyph_index, FT_LOAD_NO_HINTING);
        if (err) continue;

        if (apply_italic) {
            /* Only meaningful on a scalable outline (FT_GLYPH_FORMAT_OUTLINE);
             * a layer that's itself bitmap-only (unusual but not
             * impossible for a mixed-format font) has nothing to slant —
             * FT_GlyphSlot_Oblique is a no-op in that case rather than an
             * error, so no separate format check is needed here. */
            FT_GlyphSlot_Oblique(face->glyph);
        }

        err = FT_Render_Glyph(face->glyph, FT_RENDER_MODE_NORMAL);
        if (err) continue;

        slot = face->glyph;
        bmp  = &slot->bitmap;
        if (bmp->width == 0 || bmp->rows == 0) continue;

        buf_size = bmp->pitch * (int)bmp->rows;
        if (buf_size < 0) buf_size = -buf_size;

        copy = (unsigned char*)malloc((size_t)buf_size);
        if (!copy) continue;
        memcpy(copy, bmp->buffer, (size_t)buf_size);

        layers[n_layers].buf   = copy;
        layers[n_layers].width = (int)bmp->width;
        layers[n_layers].rows  = (int)bmp->rows;
        layers[n_layers].pitch = bmp->pitch;
        layers[n_layers].left  = slot->bitmap_left;
        layers[n_layers].top   = slot->bitmap_top;

        /* 0xFFFF = "use the caller's default text color" per the COLR
         * spec — this reference implementation hardcodes black for now;
         * a fully correct version would let the caller pass a foreground
         * color and use it here instead. */
        if (layer_color_index == 0xFFFF) {
            layers[n_layers].r = 0;
            layers[n_layers].g = 0;
            layers[n_layers].b = 0;
            layers[n_layers].a = 255;
        } else {
            FT_Color c = palette[layer_color_index];
            layers[n_layers].r = c.red;
            layers[n_layers].g = c.green;
            layers[n_layers].b = c.blue;
            layers[n_layers].a = c.alpha;
        }

        if (slot->bitmap_left < min_left)
            min_left = slot->bitmap_left;
        if (slot->bitmap_left + (int)bmp->width > max_right)
            max_right = slot->bitmap_left + (int)bmp->width;
        if (slot->bitmap_top > max_top)
            max_top = slot->bitmap_top;
        if (slot->bitmap_top - (int)bmp->rows < min_bottom)
            min_bottom = slot->bitmap_top - (int)bmp->rows;

        n_layers++;
    } while (FT_Get_Color_Glyph_Layer(face, glyph_index, &layer_glyph_index,
                                       &layer_color_index, &iterator));

    if (n_layers == 0) return 3;

    canvas_w = max_right - min_left;
    canvas_h = max_top - min_bottom;
    if (canvas_w <= 0 || canvas_h <= 0) {
        for (i = 0; i < n_layers; i++) free(layers[i].buf);
        return 4;
    }

    canvas = (unsigned char*)calloc((size_t)(canvas_w * canvas_h * 4), 1);
    if (!canvas) {
        for (i = 0; i < n_layers; i++) free(layers[i].buf);
        return 5;
    }

    /* --- PASS 2: Porter-Duff "over" composite each layer onto the canvas --- */
    for (i = 0; i < n_layers; i++) {
        int ox = layers[i].left - min_left;
        int oy = max_top - layers[i].top;
        int row, col;

        for (row = 0; row < layers[i].rows; row++) {
            for (col = 0; col < layers[i].width; col++) {
                int src_idx, px, py, a, inv_a, out_a, cidx;
                unsigned char src_a8, dr, dg, db, da;

                src_idx = row * layers[i].pitch + col;  /* grayscale coverage */
                src_a8 = layers[i].buf[src_idx];
                if (src_a8 == 0) continue;

                px = ox + col;
                py = oy + row;
                if (px < 0 || px >= canvas_w || py < 0 || py >= canvas_h) continue;

                a = (src_a8 * layers[i].a) / 255;
                if (a == 0) continue;

                cidx = (py * canvas_w + px) * 4;
                dr = canvas[cidx];
                dg = canvas[cidx + 1];
                db = canvas[cidx + 2];
                da = canvas[cidx + 3];

                inv_a = 255 - a;
                out_a = a + (da * inv_a) / 255;
                if (out_a == 0) continue;

                canvas[cidx]     = (unsigned char)((layers[i].r * a + dr * (inv_a * da / 255)) / out_a);
                canvas[cidx + 1] = (unsigned char)((layers[i].g * a + dg * (inv_a * da / 255)) / out_a);
                canvas[cidx + 2] = (unsigned char)((layers[i].b * a + db * (inv_a * da / 255)) / out_a);
                canvas[cidx + 3] = (unsigned char)out_a;
            }
        }
        free(layers[i].buf);
    }

    *out_rgba = canvas;
    *out_w = canvas_w;
    *out_h = canvas_h;
    *out_top = max_top;   /* device-pixel distance from baseline to this canvas's top row */
    *out_left = min_left; /* device-pixel distance from pen position to this canvas's left edge */
    return 0;
}
