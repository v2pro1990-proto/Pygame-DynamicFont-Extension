#include "colrv1_render.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include FT_SYNTHESIS_H  /* FT_GlyphSlot_Oblique — same header colrv0_render.c uses */

/* M_PI is a POSIX extension, not standard C — GCC/Linux define it via
 * math.h automatically, but MSVC does NOT unless _USE_MATH_DEFINES is set
 * before including math.h (and that's fragile to rely on from a build
 * script). Define it manually as a fallback so this compiles cleanly on
 * both toolchains without needing any extra compiler flag. */
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define COLRV1_MAX_LAYERS 64   /* generous headroom over COLRv0's 32 — v1 graphs can be deeper */
#define COLRV1_MAX_DEPTH  16   /* guards against malformed/cyclic paint graphs */
#define COLRV1_MAX_STOPS  16   /* color stops per gradient — generous for real-world fonts */

typedef enum { PAINT_KIND_SOLID, PAINT_KIND_LINEAR_GRADIENT, PAINT_KIND_RADIAL_GRADIENT, PAINT_KIND_SWEEP_GRADIENT, PAINT_KIND_PRERENDERED } PaintKind;

typedef struct {
    double offset;   /* 0.0-1.0 typically, can exceed range with repeat/reflect */
    unsigned char r, g, b, a;
} GradientStop;

/* One rendered PaintGlyph leaf. Either a flat solid color, or a gradient
 * sampled per-pixel at composite time. */
typedef struct {
    unsigned char* buf;
    int width, rows, pitch;
    int left, top;

    PaintKind kind;

    /* PAINT_KIND_SOLID: */
    unsigned char r, g, b, a;

    /* PAINT_KIND_LINEAR_GRADIENT: p0/p1 in the SAME device-pixel space as
     * left/top/bitmap (valid because render_colrv1_glyph uses
     * FT_COLOR_NO_ROOT_TRANSFORM — see comment at the call site). p2 (the
     * COLRv1 "skew" reference point) is deliberately NOT used — this
     * implementation only supports axis-aligned interpolation along
     * p0->p1, not the full skewed basis change. Real-world fonts rarely
     * skew gradients, so this covers the large majority of cases. */
    double p0x, p0y, p1x, p1y;

    /* PAINT_KIND_RADIAL_GRADIENT: two-circle model (c0,r0) -> (c1,r1),
     * same "two circle" definition CSS/SVG radial gradients use. Solved
     * per-pixel via the standard quadratic (see radial_gradient_color_at). */
    double c0x, c0y, r0, c1x, c1y, r1;

    /* PAINT_KIND_SWEEP_GRADIENT: center + start/end angle in degrees
     * (converted from the font's normalized -1..1 == -180..180 form). */
    double sweep_cx, sweep_cy, start_angle_deg, end_angle_deg;

    int extend;   /* FT_PaintExtend: 0=PAD, 1=REPEAT, 2=REFLECT */
    GradientStop stops[COLRV1_MAX_STOPS];
    int n_stops;
} ColrV1Layer;

/* Shared state threaded through the recursive paint graph walk. */
typedef struct {
    FT_Face face;
    FT_Color* palette;
    ColrV1Layer layers[COLRV1_MAX_LAYERS];
    int n_layers;
    int unsupported;   /* set the moment any unsupported paint type is seen */
    int apply_italic;  /* forwarded to every PaintGlyph leaf's FT_Load_Glyph
                         * — see process_paint's FT_COLR_PAINTFORMAT_GLYPH
                         * case for where this actually takes effect */
} ColrV1Ctx;


static void solid_color_from_index(
    ColrV1Ctx* ctx, FT_ColorIndex* ci,
    unsigned char* r, unsigned char* g, unsigned char* b, unsigned char* a
) {
    FT_UInt16 idx = ci->palette_index;
    FT_F2Dot14 alpha = ci->alpha;  /* 2.14 fixed point, 1.0 == 0x4000 */
    int a16;

    if (idx == 0xFFFF) {
        /* 0xFFFF means "use the caller's foreground color" per the COLR
         * spec — this reference implementation has no foreground color
         * parameter (same simplification colrv0_render.c makes), so it
         * falls back to black. */
        *r = 0; *g = 0; *b = 0;
    } else {
        FT_Color c = ctx->palette[idx];
        *r = c.red; *g = c.green; *b = c.blue;
    }

    a16 = (alpha * 255) / 16384;
    if (a16 < 0)   a16 = 0;
    if (a16 > 255) a16 = 255;
    *a = (unsigned char)a16;
}

static void extract_solid_color(
    ColrV1Ctx* ctx, FT_PaintSolid* solid,
    unsigned char* r, unsigned char* g, unsigned char* b, unsigned char* a
) {
    solid_color_from_index(ctx, &solid->color, r, g, b, a);
}

/* Reads all color stops of a linear gradient into layer->stops[]. Returns
 * 1 on success, 0 if there were more stops than COLRV1_MAX_STOPS (treated
 * as unsupported by the caller — better to abort than draw a truncated
 * gradient). */
static int extract_linear_gradient(ColrV1Ctx* ctx, FT_PaintLinearGradient* lg, ColrV1Layer* layer) {
    FT_ColorStopIterator iter = lg->colorline.color_stop_iterator;
    FT_ColorStop stop;
    double scale;

    /* p0/p1 come back in FT_Fixed (16.16) FONT UNITS — the SAME raw
     * coordinate system as the glyph outline before scaling, NOT
     * already-scaled device pixels. The rendered glyph bitmap (from
     * FT_Load_Glyph at the current FT_Size) IS in device pixels, so the
     * gradient points must be scaled by (ppem / units_per_em) to land in
     * the same space before use. */
    scale = (double)ctx->face->size->metrics.y_ppem / (double)ctx->face->units_per_EM;

    layer->kind = PAINT_KIND_LINEAR_GRADIENT;
    layer->p0x = ((double)lg->p0.x / 65536.0) * scale;
    layer->p0y = ((double)lg->p0.y / 65536.0) * scale;
    layer->p1x = ((double)lg->p1.x / 65536.0) * scale;
    layer->p1y = ((double)lg->p1.y / 65536.0) * scale;
    layer->extend = (int)lg->colorline.extend;
    layer->n_stops = 0;

    while (FT_Get_Colorline_Stops(ctx->face, &stop, &iter)) {
        unsigned char r, g, b, a;
        if (layer->n_stops >= COLRV1_MAX_STOPS) return 0;
        solid_color_from_index(ctx, &stop.color, &r, &g, &b, &a);
        layer->stops[layer->n_stops].offset = (double)stop.stop_offset / 65536.0;  /* 16.16 fixed, already 0.0-1.0 ratio */
        layer->stops[layer->n_stops].r = r;
        layer->stops[layer->n_stops].g = g;
        layer->stops[layer->n_stops].b = b;
        layer->stops[layer->n_stops].a = a;
        layer->n_stops++;
    }
    return layer->n_stops > 0;
}

