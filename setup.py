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
    ext_modules=cythonize(extensions, language_level="3"),
)
