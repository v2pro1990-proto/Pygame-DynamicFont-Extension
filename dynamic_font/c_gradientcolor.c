#include "c_gradientcolor.h"
#include <math.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* Color at position f in [0, 1] along the n evenly spaced colors. */
static void grad_sample(const GradColor* colors, int n, double f, unsigned char* out) {
    double pos, frac;
    int k;

    if (n == 1) {
        out[0] = colors[0].r;
        out[1] = colors[0].g;
        out[2] = colors[0].b;
        return;
    }
    pos = f * (double)(n - 1);
    k = (int)pos;
    if (k >= n - 1) k = n - 2;   /* f == 1 sits exactly on the last color */
    if (k < 0) k = 0;
    frac = pos - (double)k;
    /* +0.5: round to nearest instead of truncating toward the first color */
    out[0] = (unsigned char)(colors[k].r + (colors[k + 1].r - colors[k].r) * frac + 0.5);
    out[1] = (unsigned char)(colors[k].g + (colors[k + 1].g - colors[k].g) * frac + 0.5);
    out[2] = (unsigned char)(colors[k].b + (colors[k + 1].b - colors[k].b) * frac + 0.5);
}

void grad_build_lut(const GradColor* colors, int n, int layers, int mirror,
                    unsigned char* lut) {
    int i, layer;
    double u, v, f;

    if (!colors || !lut || n <= 0) return;
    if (layers < 1) layers = 1;

    for (i = 0; i < GRAD_LUT_SIZE; i++) {
        /* u: position across the whole box; v: position counted in layers */
        u = (double)i / (double)(GRAD_LUT_SIZE - 1);
        v = u * (double)layers;
        layer = (int)v;
        if (layer >= layers) {      /* u == 1: end of the last layer */
            layer = layers - 1;
            f = 1.0;
        } else {
            f = v - (double)layer;
        }
        if (mirror && (layer & 1)) f = 1.0 - f;
        grad_sample(colors, n, f, lut + i * 3);
    }
}

void grad_setup(double angle_deg, int x0, int y0, int w, int h, double period,
                long long* ax, long long* ay, long long* c) {
    double rad, ux, uy, p, pmin, pmax, range, scale;
    double cx[4], cy[4];
    int i;

    *ax = 0;
    *ay = 0;
    *c = 0;
    if (w <= 0 || h <= 0) return;

    /* Unit direction vector in screen space (y grows downward, so "up"
     * — positive angles — is negative y). */
    rad = angle_deg * M_PI / 180.0;
    ux = cos(rad);
    uy = -sin(rad);

    /* Project the box's 4 corners onto the direction: the smallest
     * projection is where the gradient starts (index 0), the largest
     * where it ends (last index). Pixel centers, hence the -1. */
    cx[0] = x0;           cy[0] = y0;
    cx[1] = x0 + w - 1;   cy[1] = y0;
    cx[2] = x0;           cy[2] = y0 + h - 1;
    cx[3] = x0 + w - 1;   cy[3] = y0 + h - 1;
    pmin = pmax = cx[0] * ux + cy[0] * uy;
    for (i = 1; i < 4; i++) {
        p = cx[i] * ux + cy[i] * uy;
        if (p < pmin) pmin = p;
        if (p > pmax) pmax = p;
    }
    if (period > 0.0) {
        /* Fixed length: index = (p - pmin) / period * GRAD_LUT_SIZE, so one
         * full table every `period` pixels, independent of the text size. */
        scale = (double)GRAD_LUT_SIZE / period * 65536.0;
    } else {
        range = pmax - pmin;
        if (range < 1e-9) return;   /* 1-pixel box along this direction: solid first color */
        /* index = (p - pmin) / range * (GRAD_LUT_SIZE - 1) */
        scale = (double)(GRAD_LUT_SIZE - 1) / range * 65536.0;
    }
    /* 16.16 fixed point, +0.5 to round */
    *ax = (long long)llround(ux * scale);
    *ay = (long long)llround(uy * scale);
    *c  = (long long)llround(-pmin * scale + 32768.0);
}