/* Samples a gradient's stop list at parameter t (already extend-adjusted
 * into a sane range), linearly interpolating between the bracketing
 * stops. */
static void sample_gradient(ColrV1Layer* layer, double t,
                             unsigned char* r, unsigned char* g,
                             unsigned char* b, unsigned char* a) {
    int i;
    if (layer->n_stops == 1 || t <= layer->stops[0].offset) {
        *r = layer->stops[0].r; *g = layer->stops[0].g;
        *b = layer->stops[0].b; *a = layer->stops[0].a;
        return;
    }
    if (t >= layer->stops[layer->n_stops - 1].offset) {
        i = layer->n_stops - 1;
        *r = layer->stops[i].r; *g = layer->stops[i].g;
        *b = layer->stops[i].b; *a = layer->stops[i].a;
        return;
    }
    for (i = 0; i < layer->n_stops - 1; i++) {
        double o0 = layer->stops[i].offset, o1 = layer->stops[i + 1].offset;
        if (t >= o0 && t <= o1) {
            double span = o1 - o0;
            double f = (span > 1e-9) ? (t - o0) / span : 0.0;
            *r = (unsigned char)(layer->stops[i].r + (layer->stops[i + 1].r - layer->stops[i].r) * f);
            *g = (unsigned char)(layer->stops[i].g + (layer->stops[i + 1].g - layer->stops[i].g) * f);
            *b = (unsigned char)(layer->stops[i].b + (layer->stops[i + 1].b - layer->stops[i].b) * f);
            *a = (unsigned char)(layer->stops[i].a + (layer->stops[i + 1].a - layer->stops[i].a) * f);
            return;
        }
    }
    /* Shouldn't reach here given the range checks above; fall back to last stop. */
    i = layer->n_stops - 1;
    *r = layer->stops[i].r; *g = layer->stops[i].g;
    *b = layer->stops[i].b; *a = layer->stops[i].a;
}

/* Computes the gradient color at device-pixel position (px, py), applying
 * the PAD/REPEAT/REFLECT extend mode to the raw projection parameter. */
static void gradient_color_at(ColrV1Layer* layer, double px, double py,
                               unsigned char* r, unsigned char* g,
                               unsigned char* b, unsigned char* a) {
    double vx = layer->p1x - layer->p0x;
    double vy = layer->p1y - layer->p0y;
    double len2 = vx * vx + vy * vy;
    double t;

    if (len2 < 1e-9) {
        t = 0.0;
    } else {
        t = ((px - layer->p0x) * vx + (py - layer->p0y) * vy) / len2;
    }

    if (layer->extend == 1) {         /* REPEAT */
        t = t - floor(t);
    } else if (layer->extend == 2) {  /* REFLECT */
        double tt = fmod(t, 2.0);
        if (tt < 0.0) tt += 2.0;
        t = (tt <= 1.0) ? tt : 2.0 - tt;
    } else {                          /* PAD (default) */
        if (t < 0.0) t = 0.0;
        if (t > 1.0) t = 1.0;
    }

    sample_gradient(layer, t, r, g, b, a);
}

/* Reads a radial gradient's two circles + color stops. Same font-unit ->
 * device-pixel scaling as extract_linear_gradient. */
static int extract_radial_gradient(ColrV1Ctx* ctx, FT_PaintRadialGradient* rg, ColrV1Layer* layer) {
    FT_ColorStopIterator iter = rg->colorline.color_stop_iterator;
    FT_ColorStop stop;
    double scale;

    scale = (double)ctx->face->size->metrics.y_ppem / (double)ctx->face->units_per_EM;

    layer->kind = PAINT_KIND_RADIAL_GRADIENT;
    layer->c0x = ((double)rg->c0.x / 65536.0) * scale;
    layer->c0y = ((double)rg->c0.y / 65536.0) * scale;
    layer->r0  = ((double)rg->r0   / 65536.0) * scale;
    layer->c1x = ((double)rg->c1.x / 65536.0) * scale;
    layer->c1y = ((double)rg->c1.y / 65536.0) * scale;
    layer->r1  = ((double)rg->r1   / 65536.0) * scale;
    layer->extend = (int)rg->colorline.extend;
    layer->n_stops = 0;

    while (FT_Get_Colorline_Stops(ctx->face, &stop, &iter)) {
        unsigned char r, g, b, a;
        if (layer->n_stops >= COLRV1_MAX_STOPS) return 0;
        solid_color_from_index(ctx, &stop.color, &r, &g, &b, &a);
        layer->stops[layer->n_stops].offset = (double)stop.stop_offset / 65536.0;
        layer->stops[layer->n_stops].r = r;
        layer->stops[layer->n_stops].g = g;
        layer->stops[layer->n_stops].b = b;
        layer->stops[layer->n_stops].a = a;
        layer->n_stops++;
    }
    return layer->n_stops > 0;
}

/* Two-circle radial gradient, same model CSS/SVG use: circle interpolates
 * from (c0,r0) at t=0 to (c1,r1) at t=1. For a query point p, solve for
 * the t at which p lies exactly on the interpolated circle:
 *
 *   (px - (c0x + t*dcx))^2 + (py - (c0y + t*dcy))^2 == (r0 + t*dr)^2
 *
 * Expanding gives a quadratic A*t^2 + B*t + C = 0. Per the COLRv1 spec,
 * pick the greater root whose corresponding radius (r0 + t*dr) is >= 0. */
static void radial_gradient_color_at(ColrV1Layer* layer, double px, double py,
                                      unsigned char* r, unsigned char* g,
                                      unsigned char* b, unsigned char* a) {
    double dcx = layer->c1x - layer->c0x;
    double dcy = layer->c1y - layer->c0y;
    double dr  = layer->r1  - layer->r0;
    double ux  = px - layer->c0x;
    double uy  = py - layer->c0y;

    double A = dcx * dcx + dcy * dcy - dr * dr;
    double B = -2.0 * (ux * dcx + uy * dcy + layer->r0 * dr);
    double C = ux * ux + uy * uy - layer->r0 * layer->r0;

    double t;
    int have_t = 0;

    if (fabs(A) > 1e-9) {
        double disc = B * B - 4.0 * A * C;
        if (disc >= 0.0) {
            double sqrt_d = sqrt(disc);
            double t1 = (-B + sqrt_d) / (2.0 * A);
            double t2 = (-B - sqrt_d) / (2.0 * A);
            /* Prefer the larger t whose radius at that t is non-negative. */
            double hi = (t1 > t2) ? t1 : t2;
            double lo = (t1 > t2) ? t2 : t1;
            if (layer->r0 + hi * dr >= 0.0) {
                t = hi; have_t = 1;
            } else if (layer->r0 + lo * dr >= 0.0) {
                t = lo; have_t = 1;
            }
        }
    } else if (fabs(B) > 1e-9) {
        /* Degenerate to linear equation (equal radii along the gradient axis). */
        t = -C / B;
        have_t = 1;
    }

    if (!have_t) {
        /* No valid circle passes through this point — fully transparent,
         * matching the spec's "point not covered by any circle" case. */
        *r = 0; *g = 0; *b = 0; *a = 0;
        return;
    }

    if (layer->extend == 1) {         /* REPEAT */
        t = t - floor(t);
    } else if (layer->extend == 2) {  /* REFLECT */
        double tt = fmod(t, 2.0);
        if (tt < 0.0) tt += 2.0;
        t = (tt <= 1.0) ? tt : 2.0 - tt;
    } else {                          /* PAD (default) */
        if (t < 0.0) t = 0.0;
        if (t > 1.0) t = 1.0;
    }

    sample_gradient(layer, t, r, g, b, a);
}


