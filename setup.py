from setuptools import setup
from Cython.Build import cythonize
from setuptools.extension import Extension
from pathlib import Path


_THIS_DIR = Path(__file__).parent
_LONG_DESCRIPTION = (_THIS_DIR / "README.md").read_text(encoding="utf-8")

extensions = [
    Extension(
        name="dynamic_font",              
        sources=["dynamic_font.pyx"],
    )
]


setup(
    name="dynamic_font",                 
    version="1.2.2.6",
    author="v2pro1990",                    
    description="Fast text and emoji rendering extension for Pygame and Pygame-CE",
    long_description=_LONG_DESCRIPTION,
    long_description_content_type="text/markdown",
    url="https://github.com/v2pro1990-proto/Pygame-DynamicFont-Extension",
    project_urls={
        "Source": "https://github.com/v2pro1990-proto/Pygame-DynamicFont-Extension",
        "Bug Tracker": "https://github.com/v2pro1990-proto/Pygame-DynamicFont-Extension/issues",
    },
    classifiers=[
        "Programming Language :: Python :: 3",
        "Programming Language :: Cython",
        "Topic :: Multimedia :: Graphics",
        "Topic :: Software Development :: Libraries :: pygame",
        "Intended Audience :: Developers",
        "License :: OSI Approved :: MIT License",
    ],
    keywords=["pygame", "pygame-ce", "font", "text rendering", "emoji", "cython"],
    install_requires=[
        "fonttools",
        "freetype-py",
        "uharfbuzz",
        "emoji",
    ],
    ext_modules=cythonize(extensions, compiler_directives={'language_level': "3"}),
)