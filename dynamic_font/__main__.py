"""Command-line entry point: the .dfbmp bitmap font tools shipped with the
package, opened in the default web browser (they are self-contained HTML
pages — nothing is uploaded anywhere).

    python -m dynamic_font -buildbitmap     .dfbmp builder: make a bitmap font
                                            from an atlas image, or open and
                                            convert an existing .dfbmp
    python -m dynamic_font -bitmapviewer    .dfbmp viewer: every glyph of a
                                            .dfbmp file and its settings
"""
import sys
import webbrowser
from pathlib import Path

_TOOLS = {
    "-buildbitmap": "dfbmp_builder.html",
    "-bitmapviewer": "dfbmp_viewer.html",
}


def main(argv=None):
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 1 or args[0].lower() not in _TOOLS:
        print(__doc__.strip())
        return 0 if not args or args[0] in ("-h", "--help") else 2
    page = Path(__file__).resolve().parent / "tools" / _TOOLS[args[0].lower()]
    if not page.is_file():
        print(f"[dynamic_font] {page.name} is missing from this installation ({page})")
        return 1
    print(f"[dynamic_font] opening {page}")
    webbrowser.open(page.as_uri())
    return 0


if __name__ == "__main__":
    sys.exit(main())
