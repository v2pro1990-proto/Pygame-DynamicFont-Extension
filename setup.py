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
    version="1.0.0",                       
    author="v2pro1990",                    
    description="Font rendering Extesion for Pygame and Pygame-CE",
    ext_modules=cythonize(extensions, compiler_directives={'language_level': "3"}),
)