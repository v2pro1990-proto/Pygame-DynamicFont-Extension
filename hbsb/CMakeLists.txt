# Builds HarfBuzz and SheenBidi (their unity sources, vendored in
# ../harfbuzz_src and ../sheenbidi_src) ONCE into static libraries, the same
# way build_all.bat / cibuildwheel's before-all build FreeType once — so each
# wheel links them instead of recompiling HarfBuzz (minutes) per Python
# version. setup.py links them when it finds them, and compiles the sources
# itself otherwise (e.g. a from-source install of the sdist).
#
#   cmake -S hbsb -B hbsb/build_x64 -A x64     (Windows; -A Win32 / ARM64)
#   cmake -S hbsb -B /tmp/hbsb_build -DCMAKE_BUILD_TYPE=Release   (Linux/macOS)
#   cmake --build <build dir> --config Release
#
# Output: <build dir>/lib/dynfont_harfbuzz.lib + dynfont_sheenbidi.lib
#         (libdynfont_harfbuzz.a + libdynfont_sheenbidi.a on Linux/macOS).
# The dynfont_ prefix keeps them from ever being mistaken for a system
# libharfbuzz.

cmake_minimum_required(VERSION 3.15)
project(dynfont_hbsb C CXX)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release)
endif()
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
# One output folder whatever the generator (Visual Studio adds /Release).
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY_RELEASE ${CMAKE_BINARY_DIR}/lib)

set(ROOT ${CMAKE_CURRENT_SOURCE_DIR}/..)

add_library(dynfont_harfbuzz STATIC ${ROOT}/harfbuzz_src/src/harfbuzz.cc)
target_include_directories(dynfont_harfbuzz PRIVATE ${ROOT}/harfbuzz_src/src)

add_library(dynfont_sheenbidi STATIC ${ROOT}/sheenbidi_src/Source/SheenBidi.c)
target_include_directories(dynfont_sheenbidi PRIVATE ${ROOT}/sheenbidi_src/Headers ${ROOT}/sheenbidi_src/Source)
target_compile_definitions(dynfont_sheenbidi PRIVATE SB_CONFIG_UNITY)

# Same flags setup.py uses for these sources, minus whole-program
# optimisation (/GL, -flto): with it the libraries would hold compiler IR and
# all of HarfBuzz would still be code-generated at every wheel's link.
if(MSVC)
  # No C++ exceptions / RTTI (HarfBuzz uses neither): otherwise the .pyd
  # imports __CxxFrameHandler4 from VCRUNTIME140_1.dll, missing on older
  # installs. /Gy /Gw let the linker drop what the extension never calls.
  string(REPLACE "/EHsc" "" CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS}")
  string(REPLACE "/GR" "" CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS}")
  foreach(t dynfont_harfbuzz dynfont_sheenbidi)
    target_compile_options(${t} PRIVATE /O2 /fp:fast /Gy /Gw)
    target_compile_definitions(${t} PRIVATE _CRT_SECURE_NO_WARNINGS)
  endforeach()
  target_compile_options(dynfont_harfbuzz PRIVATE /EHs-c- /GR-)
  target_compile_definitions(dynfont_harfbuzz PRIVATE _HAS_EXCEPTIONS=0)
else()
  foreach(t dynfont_harfbuzz dynfont_sheenbidi)
    target_compile_options(${t} PRIVATE -O3 -fno-math-errno -fomit-frame-pointer)
  endforeach()
  # HarfBuzz: memory-map font files. HAVE_MMAP only switches the mmap code
  # on — <sys/mman.h> / <unistd.h> (mmap, munmap, close) are included only
  # with HAVE_SYS_MMAN_H / HAVE_UNISTD_H, which HarfBuzz's own build always
  # sets together with it.
  target_compile_definitions(dynfont_harfbuzz PRIVATE HAVE_MMAP=1 HAVE_SYS_MMAN_H=1 HAVE_UNISTD_H=1)
endif()
