# v1.2.4 CHANGELOG images and numbers

Everything shown in the v1.2.4 [CHANGELOG](../../CHANGELOG.md) comes from the
scripts in this folder — the images are real DynamicFont output, and the
numbers are measured. Run them yourself to check (Python 3.8+, pygame or
pygame-ce, the v1.2.4 `dynamic_font` installed).

| Script | Makes |
| ----- | ----- |
| `make_demos.py` | `00_banner.png` … `06_bitmap_font.png` — the code on the left of each card is what renders the text on its right |
| `make_before_after.py --old DIR` | `07_fixes_before_after.png` — the same input rendered by v1.2.3 (`DIR`) and by v1.2.4 |
| `measure_bidi.py [--engine DIR]` | the right-to-left results (v1.2.3: 3 of 8, v1.2.4: 8 of 8) |
| `benchmark.py [--engine DIR]` | the performance table |

- `--engine DIR` / `--old DIR` / `--new DIR` point at a folder that contains a
  particular version of `dynamic_font` (for example a wheel of that version
  unzipped into the folder), so two versions can be compared on one machine.
- The bitmap-font card uses `dynamic_font.PIXEL_FONT`, the `.dfbmp` font that
  ships with the package (built by [`scripts/make_pixel_font.py`](../../scripts/make_pixel_font.py)).
- The images were made on Windows 10 with Segoe UI, Georgia and JetBrains
  Mono installed; other fonts or systems give different — but equally real —
  images. On the machine that made them, the scripts reproduce every image
  pixel for pixel.
- Benchmark times depend on the machine; compare the two versions on the
  same one.