/* Reads a sweep (conic/angular) gradient's center + start/end angle +
 * color stops. Angles come from the font as FT_Fixed (16.16) in the
 * COLRv1 spec's normalized form where 1.0 == 180 degrees — converted
 * here to plain degrees for straightforward atan2-based sampling. */
static int extract_sweep_gradient(ColrV1Ctx* ctx, FT_PaintSweepGradient* sg, ColrV1Layer* layer) {
    FT_ColorStopIterator iter = sg->colorline.color_stop_iterator;
    FT_ColorStop stop;
    double scale;

    scale = (double)ctx->face->size->metrics.y_ppem / (double)ctx->face->units_per_EM;

    layer->kind = PAINT_KIND_SWEEP_GRADIENT;
    layer->sweep_cx = ((double)sg->center.x / 65536.0) * scale;
    layer->sweep_cy = ((double)sg->center.y / 65536.0) * scale;
    layer->start_angle_deg = ((double)sg->start_angle / 65536.0) * 180.0;
    layer->end_angle_deg   = ((double)sg->end_angle   / 65536.0) * 180.0;
    layer->extend = (int)sg->colorline.extend;
    layer->n_stops = 0;

    while (FT_Get_Colorline_Stops(ctx->face, &stop, &iter)) {
        unsigned char r, g, b, a;
        if (layer->n_stops >= COLRV1_MAX_STOPS) return 0;
        solid_color_from_index(ctx, &stop.color, &r, &g, &b, &a);
        layer->stops[layer->n_stops].offset = (double)stop.stop_offset / 65536.0;
        layer->stops[layer->n_stops].r = r;
        layer->stops[layer->n_stops].g = g;
        layer->stops[layer->n_stops].b = b;
        layer->stops[layer->n_stops].a = a;
        layer->n_stops++;
    }
    return layer->n_stops > 0;
}

/* Angle from center to (px,py) via atan2, normalized into the sweep's
 * [start_angle, end_angle) range (adding/subtracting full turns as
 * needed) before computing t — handles sweeps that cross the -180/180
 * wraparound boundary. */
static void sweep_gradient_color_at(ColrV1Layer* layer, double px, double py,
                                     unsigned char* r, unsigned char* g,
                                     unsigned char* b, unsigned char* a) {
    double dx = px - layer->sweep_cx;
    double dy = py - layer->sweep_cy;
    double angle_deg;
    double span = layer->end_angle_deg - layer->start_angle_deg;
    double t;

    if (fabs(dx) < 1e-9 && fabs(dy) < 1e-9) {
        /* Exactly at the center — angle is undefined; use the start color. */
        angle_deg = layer->start_angle_deg;
    } else {
        angle_deg = atan2(dy, dx) * (180.0 / M_PI);
    }

    if (fabs(span) < 1e-9) {
        t = 0.0;
    } else {
        /* Bring angle_deg into [start_angle_deg, start_angle_deg + 360)
         * (or the mirrored direction if span is negative) so the sweep
         * that crosses +/-180 is handled correctly. */
        while (angle_deg < layer->start_angle_deg) angle_deg += 360.0;
        while (angle_deg >= layer->start_angle_deg + 360.0) angle_deg -= 360.0;
        t = (angle_deg - layer->start_angle_deg) / span;
    }

    if (layer->extend == 1) {         /* REPEAT */
        t = t - floor(t);
    } else if (layer->extend == 2) {  /* REFLECT */
        double tt = fmod(t, 2.0);
        if (tt < 0.0) tt += 2.0;
        t = (tt <= 1.0) ? tt : 2.0 - tt;
    } else {                          /* PAD (default) */
        if (t < 0.0) t = 0.0;
        if (t > 1.0) t = 1.0;
    }

    sample_gradient(layer, t, r, g, b, a);
}


/* Minimal 2x3 affine matrix, same convention as FT_Affine23:
 *   x' = x*xx + y*xy + dx
 *   y' = x*yx + y*yy + dy
 * xx/xy/yx/yy are unitless ratios (no ppem scaling needed — a "2x scale"
 * is 2x regardless of device pixel size). dx/dy ARE device-pixel
 * distances (already scaled by ppem/unitsPerEm when extracted from the
 * paint data, same convention as gradient points elsewhere in this file). */
typedef struct { double xx, xy, dx, yx, yy, dy; } Matrix2x3;

static Matrix2x3 mat_identity(void) {
    Matrix2x3 m; m.xx = 1.0; m.xy = 0.0; m.dx = 0.0;
    m.yx = 0.0; m.yy = 1.0; m.dy = 0.0;
    return m;
}

/* Composes outer ∘ inner — applying the result to a point p means
 * outer(inner(p)), i.e. inner happens first (closer to the leaf glyph),
 * outer is the transform accumulated from ancestors further up the tree. */
static Matrix2x3 mat_compose(Matrix2x3 outer, Matrix2x3 inner) {
    Matrix2x3 r;
    r.xx = outer.xx * inner.xx + outer.xy * inner.yx;
    r.xy = outer.xx * inner.xy + outer.xy * inner.yy;
    r.dx = outer.xx * inner.dx + outer.xy * inner.dy + outer.dx;
    r.yx = outer.yx * inner.xx + outer.yy * inner.yx;
    r.yy = outer.yx * inner.xy + outer.yy * inner.yy;
    r.dy = outer.yx * inner.dx + outer.yy * inner.dy + outer.dy;
    return r;
}

static void mat_apply_point(Matrix2x3 m, double x, double y, double* ox, double* oy) {
    *ox = x * m.xx + y * m.xy + m.dx;
    *oy = x * m.yx + y * m.yy + m.dy;
}

/* PaintGlyph's child is not always directly a Solid/Gradient — it can be
 * wrapped in its OWN Transform/Translate/Scale chain first (a DIFFERENT
 * pattern than Transform-wraps-PaintGlyph, which process_paint's main
 * dispatch already handles via `mat`). This recursively unwraps that
 * chain, accumulating into fill_mat (seeded with the caller's `mat` so
 * the fill ends up in the same final device-pixel space as the outline),
 * until it reaches an actual fill type. Returns 1 on success. */
