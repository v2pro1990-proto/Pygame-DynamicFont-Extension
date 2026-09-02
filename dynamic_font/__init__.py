"""
dynamic_font — public package interface.

The actual compiled extension lives in `dynamic_font._core` (built from
_core.pyx) — this file exists solely to (a) keep `import dynamic_font`
working exactly as before despite the underlying package/module
restructure, and (b) make the four mutable module-level config
variables (MODERN_FONT, SMOOTH_FONT, ANTI_ALIAS, EMOJI_OFFSET_Y)
actually behave like they did as a single flat module.

Why this needs special handling (not just `from ._core import *`):
a plain star-import COPIES each variable's current value into THIS
module's own namespace at import time. Afterward, `dynamic_font.
MODERN_FONT = False` would only ever update THIS file's copy — the
C-level code inside _core.pyx reads its OWN module-global `MODERN_FONT`
directly, and would never see that change. Every existing usage
pattern in this project's own README/examples (`dynamic_font.
MODERN_FONT = True`, etc.) would silently stop working after this
restructure without the property-proxy trick below.

This is a well-established pattern for making module-level attributes
behave like properties (real getter/setter forwarding), by swapping
the live module object's class for one that defines them — since
Python module objects support this from PEP 562's underlying
mechanism (module `__class__` reassignment predates PEP 562 and works
on every Python version this project supports, 3.8+).
"""
import sys as _sys
import types as _types

from . import _core

# Everything that ISN'T one of the four mutable config variables below
# is safe to re-export normally — these are either genuinely constant
# after import (functions, the DynamicFont class) or immutable-in-
# practice, so a plain copy-on-import is fine for them.
from ._core import (
    DynamicFont,
    get_engine_version,
    get_family_root,
    is_scanning,
)


class _DynamicFontModule(_types.ModuleType):
    """Swapped in as this module's __class__ below — makes the four
    config variables real properties that forward every read/write
    straight to dynamic_font._core's own globals, instead of a
    disconnected copy."""

    @property
    def MODERN_FONT(self):
        return _core.MODERN_FONT

    @MODERN_FONT.setter
    def MODERN_FONT(self, value):
        _core.MODERN_FONT = value

    @property
    def SMOOTH_FONT(self):
        return _core.SMOOTH_FONT

    @SMOOTH_FONT.setter
    def SMOOTH_FONT(self, value):
        _core.SMOOTH_FONT = value

    @property
    def ANTI_ALIAS(self):
        return _core.ANTI_ALIAS

    @ANTI_ALIAS.setter
    def ANTI_ALIAS(self, value):
        _core.ANTI_ALIAS = value

    @property
    def EMOJI_OFFSET_Y(self):
        return _core.EMOJI_OFFSET_Y

    @EMOJI_OFFSET_Y.setter
    def EMOJI_OFFSET_Y(self, value):
        _core.EMOJI_OFFSET_Y = value


_sys.modules[__name__].__class__ = _DynamicFontModule

del _sys, _types
