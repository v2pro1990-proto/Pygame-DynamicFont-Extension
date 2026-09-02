#include "cbdt_render.h"
#include <stdlib.h>
#include <string.h>

#define FT_PIXEL_MODE_BGRA_VALUE 7

int render_cbdt_glyph(
    FT_Face face,
    FT_UInt glyph_index,
    int requested_size,
    unsigned char** out_rgba,
    int* out_w,
    int* out_h,
    int* out_top,
    int* out_left
) {
    FT_Error err;
    FT_GlyphSlot slot;
    FT_Bitmap* bmp;
    unsigned char* canvas;
    int w, h, row, col;
    int i, best_index, larger_h = 0, cur_h;

    *out_rgba = NULL;
    *out_w = 0;
    *out_h = 0;
    *out_top = 0;
    *out_left = 0;

    /* CBDT fonts embed bitmaps at a FIXED set of "strike" sizes only —
     * scan face->available_sizes ourselves and pick one, rather than
     * trusting a prior FT_Set_Pixel_Sizes(face, 0, size) call to have
     * picked correctly. FT_Set_Pixel_Sizes on a face with no scalable
     * outline (bitmap-only, common for CBDT-only fonts) can silently
     * misbehave for sizes that don't closely match any strike — this is
     * what caused "works at size=20, nothing at size=24/30" in practice:
     * FreeType's own strike-matching heuristic isn't guaranteed to
     * succeed the same way FT_Select_Size's direct, explicit selection
     * does. */
    if (face->num_fixed_sizes <= 0) return 5;

    /* Prefer the SMALLEST strike that is >= requested_size, so the
     * caller's later smoothscale step (see the .pyx render_cbdt_*
     * functions) always SHRINKS the bitmap rather than enlarging it.
     * Downscaling a bitmap looks crisp (effectively averaging existing
     * detail down); upscaling has to invent pixels that were never
     * there and always looks soft/blurry by comparison — this is why
     * picking the NUMERICALLY closest strike (the old approach, e.g.
     * picking a 20px strike over a 32px one for a 25px request just
     * because |20-25| < |32-25|) produced visibly worse quality than
     * picking the strike on the other side of the request, even though
     * it's numerically "farther". If requested_size is larger than
     * EVERY available strike, there's no larger option to fall back on
     * — in that case we still have to enlarge, so just pick the LARGEST
     * available strike (minimizes the enlargement ratio, the best that
     * can be done). */
    best_index = -1;
    for (i = 0; i < face->num_fixed_sizes; i++) {
        cur_h = (int)face->available_sizes[i].height;
        if (cur_h >= requested_size) {
            if (best_index == -1 || cur_h < larger_h) {
                best_index = i;
                larger_h = cur_h;
            }
        }
    }
    if (best_index == -1) {
        /* requested_size exceeds every strike — pick the largest one. */
        best_index = 0;
        for (i = 1; i < face->num_fixed_sizes; i++) {
            if ((int)face->available_sizes[i].height >
                (int)face->available_sizes[best_index].height) {
                best_index = i;
            }
        }
    }
    if (FT_Select_Size(face, best_index) != 0) return 5;

    /* FT_LOAD_COLOR is what makes FreeType look for/decode an embedded
     * CBDT (PNG-compressed) bitmap instead of a vector outline. Requires
     * FreeType built WITH PNG support — without it, this returns error 7
     * (Unimplemented_Feature) for any glyph that only has a CBDT bitmap
     * and no vector outline fallback. */
    err = FT_Load_Glyph(face, glyph_index, FT_LOAD_RENDER | FT_LOAD_COLOR);
    if (err) return 1;

    slot = face->glyph;
    bmp  = &slot->bitmap;

    if (bmp->pixel_mode != FT_PIXEL_MODE_BGRA_VALUE) {
        /* Not a color bitmap glyph (e.g. FT_LOAD_COLOR found nothing and
         * fell back to a grayscale outline instead) — nothing for THIS
         * renderer to do, caller should fall back to COLRv0/pygame.font. */
        return 2;
    }
    if (bmp->width == 0 || bmp->rows == 0) return 3;

    w = (int)bmp->width;
    h = (int)bmp->rows;

    canvas = (unsigned char*)malloc((size_t)(w * h * 4));
    if (!canvas) return 4;

    /* Source is BGRA, PRE-MULTIPLIED alpha (confirmed in FreeType's own
     * docs: "full red at half-translucent opacity is 00,00,80,80, not
     * 00,00,FF,80"). Convert to RGBA, UN-premultiplied — matching the
     * convention colrv0_render.c/colrv1_render.c already use, and what
     * pygame's SRCALPHA surfaces expect (straight alpha, not premultiplied
     * — feeding premultiplied data in directly would make partially
     * transparent pixels render too dark/muddy). */
    for (row = 0; row < h; row++) {
        unsigned char* src_row = bmp->buffer + row * bmp->pitch;
        for (col = 0; col < w; col++) {
            unsigned char b = src_row[col * 4 + 0];
            unsigned char g = src_row[col * 4 + 1];
            unsigned char r = src_row[col * 4 + 2];
            unsigned char a = src_row[col * 4 + 3];
            int dst_idx = (row * w + col) * 4;

            if (a == 0) {
                canvas[dst_idx]     = 0;
                canvas[dst_idx + 1] = 0;
                canvas[dst_idx + 2] = 0;
                canvas[dst_idx + 3] = 0;
            } else {
                /* Un-premultiply: straight = premultiplied * 255 / alpha */
                canvas[dst_idx]     = (unsigned char)((r * 255 + a / 2) / a);
                canvas[dst_idx + 1] = (unsigned char)((g * 255 + a / 2) / a);
                canvas[dst_idx + 2] = (unsigned char)((b * 255 + a / 2) / a);
                canvas[dst_idx + 3] = a;
            }
        }
    }

    *out_rgba = canvas;
    *out_w = w;
    *out_h = h;
    *out_top = slot->bitmap_top;
    *out_left = slot->bitmap_left;
    return 0;
}
