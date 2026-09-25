#ifndef C_GRADIENTCOLOR_H
#define C_GRADIENTCOLOR_H

/*
 * c_gradientcolor.h — N-stop linear gradient support for text color.
 *
 * Design: the gradient is applied WHILE glyphs are drawn (the .pyx
 * _draw_layout loop), not as a post-process over the finished surface:
 *   - only text glyphs are colored — color emoji keep their own colors;
 *   - no extra pass over every pixel of the surface;
 *   - inline ^X color tags still win over the gradient.
 * The gradient spans the WHOLE line (one smooth sweep across all runs),
 * not each glyph or run separately.
 *
 * This module does the math that is independent of pixel layout:
 *   1. grad_build_lut(): N evenly spaced colors (optionally repeated in
 *      several layers) -> GRAD_LUT_SIZE-entry RGB table, so drawing needs
 *      a table lookup per pixel, no floating point.
 *   2. grad_setup():     direction + box -> fixed-point coefficients that
 *      map a pixel (x, y) to its table index in [0, GRAD_LUT_SIZE - 1].
 *
 * Angles use the math convention with the screen's y axis pointing DOWN:
 *   0 = RIGHT (first color at the left edge, last color at the right),
 *   90 = UP, 180 = LEFT, 270 = DOWN; 45 = towards the top-right corner.
 */

#ifdef __cplusplus
extern "C" {
#endif

/* Table resolution. 1024 steps keep every layer smooth even when the
 * gradient repeats many times across the line (e.g. 20 layers still get
 * ~50 steps each). MUST stay a power of two: periodic gradients wrap
 * their index with a bit mask (index & (GRAD_LUT_SIZE - 1)). */
#define GRAD_LUT_SIZE 1024

typedef struct {
    unsigned char r, g, b;
} GradColor;

/*
 * Fills lut (GRAD_LUT_SIZE * 3 bytes, RGB triplets) with the gradient.
 *
 * colors, n: n colors spread evenly over one layer (n == 1 -> solid).
 * layers:    how many times the color sequence repeats across the box
 *            (values < 1 are treated as 1).
 * mirror:    0 = every layer runs first -> last color (a hard cut between
 *            layers); 1 = every other layer runs backwards, last -> first,
 *            so consecutive layers join seamlessly.
 *
 * No-op when colors/lut is NULL or n <= 0.
 */
void grad_build_lut(const GradColor* colors, int n, int layers, int mirror,
                    unsigned char* lut);

/*
 * For a gradient at angle_deg across the box (x0, y0, w, h), computes
 * coefficients such that, for any pixel (x, y):
 *     index = (x * ax + y * ay + c) >> 16
 *
 * period <= 0 (stretch): index 0 at the box corner where the gradient
 *   starts, GRAD_LUT_SIZE - 1 at the opposite corner. Pixels outside the
 *   box can land outside that range — the caller clamps.
 * period > 0 (fixed length): the whole table spans `period` pixels along
 *   the direction, starting at that same corner, whatever the box size —
 *   the caller wraps the index (index & (GRAD_LUT_SIZE - 1)) so the
 *   pattern repeats across the text.
 *
 * A degenerate box yields ax = ay = c = 0 (index 0).
 */
void grad_setup(double angle_deg, int x0, int y0, int w, int h, double period,
                long long* ax, long long* ay, long long* c);

#ifdef __cplusplus
}
#endif

#endif /* C_GRADIENTCOLOR_H */
