#include "cbdt_render.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define FT_PIXEL_MODE_BGRA_VALUE 7
#define CBDT_PI 3.14159265358979323846

/* Lanczos-3 kernel. */
static double lanczos3(double x) {
    double px;
    if (x < 0) x = -x;
    if (x < 1e-8) return 1.0;
    if (x >= 3.0) return 0.0;
    px = CBDT_PI * x;
    return 3.0 * sin(px) * sin(px / 3.0) / (px * px);
}

/* Lanczos-3 weights for resampling n_src samples to n_dst: output i reads
 * source samples idx[i*taps .. +taps) with normalised weights wt[...]. When
 * shrinking, the kernel is widened by the shrink factor so every source pixel
 * is averaged in (no aliasing); edge samples are clamped. The table depends
 * only on the two lengths, so it is built once per axis, not per row. */
typedef struct { int taps; int* idx; float* wt; } LanczosTable;

static int lanczos_table(int n_src, int n_dst, LanczosTable* t) {
    double scale = (double)n_dst / (double)n_src;
    double fs = scale < 1.0 ? 1.0 / scale : 1.0;
    double support = 3.0 * fs;
    int i, j;
    t->taps = (int)ceil(support) * 2 + 2;
    t->idx = (int*)malloc((size_t)n_dst * t->taps * sizeof(int));
    t->wt = (float*)malloc((size_t)n_dst * t->taps * sizeof(float));
    if (!t->idx || !t->wt) { free(t->idx); free(t->wt); return 0; }
    for (i = 0; i < n_dst; i++) {
        double center = (i + 0.5) / scale - 0.5, wsum = 0;
        int lo = (int)floor(center - support);
        int* idx = t->idx + (size_t)i * t->taps;
        float* wt = t->wt + (size_t)i * t->taps;
        for (j = 0; j < t->taps; j++) {
            int s = lo + j;
            double w = lanczos3((s - center) / fs);
            idx[j] = s < 0 ? 0 : (s >= n_src ? n_src - 1 : s);
            wt[j] = (float)w;
            wsum += w;
        }
        if (wsum != 0.0)
            for (j = 0; j < t->taps; j++) wt[j] = (float)(wt[j] / wsum);
    }
    return 1;
}

/* One separable pass over premultiplied float RGBA: `src` samples (stride
 * `src_step` floats, 4 channels each) become t's n_dst samples of `dst`
 * (stride `dst_step`). */
static void lanczos_pass(const LanczosTable* t, int n_dst, const float* src, int src_step,
                         float* dst, int dst_step) {
    int i, j;
    for (i = 0; i < n_dst; i++) {
        const int* idx = t->idx + (size_t)i * t->taps;
        const float* wt = t->wt + (size_t)i * t->taps;
        float r = 0, g = 0, b = 0, a = 0;
        for (j = 0; j < t->taps; j++) {
            const float* p = src + (size_t)idx[j] * src_step;
            float w = wt[j];
            r += w * p[0]; g += w * p[1]; b += w * p[2]; a += w * p[3];
        }
        dst[(size_t)i * dst_step + 0] = r; dst[(size_t)i * dst_step + 1] = g;
        dst[(size_t)i * dst_step + 2] = b; dst[(size_t)i * dst_step + 3] = a;
    }
}

/* Premultiplied BGRA (FreeType's CBDT output) -> resized, straight RGBA.
 * Resampling has to happen while the alpha is still premultiplied: averaging
 * straight-alpha pixels pulls the black of the transparent surroundings into
 * the edge colors and leaves a dark fringe around every emoji. */
static unsigned char* bgra_premul_resize(const FT_Bitmap* bmp, int dw, int dh) {
    int sw = (int)bmp->width, sh = (int)bmp->rows, x, y, k;
    float *src = NULL, *tmp = NULL, *dst = NULL;
    unsigned char* out = NULL;
    LanczosTable tx = {0, NULL, NULL}, ty = {0, NULL, NULL};

    src = (float*)malloc((size_t)sw * sh * 4 * sizeof(float));
    tmp = (float*)malloc((size_t)dw * sh * 4 * sizeof(float));
    dst = (float*)malloc((size_t)dw * dh * 4 * sizeof(float));
    out = (unsigned char*)malloc((size_t)dw * dh * 4);
    if (!src || !tmp || !dst || !out || !lanczos_table(sw, dw, &tx) || !lanczos_table(sh, dh, &ty)) {
        free(src); free(tmp); free(dst); free(out);
        free(tx.idx); free(tx.wt); free(ty.idx); free(ty.wt);
        return NULL;
    }

    for (y = 0; y < sh; y++) {
        const unsigned char* row = bmp->buffer + y * bmp->pitch;
        for (x = 0; x < sw; x++) {
            float* p = src + ((size_t)y * sw + x) * 4;
            p[0] = row[x * 4 + 2]; p[1] = row[x * 4 + 1]; p[2] = row[x * 4 + 0]; p[3] = row[x * 4 + 3];
        }
    }
    for (y = 0; y < sh; y++)                                 /* horizontal */
        lanczos_pass(&tx, dw, src + (size_t)y * sw * 4, 4, tmp + (size_t)y * dw * 4, 4);
    for (x = 0; x < dw; x++)                                 /* vertical */
        lanczos_pass(&ty, dh, tmp + (size_t)x * 4, dw * 4, dst + (size_t)x * 4, dw * 4);
    free(tx.idx); free(tx.wt); free(ty.idx); free(ty.wt);

    for (y = 0; y < dh * dw; y++) {
        float* p = dst + (size_t)y * 4;
        double a = p[3] < 0 ? 0 : (p[3] > 255 ? 255 : p[3]);
        unsigned char* o = out + (size_t)y * 4;
        if (a < 0.5) { o[0] = o[1] = o[2] = o[3] = 0; continue; }
        for (k = 0; k < 3; k++) {
            double c = p[k] < 0 ? 0 : (p[k] > a ? a : p[k]);  /* Lanczos can overshoot */
            o[k] = (unsigned char)(c * 255.0 / a + 0.5);
        }
        o[3] = (unsigned char)(a + 0.5);
    }
    free(src); free(tmp); free(dst);
    return out;
}

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
     * resize step below always SHRINKS the bitmap rather than enlarging it.
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

    /* The strike's bitmap height rarely matches requested_size. Resize only
     * when the mismatch is over 15% (a multi-strike font like Apple Color
     * Emoji usually has a strike close enough to use 1:1, which is always
     * the crispest); otherwise shrink it here, before un-premultiplying. */
    if (requested_size > 0 && abs(h - requested_size) > (int)(requested_size * 0.15)) {
        double scale = (double)requested_size / (double)h;
        int dw = (int)(w * scale), dh = (int)(h * scale);
        if (dw < 1) dw = 1;
        if (dh < 1) dh = 1;
        canvas = bgra_premul_resize(bmp, dw, dh);
        if (!canvas) return 4;
        *out_rgba = canvas;
        *out_w = dw;
        *out_h = dh;
        *out_top = (int)(slot->bitmap_top * scale);
        *out_left = (int)(slot->bitmap_left * scale);
        return 0;
    }

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
