from setuptools import setup
from Cython.Build import cythonize
from setuptools.extension import Extension

extensions = [
    Extension(
        name="dynamic_font",              # Tên module khi bạn 'import'
        sources=["dynamic_font_v2.pyx"], # File nguồn thực tế của bạn
    )
]

setup(
    ext_modules=cythonize(extensions, language_level="3"),
)