static int resolve_fill(ColrV1Ctx* ctx, FT_OpaquePaint fill_ref, Matrix2x3 fill_mat, int depth,
                         PaintKind* out_kind,
                         unsigned char* out_r, unsigned char* out_g,
                         unsigned char* out_b, unsigned char* out_a,
                         ColrV1Layer* out_grad) {
    FT_COLR_Paint p;
    double scale;

    if (depth > COLRV1_MAX_DEPTH) return 0;
    if (!FT_Get_Paint(ctx->face, fill_ref, &p)) return 0;

    if (p.format == FT_COLR_PAINTFORMAT_SOLID) {
        *out_kind = PAINT_KIND_SOLID;
        extract_solid_color(ctx, &p.u.solid, out_r, out_g, out_b, out_a);
        return 1;
    }
    if (p.format == FT_COLR_PAINTFORMAT_LINEAR_GRADIENT) {
        *out_kind = PAINT_KIND_LINEAR_GRADIENT;
        if (!extract_linear_gradient(ctx, &p.u.linear_gradient, out_grad)) return 0;
        mat_apply_point(fill_mat, out_grad->p0x, out_grad->p0y, &out_grad->p0x, &out_grad->p0y);
        mat_apply_point(fill_mat, out_grad->p1x, out_grad->p1y, &out_grad->p1x, &out_grad->p1y);
        return 1;
    }
    if (p.format == FT_COLR_PAINTFORMAT_RADIAL_GRADIENT) {
        double sf;
        *out_kind = PAINT_KIND_RADIAL_GRADIENT;
        if (!extract_radial_gradient(ctx, &p.u.radial_gradient, out_grad)) return 0;
        sf = sqrt(fabs(fill_mat.xx * fill_mat.yy - fill_mat.xy * fill_mat.yx));
        mat_apply_point(fill_mat, out_grad->c0x, out_grad->c0y, &out_grad->c0x, &out_grad->c0y);
        mat_apply_point(fill_mat, out_grad->c1x, out_grad->c1y, &out_grad->c1x, &out_grad->c1y);
        out_grad->r0 *= sf; out_grad->r1 *= sf;
        return 1;
    }
    if (p.format == FT_COLR_PAINTFORMAT_SWEEP_GRADIENT) {
        *out_kind = PAINT_KIND_SWEEP_GRADIENT;
        if (!extract_sweep_gradient(ctx, &p.u.sweep_gradient, out_grad)) return 0;
        mat_apply_point(fill_mat, out_grad->sweep_cx, out_grad->sweep_cy,
                         &out_grad->sweep_cx, &out_grad->sweep_cy);
        return 1;
    }
    if (p.format == FT_COLR_PAINTFORMAT_TRANSFORM) {
        Matrix2x3 local, combined;
        scale = (double)ctx->face->size->metrics.y_ppem / (double)ctx->face->units_per_EM;
        local.xx = (double)p.u.transform.affine.xx / 65536.0;
        local.xy = (double)p.u.transform.affine.xy / 65536.0;
        local.yx = (double)p.u.transform.affine.yx / 65536.0;
        local.yy = (double)p.u.transform.affine.yy / 65536.0;
        local.dx = ((double)p.u.transform.affine.dx / 65536.0) * scale;
        local.dy = ((double)p.u.transform.affine.dy / 65536.0) * scale;
        combined = mat_compose(fill_mat, local);
        return resolve_fill(ctx, p.u.transform.paint, combined, depth + 1,
                             out_kind, out_r, out_g, out_b, out_a, out_grad);
    }
    if (p.format == FT_COLR_PAINTFORMAT_TRANSLATE) {
        Matrix2x3 local, combined;
        scale = (double)ctx->face->size->metrics.y_ppem / (double)ctx->face->units_per_EM;
        local = mat_identity();
        local.dx = ((double)p.u.translate.dx / 65536.0) * scale;
        local.dy = ((double)p.u.translate.dy / 65536.0) * scale;
        combined = mat_compose(fill_mat, local);
        return resolve_fill(ctx, p.u.translate.paint, combined, depth + 1,
                             out_kind, out_r, out_g, out_b, out_a, out_grad);
    }
    if (p.format == FT_COLR_PAINTFORMAT_SCALE) {
        Matrix2x3 local, combined;
        double sx, sy, cx, cy;
        scale = (double)ctx->face->size->metrics.y_ppem / (double)ctx->face->units_per_EM;
        sx = (double)p.u.scale.scale_x / 65536.0;
        sy = (double)p.u.scale.scale_y / 65536.0;
        cx = ((double)p.u.scale.center_x / 65536.0) * scale;
        cy = ((double)p.u.scale.center_y / 65536.0) * scale;
        local.xx = sx; local.xy = 0.0; local.dx = cx * (1.0 - sx);
        local.yx = 0.0; local.yy = sy; local.dy = cy * (1.0 - sy);
        combined = mat_compose(fill_mat, local);
        return resolve_fill(ctx, p.u.scale.paint, combined, depth + 1,
                             out_kind, out_r, out_g, out_b, out_a, out_grad);
    }

    return 0;  /* unsupported fill type (sweep already handled above; this
                * catches Rotate/Skew/Composite/ColrGlyph as fill) */
}


/* Forward declaration — render_subtree (below) calls process_paint, and
 * process_paint (further below) calls render_subtree for SRC_IN
 * compositing, so one of the two needs a forward declaration. */
static int process_paint(ColrV1Ctx* ctx, FT_OpaquePaint opaque, int depth, Matrix2x3 mat);

/* Composites ctx's collected layers into a single RGBA buffer, computing
 * its own bounding box. out_dev_left / out_dev_top record the DEVICE-PIXEL
 * position of the buffer's (0,0) pixel (top-left, Y-down row order) — the
 * SAME convention render_colrv1_glyph's final canvas uses — so a caller
 * can correctly position/intersect this buffer against another one (see
 * SRC_IN compositing below). Frees ctx's layer buffers unconditionally
 * (success or failure) since this always fully consumes them. Returns 0
 * on failure (nothing to composite / alloc failure), 1 on success. */
