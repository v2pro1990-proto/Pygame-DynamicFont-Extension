Third-party components in dynamic_font
======================================

dynamic_font itself is MIT-licensed (see LICENSE in the distribution's
metadata). The compiled extension statically links, and the package
bundles, the following third-party components. Each keeps its own
license, reproduced in full in this directory.

Component       Version   How it is used          License / file
--------------  --------  ----------------------  ------------------------------------
FreeType        2.13.2    statically linked       FreeType License (FTL), chosen from
                                                  the FTL/GPLv2 dual license:
                                                    FreeType-FTL.txt
                                                    FreeType-LICENSE.txt
                                                  BDF/PCF drivers (MIT-style):
                                                    FreeType-BDF-PCF.txt
libpng          1.6.44    statically linked       libpng License v2:
                                                    libpng-LICENSE.txt
zlib            1.3.1     statically linked       zlib License:
                                                    zlib-LICENSE.txt
HarfBuzz        14.5.0    statically compiled in  "Old MIT" License:
                                                    HarfBuzz-COPYING.txt
                                                  USE data (MIT, Microsoft):
                                                    HarfBuzz-ms-use-COPYING.txt
SheenBidi       3.0.0     statically compiled in  Apache License 2.0:
                                                    SheenBidi-LICENSE.txt
Noto fonts      -         bundled font files      SIL Open Font License 1.1:
                                                    Noto-OFL.txt
DynamicFont     -         bundled bitmap font     SIL Open Font License 1.1
Pixel                     (from JetBrains Mono)   (a Modified Version of JetBrains Mono):
                                                    DynamicFontPixel-OFL.txt

FreeType credit (required by the FreeType License):

    Portions of this software are copyright © 1996-2023 The FreeType
    Project (www.freetype.org).  All rights reserved.

Credits for dynamic_font itself are appreciated, not required (MIT only
asks that its copyright notice and license stay with copies of the
software). A suggested credit line for games and products:

    Text rendering: DynamicFont by v2pro1990
    https://github.com/v2pro1990-proto/Pygame-DynamicFont-Extension
