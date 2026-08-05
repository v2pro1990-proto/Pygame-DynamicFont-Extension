from setuptools import setup
from Cython.Build import cythonize
from setuptools.extension import Extension


extensions = [
    Extension(
        name="dynamic_font",              
        sources=["dynamic_font.pyx"],
    )
]


setup(
    name="dynamic_font",                 
    version="1.2.2.5",                       
    author="v2pro1990",                    
    description="Font rendering Extesion for Pygame and Pygame-CE",
    # pygame/pygame-ce intentionally NOT listed here — anyone installing
    # a pygame extension already has pygame or pygame-ce in their project
    # (that's the whole reason they need this). Auto-installing it could
    # even conflict with an existing pygame-ce setup, since "pygame" and
    # "pygame-ce" are separate PyPI packages that both provide the same
    # top-level "pygame" import name.
    install_requires=[
        "fonttools",
        "freetype-py",
        "uharfbuzz",
        "emoji",
    ],
    ext_modules=cythonize(extensions, compiler_directives={'language_level': "3"}),
)