static int composite_layers(ColrV1Ctx* ctx, unsigned char** out_buf,
                             int* out_w, int* out_h,
                             int* out_dev_left, int* out_dev_top) {
    int min_left, max_right, max_top, min_bottom;
    int canvas_w, canvas_h;
    unsigned char* canvas;
    int i;

    if (ctx->n_layers == 0) return 0;

    min_left = 1000000; max_right = -1000000;
    max_top  = -1000000; min_bottom = 1000000;
    for (i = 0; i < ctx->n_layers; i++) {
        if (ctx->layers[i].left < min_left) min_left = ctx->layers[i].left;
        if (ctx->layers[i].left + ctx->layers[i].width > max_right)
            max_right = ctx->layers[i].left + ctx->layers[i].width;
        if (ctx->layers[i].top > max_top) max_top = ctx->layers[i].top;
        if (ctx->layers[i].top - ctx->layers[i].rows < min_bottom)
            min_bottom = ctx->layers[i].top - ctx->layers[i].rows;
    }

    canvas_w = max_right - min_left;
    canvas_h = max_top - min_bottom;
    if (canvas_w <= 0 || canvas_h <= 0) {
        for (i = 0; i < ctx->n_layers; i++) free(ctx->layers[i].buf);
        return 0;
    }

    canvas = (unsigned char*)calloc((size_t)(canvas_w * canvas_h * 4), 1);
    if (!canvas) {
        for (i = 0; i < ctx->n_layers; i++) free(ctx->layers[i].buf);
        return 0;
    }

    for (i = 0; i < ctx->n_layers; i++) {
        int ox = ctx->layers[i].left - min_left;
        int oy = max_top - ctx->layers[i].top;
        int row, col;
        PaintKind kind = ctx->layers[i].kind;

        if (kind == PAINT_KIND_PRERENDERED) {
            /* Already a full RGBA buffer (from a sub-composite) — no
             * separate grayscale coverage mask to multiply against, just
             * standard Porter-Duff "over" using its own alpha channel. */
            for (row = 0; row < ctx->layers[i].rows; row++) {
                for (col = 0; col < ctx->layers[i].width; col++) {
                    int pidx, px, py, a, inv_a, out_a, cidx;
                    unsigned char lr, lg, lb, la, dr, dg, db, da;

                    pidx = (row * ctx->layers[i].width + col) * 4;
                    la = ctx->layers[i].buf[pidx + 3];
                    if (la == 0) continue;
                    lr = ctx->layers[i].buf[pidx];
                    lg = ctx->layers[i].buf[pidx + 1];
                    lb = ctx->layers[i].buf[pidx + 2];

                    px = ox + col;
                    py = oy + row;
                    if (px < 0 || px >= canvas_w || py < 0 || py >= canvas_h) continue;

                    a = la;
                    cidx = (py * canvas_w + px) * 4;
                    dr = canvas[cidx]; dg = canvas[cidx+1]; db = canvas[cidx+2]; da = canvas[cidx+3];
                    inv_a = 255 - a;
                    out_a = a + (da * inv_a) / 255;
                    if (out_a == 0) continue;
                    canvas[cidx]   = (unsigned char)((lr*a + dr*(inv_a*da/255)) / out_a);
                    canvas[cidx+1] = (unsigned char)((lg*a + dg*(inv_a*da/255)) / out_a);
                    canvas[cidx+2] = (unsigned char)((lb*a + db*(inv_a*da/255)) / out_a);
                    canvas[cidx+3] = (unsigned char)out_a;
                }
            }
            free(ctx->layers[i].buf);
            continue;
        }

        for (row = 0; row < ctx->layers[i].rows; row++) {
            for (col = 0; col < ctx->layers[i].width; col++) {
                int src_idx, px, py, a, inv_a, out_a, cidx;
                unsigned char src_a8, dr, dg, db, da;
                unsigned char lr, lg, lb, la;

                src_idx = row * ctx->layers[i].pitch + col;
                src_a8 = ctx->layers[i].buf[src_idx];
                if (src_a8 == 0) continue;

                px = ox + col;
                py = oy + row;
                if (px < 0 || px >= canvas_w || py < 0 || py >= canvas_h) continue;

                if (kind == PAINT_KIND_LINEAR_GRADIENT || kind == PAINT_KIND_RADIAL_GRADIENT
                    || kind == PAINT_KIND_SWEEP_GRADIENT) {
                    double dev_x = (double)(ctx->layers[i].left + col);
                    double dev_y = (double)(ctx->layers[i].top - row);
                    if (kind == PAINT_KIND_LINEAR_GRADIENT) {
                        gradient_color_at(&ctx->layers[i], dev_x, dev_y, &lr, &lg, &lb, &la);
                    } else if (kind == PAINT_KIND_RADIAL_GRADIENT) {
                        radial_gradient_color_at(&ctx->layers[i], dev_x, dev_y, &lr, &lg, &lb, &la);
                    } else {
                        sweep_gradient_color_at(&ctx->layers[i], dev_x, dev_y, &lr, &lg, &lb, &la);
                    }
                    if (la == 0) continue;
                } else {
                    lr = ctx->layers[i].r; lg = ctx->layers[i].g;
                    lb = ctx->layers[i].b; la = ctx->layers[i].a;
                }

                a = (src_a8 * la) / 255;
                if (a == 0) continue;

                cidx = (py * canvas_w + px) * 4;
                dr = canvas[cidx];
                dg = canvas[cidx + 1];
                db = canvas[cidx + 2];
                da = canvas[cidx + 3];

                inv_a = 255 - a;
                out_a = a + (da * inv_a) / 255;
                if (out_a == 0) continue;

                canvas[cidx]     = (unsigned char)((lr * a + dr * (inv_a * da / 255)) / out_a);
                canvas[cidx + 1] = (unsigned char)((lg * a + dg * (inv_a * da / 255)) / out_a);
                canvas[cidx + 2] = (unsigned char)((lb * a + db * (inv_a * da / 255)) / out_a);
                canvas[cidx + 3] = (unsigned char)out_a;
            }
        }
        free(ctx->layers[i].buf);
    }

    *out_buf = canvas;
    *out_w = canvas_w;
    *out_h = canvas_h;
    *out_dev_left = min_left;
    *out_dev_top  = max_top;
    return 1;
}

/* Renders a paint subtree (backdrop or source of a PaintComposite) into
 * its OWN isolated RGBA buffer, for compositing modes that need real
 * pixel-level combination (SRC_IN, etc) rather than simple sequential
 * "over" drawing. Uses a fresh ColrV1Ctx sharing the same face/palette. */
static int render_subtree(FT_Face face, FT_Color* palette, FT_OpaquePaint ref, Matrix2x3 mat,
                           int apply_italic,
                           unsigned char** out_buf, int* out_w, int* out_h,
                           int* out_dev_left, int* out_dev_top) {
    ColrV1Ctx sub_ctx;
    sub_ctx.face = face;
    sub_ctx.palette = palette;
    sub_ctx.n_layers = 0;
    sub_ctx.unsupported = 0;
    sub_ctx.apply_italic = apply_italic;

    process_paint(&sub_ctx, ref, 0, mat);
    if (sub_ctx.unsupported) {
        int i;
        for (i = 0; i < sub_ctx.n_layers; i++) free(sub_ctx.layers[i].buf);
        return 0;
    }
    return composite_layers(&sub_ctx, out_buf, out_w, out_h, out_dev_left, out_dev_top);
}


/* Recursively walks one paint node. Returns 0 on success, 1 on hard error
 * (out of memory, etc — distinct from "unsupported", which is signaled via
 * ctx->unsupported so the caller can tell the two apart). */
static int process_paint(ColrV1Ctx* ctx, FT_OpaquePaint opaque, int depth, Matrix2x3 mat) {
    FT_COLR_Paint paint;
    FT_LayerIterator iter;
    FT_OpaquePaint child = { NULL, 0 };

    if (depth > COLRV1_MAX_DEPTH) {
        ctx->unsupported = 1;
        return 1;
    }

    if (!FT_Get_Paint(ctx->face, opaque, &paint)) {
        return 1;
    }

    if (paint.format == FT_COLR_PAINTFORMAT_COLR_LAYERS) {
        iter = paint.u.colr_layers.layer_iterator;
        while (FT_Get_Paint_Layers(ctx->face, &iter, &child)) {
            process_paint(ctx, child, depth + 1, mat);
            if (ctx->unsupported) return 1;
        }
        return 0;
    }

    if (paint.format == FT_COLR_PAINTFORMAT_GLYPH) {
        FT_UInt gid = paint.u.glyph.glyphID;
        unsigned char r = 0, g = 0, b = 0, a = 255;
        FT_GlyphSlot slot;
        FT_Bitmap* bmp;
        int buf_size;
        unsigned char* copy;
        FT_Error err;
        PaintKind kind;
        ColrV1Layer grad_info;
        grad_info.n_stops = 0;

        /* PaintGlyph's fill can be a direct Solid/Gradient, OR wrapped in
         * its own Transform/Translate/Scale chain first — resolve_fill
         * handles both, accumulating fill-local transforms on top of
         * `mat` so gradient points land in the outline's final space. */
        kind = PAINT_KIND_SOLID;  /* silence "maybe uninitialized" — overwritten on success */
        if (!resolve_fill(ctx, paint.u.glyph.paint, mat, 0,
                           &kind, &r, &g, &b, &a, &grad_info)) {
            ctx->unsupported = 1;
            return 1;
        }

        if (ctx->n_layers >= COLRV1_MAX_LAYERS) {
            return 0;  /* silently drop extra layers past the cap, not a hard error */
        }

        /* Apply the accumulated transform to the OUTLINE via FreeType's
         * own FT_Set_Transform — matrix is unitless ratios (16.16), delta
         * is a device-pixel translation (26.6). Reset to identity right
         * after loading so this doesn't leak into sibling/later glyphs. */
        {
            FT_Matrix ft_matrix;
            FT_Vector ft_delta;
            ft_matrix.xx = (FT_Fixed)(mat.xx * 65536.0);
            ft_matrix.xy = (FT_Fixed)(mat.xy * 65536.0);
            ft_matrix.yx = (FT_Fixed)(mat.yx * 65536.0);
            ft_matrix.yy = (FT_Fixed)(mat.yy * 65536.0);
            ft_delta.x = (FT_Pos)(mat.dx * 64.0);
            ft_delta.y = (FT_Pos)(mat.dy * 64.0);
            FT_Set_Transform(ctx->face, &ft_matrix, &ft_delta);
        }

        err = FT_Load_Glyph(ctx->face, gid, FT_LOAD_NO_HINTING);
        FT_Set_Transform(ctx->face, NULL, NULL);  /* reset immediately, don't leak state */
        if (err) return 0;

        /* Split into load-then-render (instead of the single FT_LOAD_RENDER
         * flag used before) so FT_GlyphSlot_Oblique has an unrasterized
         * outline to act on — same reasoning as colrv0_render.c's fix.
         * NOTE the FT_Set_Transform reset above already happened BEFORE
         * this — Oblique's own shear is independent of and applied on
         * top of whatever COLRv1 paint-graph transform was just reset,
         * consistent with how regular (non-color) synthetic italic is
         * applied elsewhere in this engine. */
        if (ctx->apply_italic) {
            FT_GlyphSlot_Oblique(ctx->face->glyph);
        }
        err = FT_Render_Glyph(ctx->face->glyph, FT_RENDER_MODE_NORMAL);
        if (err) return 0;

        slot = ctx->face->glyph;
        bmp  = &slot->bitmap;
        if (bmp->width == 0 || bmp->rows == 0) return 0;


        buf_size = bmp->pitch * (int)bmp->rows;
        if (buf_size < 0) buf_size = -buf_size;
        copy = (unsigned char*)malloc((size_t)buf_size);
        if (!copy) return 0;
        memcpy(copy, bmp->buffer, (size_t)buf_size);

        ctx->layers[ctx->n_layers].buf   = copy;
        ctx->layers[ctx->n_layers].width = (int)bmp->width;
        ctx->layers[ctx->n_layers].rows  = (int)bmp->rows;
        ctx->layers[ctx->n_layers].pitch = bmp->pitch;
        ctx->layers[ctx->n_layers].left  = slot->bitmap_left;
        ctx->layers[ctx->n_layers].top   = slot->bitmap_top;
        ctx->layers[ctx->n_layers].kind  = kind;
        if (kind == PAINT_KIND_SOLID) {
            ctx->layers[ctx->n_layers].r = r;
            ctx->layers[ctx->n_layers].g = g;
            ctx->layers[ctx->n_layers].b = b;
            ctx->layers[ctx->n_layers].a = a;
        } else if (kind == PAINT_KIND_LINEAR_GRADIENT) {
            ctx->layers[ctx->n_layers].p0x = grad_info.p0x;
            ctx->layers[ctx->n_layers].p0y = grad_info.p0y;
            ctx->layers[ctx->n_layers].p1x = grad_info.p1x;
            ctx->layers[ctx->n_layers].p1y = grad_info.p1y;
            ctx->layers[ctx->n_layers].extend  = grad_info.extend;
            ctx->layers[ctx->n_layers].n_stops = grad_info.n_stops;
            memcpy(ctx->layers[ctx->n_layers].stops, grad_info.stops,
                   sizeof(GradientStop) * (size_t)grad_info.n_stops);
        } else if (kind == PAINT_KIND_RADIAL_GRADIENT) {
            ctx->layers[ctx->n_layers].c0x = grad_info.c0x;
            ctx->layers[ctx->n_layers].c0y = grad_info.c0y;
            ctx->layers[ctx->n_layers].r0  = grad_info.r0;
            ctx->layers[ctx->n_layers].c1x = grad_info.c1x;
            ctx->layers[ctx->n_layers].c1y = grad_info.c1y;
            ctx->layers[ctx->n_layers].r1  = grad_info.r1;
            ctx->layers[ctx->n_layers].extend  = grad_info.extend;
            ctx->layers[ctx->n_layers].n_stops = grad_info.n_stops;
            memcpy(ctx->layers[ctx->n_layers].stops, grad_info.stops,
                   sizeof(GradientStop) * (size_t)grad_info.n_stops);
        } else {  /* PAINT_KIND_SWEEP_GRADIENT */
            ctx->layers[ctx->n_layers].sweep_cx = grad_info.sweep_cx;
            ctx->layers[ctx->n_layers].sweep_cy = grad_info.sweep_cy;
            ctx->layers[ctx->n_layers].start_angle_deg = grad_info.start_angle_deg;
            ctx->layers[ctx->n_layers].end_angle_deg   = grad_info.end_angle_deg;
            ctx->layers[ctx->n_layers].extend  = grad_info.extend;
            ctx->layers[ctx->n_layers].n_stops = grad_info.n_stops;
            memcpy(ctx->layers[ctx->n_layers].stops, grad_info.stops,
                   sizeof(GradientStop) * (size_t)grad_info.n_stops);
        }
        ctx->n_layers++;
        return 0;
    }

    if (paint.format == FT_COLR_PAINTFORMAT_SOLID) {
        /* A bare Solid with no enclosing Glyph paint has no shape to fill —
         * nothing to draw. Not an error, just a no-op. */
        return 0;
    }

    if (paint.format == FT_COLR_PAINTFORMAT_TRANSFORM) {
        Matrix2x3 local, combined;
        double scale = (double)ctx->face->size->metrics.y_ppem / (double)ctx->face->units_per_EM;
        local.xx = (double)paint.u.transform.affine.xx / 65536.0;
        local.xy = (double)paint.u.transform.affine.xy / 65536.0;
        local.yx = (double)paint.u.transform.affine.yx / 65536.0;
        local.yy = (double)paint.u.transform.affine.yy / 65536.0;
        local.dx = ((double)paint.u.transform.affine.dx / 65536.0) * scale;
        local.dy = ((double)paint.u.transform.affine.dy / 65536.0) * scale;
        combined = mat_compose(mat, local);
        return process_paint(ctx, paint.u.transform.paint, depth + 1, combined);
    }

    if (paint.format == FT_COLR_PAINTFORMAT_TRANSLATE) {
        Matrix2x3 local, combined;
        double scale = (double)ctx->face->size->metrics.y_ppem / (double)ctx->face->units_per_EM;
        local = mat_identity();
        local.dx = ((double)paint.u.translate.dx / 65536.0) * scale;
        local.dy = ((double)paint.u.translate.dy / 65536.0) * scale;
        combined = mat_compose(mat, local);
        return process_paint(ctx, paint.u.translate.paint, depth + 1, combined);
    }

    if (paint.format == FT_COLR_PAINTFORMAT_SCALE) {
        Matrix2x3 local, combined;
        double scale = (double)ctx->face->size->metrics.y_ppem / (double)ctx->face->units_per_EM;
        double sx = (double)paint.u.scale.scale_x / 65536.0;
        double sy = (double)paint.u.scale.scale_y / 65536.0;
        double cx = ((double)paint.u.scale.center_x / 65536.0) * scale;
        double cy = ((double)paint.u.scale.center_y / 65536.0) * scale;
        /* scale-around-center: p' = center + S*(p-center) = S*p + center*(1-S) */
        local.xx = sx; local.xy = 0.0; local.dx = cx * (1.0 - sx);
        local.yx = 0.0; local.yy = sy; local.dy = cy * (1.0 - sy);
        combined = mat_compose(mat, local);
        return process_paint(ctx, paint.u.scale.paint, depth + 1, combined);
    }

    if (paint.format == FT_COLR_PAINTFORMAT_COMPOSITE) {
        /* SRC_OVER ("source drawn normally on top of backdrop") and
         * DEST_OVER ("backdrop drawn normally on top of source" — same
         * operation with the two operands' priority swapped) are both
         * mathematically IDENTICAL to processing the two paints as
         * sequential layers in the right order — the same way
         * PaintColrLayers already composites its children (see the
         * Porter-Duff "over" loop in render_colrv1_glyph). No new
         * buffer-level blending logic needed for either. Any other mode
         * (Screen/Multiply/XOR/...) is unsupported. */
        if (paint.u.composite.composite_mode == FT_COLR_COMPOSITE_SRC_OVER) {
            process_paint(ctx, paint.u.composite.backdrop_paint, depth + 1, mat);
            if (ctx->unsupported) return 1;
            process_paint(ctx, paint.u.composite.source_paint, depth + 1, mat);
            if (ctx->unsupported) return 1;
            return 0;
        }
        if (paint.u.composite.composite_mode == FT_COLR_COMPOSITE_DEST_OVER) {
            process_paint(ctx, paint.u.composite.source_paint, depth + 1, mat);
            if (ctx->unsupported) return 1;
            process_paint(ctx, paint.u.composite.backdrop_paint, depth + 1, mat);
            if (ctx->unsupported) return 1;
            return 0;
        }
        if (paint.u.composite.composite_mode == FT_COLR_COMPOSITE_SRC_IN) {
            /* "Show source, but only where backdrop had coverage" — needs
             * real pixel-level intersection, not just sequential drawing.
             *
             * SPECIAL CASE: source_paint is often a BARE PaintSolid (no
             * enclosing PaintGlyph, no shape of its own) — used to mean
             * "recolor backdrop's shape with this flat color", not
             * "nothing to draw" (which is what a bare Solid means outside
             * a composite). Handle this directly: render backdrop only,
             * then tint its buffer with the solid's color, keeping its
             * own alpha as the mask. Avoids needing a second render pass
             * for something that isn't really a drawable shape. */
            FT_COLR_Paint src_peek, backdrop_peek;
            unsigned char *buf_b, *result;
            int wb, hb, lb, tb;
            int row, col;

            if (FT_Get_Paint(ctx->face, paint.u.composite.source_paint, &src_peek)
                && src_peek.format == FT_COLR_PAINTFORMAT_SOLID) {
                unsigned char sr, sg, sb, sa;
                extract_solid_color(ctx, &src_peek.u.solid, &sr, &sg, &sb, &sa);

                if (!render_subtree(ctx->face, ctx->palette, paint.u.composite.backdrop_paint,
                                     mat, ctx->apply_italic, &buf_b, &wb, &hb, &lb, &tb)) {
                    ctx->unsupported = 1;
                    return 1;
                }
                result = (unsigned char*)malloc((size_t)(wb * hb * 4));
                if (!result) { free(buf_b); return 1; }
                for (row = 0; row < hb; row++) {
                    for (col = 0; col < wb; col++) {
                        int idx = (row * wb + col) * 4;
                        unsigned char ba = buf_b[idx + 3];
                        result[idx]     = sr;
                        result[idx + 1] = sg;
                        result[idx + 2] = sb;
                        result[idx + 3] = (unsigned char)((sa * ba) / 255);
                    }
                }
                free(buf_b);

                if (ctx->n_layers >= COLRV1_MAX_LAYERS) { free(result); return 0; }
                ctx->layers[ctx->n_layers].buf   = result;
                ctx->layers[ctx->n_layers].width = wb;
                ctx->layers[ctx->n_layers].rows  = hb;
                ctx->layers[ctx->n_layers].pitch = wb * 4;
                ctx->layers[ctx->n_layers].left  = lb;
                ctx->layers[ctx->n_layers].top   = tb;
                ctx->layers[ctx->n_layers].kind  = PAINT_KIND_PRERENDERED;
                ctx->n_layers++;
                return 0;
            }

            /* REVERSE special case: backdrop_paint is a bare PaintSolid
             * (a flat, shapeless "uniform coverage at alpha X" — common
             * for applying an overall opacity/tint to source, e.g. a
             * 0.7-alpha solid backdrop just dims the source uniformly).
             * No second shape to intersect against — just scale source's
             * own alpha by the solid's alpha, pixel-for-pixel. */
            if (FT_Get_Paint(ctx->face, paint.u.composite.backdrop_paint, &backdrop_peek)
                && backdrop_peek.format == FT_COLR_PAINTFORMAT_SOLID) {
                unsigned char br, bg, bb, ba_solid;
                extract_solid_color(ctx, &backdrop_peek.u.solid, &br, &bg, &bb, &ba_solid);
                (void)br; (void)bg; (void)bb;  /* backdrop's OWN color is irrelevant for SRC_IN — only its alpha matters */

                if (!render_subtree(ctx->face, ctx->palette, paint.u.composite.source_paint,
                                     mat, ctx->apply_italic, &buf_b, &wb, &hb, &lb, &tb)) {
                    ctx->unsupported = 1;
                    return 1;
                }
                for (row = 0; row < hb; row++) {
                    for (col = 0; col < wb; col++) {
                        int idx = (row * wb + col) * 4;
                        buf_b[idx + 3] = (unsigned char)((buf_b[idx + 3] * ba_solid) / 255);
                    }
                }

                if (ctx->n_layers >= COLRV1_MAX_LAYERS) { free(buf_b); return 0; }
                ctx->layers[ctx->n_layers].buf   = buf_b;
                ctx->layers[ctx->n_layers].width = wb;
                ctx->layers[ctx->n_layers].rows  = hb;
                ctx->layers[ctx->n_layers].pitch = wb * 4;
                ctx->layers[ctx->n_layers].left  = lb;
                ctx->layers[ctx->n_layers].top   = tb;
                ctx->layers[ctx->n_layers].kind  = PAINT_KIND_PRERENDERED;
                ctx->n_layers++;
                return 0;
            }

            /* General case: both operands are real shapes — render both
             * into ISOLATED buffers, then combine:

             * result_alpha = source_alpha * backdrop_alpha / 255,
             * result_color = source_color. */
            {
                unsigned char *buf_s;
                int ws, hs, ls, ts;

                if (!render_subtree(ctx->face, ctx->palette, paint.u.composite.backdrop_paint,
                                     mat, ctx->apply_italic, &buf_b, &wb, &hb, &lb, &tb)) {
                    ctx->unsupported = 1;
                    return 1;
                }
                if (!render_subtree(ctx->face, ctx->palette, paint.u.composite.source_paint,
                                     mat, ctx->apply_italic, &buf_s, &ws, &hs, &ls, &ts)) {
                    free(buf_b);
                    ctx->unsupported = 1;
                    return 1;
                }

                result = (unsigned char*)calloc((size_t)(ws * hs * 4), 1);
                if (!result) { free(buf_b); free(buf_s); return 1; }

                for (row = 0; row < hs; row++) {
                    for (col = 0; col < ws; col++) {
                        int sidx = (row * ws + col) * 4;
                        unsigned char sa = buf_s[sidx + 3];
                        int dev_x, dev_y, bcol, brow, bidx;
                        unsigned char ba;

                        if (sa == 0) continue;

                        dev_x = ls + col;
                        dev_y = ts - row;
                        bcol = dev_x - lb;
                        brow = tb - dev_y;
                        if (bcol < 0 || bcol >= wb || brow < 0 || brow >= hb) continue;

                        bidx = (brow * wb + bcol) * 4;
                        ba = buf_b[bidx + 3];
                        if (ba == 0) continue;

                        result[sidx]     = buf_s[sidx];
                        result[sidx + 1] = buf_s[sidx + 1];
                        result[sidx + 2] = buf_s[sidx + 2];
                        result[sidx + 3] = (unsigned char)((sa * ba) / 255);
                    }
                }
                free(buf_b);
                free(buf_s);

                if (ctx->n_layers >= COLRV1_MAX_LAYERS) { free(result); return 0; }
                ctx->layers[ctx->n_layers].buf   = result;
                ctx->layers[ctx->n_layers].width = ws;
                ctx->layers[ctx->n_layers].rows  = hs;
                ctx->layers[ctx->n_layers].pitch = ws * 4;
                ctx->layers[ctx->n_layers].left  = ls;
                ctx->layers[ctx->n_layers].top   = ts;
                ctx->layers[ctx->n_layers].kind  = PAINT_KIND_PRERENDERED;
                ctx->n_layers++;
                return 0;
            }
        }
        ctx->unsupported = 1;
        return 1;
    }

    /* Rotate / Skew / Composite (non-SRC_OVER modes) / ColrGlyph — none
     * of these are implemented yet. Abort cleanly so the caller falls
     * back instead of drawing an incomplete/wrong glyph. */
    ctx->unsupported = 1;
    return 1;
}


int render_colrv1_glyph(
    FT_Face face,
    FT_UInt glyph_index,
    int apply_italic,
    unsigned char** out_rgba,
    int* out_w,
    int* out_h,
    int* out_top,
    int* out_left
) {
    ColrV1Ctx ctx;
    FT_OpaquePaint root = { NULL, 0 };  /* must initialize — garbage stack
                                          * causes FT_Get_Color_Glyph_Paint
                                          * to fail incorrectly */
    int dev_left, dev_top;

    *out_rgba = NULL;
    *out_w = 0;
    *out_h = 0;
    *out_top = 0;
    *out_left = 0;

    ctx.face = face;
    ctx.n_layers = 0;
    ctx.unsupported = 0;
    ctx.apply_italic = apply_italic;

    if (FT_Palette_Select(face, 0, &ctx.palette) || ctx.palette == NULL) {
        return 1;
    }

    if (!FT_Get_Color_Glyph_Paint(face, glyph_index,
                                   FT_COLOR_NO_ROOT_TRANSFORM, &root)) {
        return 2;
    }

    process_paint(&ctx, root, 0, mat_identity());

    if (ctx.unsupported) {
        int i;
        for (i = 0; i < ctx.n_layers; i++) free(ctx.layers[i].buf);
        return 3;
    }
    if (ctx.n_layers == 0) {
        return 4;
    }

    if (!composite_layers(&ctx, out_rgba, out_w, out_h, &dev_left, &dev_top)) {
        return (*out_rgba == NULL && ctx.n_layers > 0) ? 5 : 6;
    }
    *out_top = dev_top;
    *out_left = dev_left;
    return 0;
}
