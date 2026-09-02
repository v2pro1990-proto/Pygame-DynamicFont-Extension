@echo off
setlocal enabledelayedexpansion

REM ============================================================
REM  build_all.bat -- Builds zlib -> libpng -> FreeType (with PNG)
REM  for x64, x86 (Win32), AND ARM64 Python, then cleans up the
REM  source trees. ONE script, no separate cleanup step needed.
REM
REM  WINDOWS ONLY. Linux/macOS do NOT need this script at all —
REM  both platforms already have a PNG-enabled FreeType available
REM  through their normal package manager (apt/brew), which
REM  setup.py finds automatically via pkg-config. This script
REM  exists only because Windows has no equivalent system package
REM  manager for these C libraries, so building from source is the
REM  only option there.
REM
REM  Must be run from "x64 Native Tools Command Prompt for VS"
REM  (the x64 tools prompt can ALSO cross-target x86 and ARM64 via
REM  the -A flag below — no separate prompt needed for those, but
REM  ARM64 DOES require the "C++ ARM64/ARM64EC build tools"
REM  component installed through the Visual Studio Installer, or
REM  its CMake configure step will fail to find a working compiler).
REM
REM  Expected directory layout (run this script from the root):
REM    .\freetype_src\   (will be git-cloned if missing)
REM    .\zlib\           (will be git-cloned if missing)
REM    .\libpng\         (will be git-cloned if missing)
REM
REM  None of the 3 dependency source trees need to be committed to
REM  your repo — this script clones all of them fresh as needed.
REM
REM  Output layout (separate per architecture, since a build for
REM  one architecture cannot link against another architecture's
REM  static libs):
REM    C:\deps\x64\lib\{zlibstatic,libpng16_static}.lib
REM    C:\deps\x86\lib\{zlibstatic,libpng16_static}.lib
REM    C:\deps\arm64\lib\{zlibstatic,libpng16_static}.lib
REM    freetype_src\build_x64\Release\freetype.lib
REM    freetype_src\build_x86\Release\freetype.lib
REM    freetype_src\build_arm64\Release\freetype.lib
REM  setup.py picks the right one automatically based on which
REM  Python interpreter (32-bit, 64-bit, or ARM64) is running the
REM  build.
REM ============================================================

set DEPS_ROOT=C:\deps
if "%GENERATOR%"=="" set GENERATOR=Visual Studio 18 2026

echo.
echo === Checking required tools ===
where cmake >nul 2>nul
if errorlevel 1 (
    echo [ERROR] cmake not found in PATH.
    echo         Run this script from "x64 Native Tools Command Prompt for VS".
    exit /b 1
)
where cl >nul 2>nul
if errorlevel 1 (
    echo [ERROR] cl.exe not found in PATH.
    echo         Run this script from "x64 Native Tools Command Prompt for VS".
    exit /b 1
)
where git >nul 2>nul
if errorlevel 1 (
    echo [ERROR] git not found in PATH.
    exit /b 1
)
echo [OK] cmake / cl.exe / git are all available.

REM ------------------------------------------------------------
REM Build all three architectures by calling the same subroutine
REM three times. CMAKE_ARCH is the -A value CMake expects ("x64",
REM "Win32", or "ARM64"); DEPS_SUBDIR/FT_BUILD_SUBDIR are where
REM THIS architecture's artifacts get placed, kept separate from
REM the others.
REM
REM ARM64 is cross-compiled from this same Intel machine — MSVC
REM supports this natively via its ARM64 cross toolset (installed
REM by the "C++ ARM64/ARM64EC build tools" Visual Studio component
REM — make sure that's installed, or this step will fail to find a
REM working ARM64 compiler even though cmake configure may still
REM appear to succeed). This is a NEWER, LESS-TESTED path than
REM x64/x86 — if it fails, x64 and x86 builds are unaffected (each
REM architecture's failure is independent).
REM ------------------------------------------------------------
call :build_one_arch x64 x64 build_x64
if errorlevel 1 exit /b 1

call :build_one_arch Win32 x86 build_x86
if errorlevel 1 exit /b 1

call :build_one_arch ARM64 arm64 build_arm64
if errorlevel 1 exit /b 1

echo.
echo ============================================================
echo   DONE! All three architectures built successfully:
echo     x64:   %DEPS_ROOT%\x64\lib\zlibstatic.lib
echo            %DEPS_ROOT%\x64\lib\libpng16_static.lib
echo            freetype_src\build_x64\Release\freetype.lib
echo     x86:   %DEPS_ROOT%\x86\lib\zlibstatic.lib
echo            %DEPS_ROOT%\x86\lib\libpng16_static.lib
echo            freetype_src\build_x86\Release\freetype.lib
echo     arm64: %DEPS_ROOT%\arm64\lib\zlibstatic.lib
echo            %DEPS_ROOT%\arm64\lib\libpng16_static.lib
echo            freetype_src\build_arm64\Release\freetype.lib
echo.
echo   setup.py auto-detects which one to link against based on
echo   the Python interpreter's own architecture.
echo ============================================================
exit /b 0

REM ============================================================
REM Subroutine: build zlib -> libpng -> FreeType for one CMake
REM architecture value. %1=CMAKE_ARCH  %2=DEPS_SUBDIR  %3=FT_BUILD_SUBDIR
REM ============================================================
:build_one_arch
set CMAKE_ARCH=%~1
set DEPS_SUBDIR=%~2
set FT_BUILD_SUBDIR=%~3
set DEPS_PREFIX=%DEPS_ROOT%\%DEPS_SUBDIR%

echo.
echo ############################################################
echo   Building architecture: %CMAKE_ARCH%  (output: %DEPS_SUBDIR%)
echo ############################################################

REM --------------------------------------------------------
REM Step 1: zlib
REM --------------------------------------------------------
echo.
echo === [%DEPS_SUBDIR%] STEP 1/4: zlib ===
if not exist zlib (
    git clone -b v1.3.1 --depth 1 https://github.com/madler/zlib.git
    if errorlevel 1 (
        echo [ERROR] git clone zlib failed.
        exit /b 1
    )
) else (
    echo [SKIP] zlib directory already exists, not re-cloning.
)

cmake -G "%GENERATOR%" -A %CMAKE_ARCH% -B zlib\build_%DEPS_SUBDIR% -S zlib ^
    -DCMAKE_INSTALL_PREFIX="%DEPS_PREFIX%" ^
    -DCMAKE_BUILD_TYPE=Release ^
    -DBUILD_SHARED_LIBS=OFF ^
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
if errorlevel 1 (
    echo [ERROR] CMake configure step failed for zlib [%DEPS_SUBDIR%].
    exit /b 1
)

cmake --build zlib\build_%DEPS_SUBDIR% --config Release --target install
if errorlevel 1 (
    echo [ERROR] Build/install step failed for zlib [%DEPS_SUBDIR%].
    exit /b 1
)

if not exist "%DEPS_PREFIX%\lib\zlibstatic.lib" (
    echo [ERROR] zlibstatic.lib was not produced - check the log above.
    exit /b 1
)
echo [OK] zlib [%DEPS_SUBDIR%] done: %DEPS_PREFIX%\lib\zlibstatic.lib

REM --------------------------------------------------------
REM Step 2: libpng
REM --------------------------------------------------------
echo.
echo === [%DEPS_SUBDIR%] STEP 2/4: libpng ===
if not exist libpng (
    git clone -b v1.6.44 --depth 1 https://github.com/pnggroup/libpng.git
    if errorlevel 1 (
        echo [ERROR] git clone libpng failed.
        exit /b 1
    )
) else (
    echo [SKIP] libpng directory already exists, not re-cloning.
)

cmake -G "%GENERATOR%" -A %CMAKE_ARCH% -B libpng\build_%DEPS_SUBDIR% -S libpng ^
    -DCMAKE_PREFIX_PATH="%DEPS_PREFIX%" ^
    -DCMAKE_INSTALL_PREFIX="%DEPS_PREFIX%" ^
    -DCMAKE_BUILD_TYPE=Release ^
    -DPNG_SHARED=OFF -DPNG_TESTS=OFF ^
    -DZLIB_LIBRARY="%DEPS_PREFIX%\lib\zlibstatic.lib" ^
    -DZLIB_INCLUDE_DIR="%DEPS_PREFIX%\include" ^
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
if errorlevel 1 (
    echo [ERROR] CMake configure step failed for libpng [%DEPS_SUBDIR%].
    exit /b 1
)

cmake --build libpng\build_%DEPS_SUBDIR% --config Release --target install
if errorlevel 1 (
    echo [ERROR] Build/install step failed for libpng [%DEPS_SUBDIR%].
    exit /b 1
)

if not exist "%DEPS_PREFIX%\lib\libpng16_static.lib" (
    echo [ERROR] libpng16_static.lib was not produced - check the log above.
    exit /b 1
)
echo [OK] libpng [%DEPS_SUBDIR%] done: %DEPS_PREFIX%\lib\libpng16_static.lib

REM --------------------------------------------------------
REM Step 3: FreeType (force-enable PNG)
REM --------------------------------------------------------
echo.
echo === [%DEPS_SUBDIR%] STEP 3/4: FreeType (with PNG) ===
if not exist freetype_src (
    git clone -b VER-2-13-3 --depth 1 https://gitlab.freedesktop.org/freetype/freetype.git freetype_src
    if errorlevel 1 (
        echo [ERROR] git clone freetype_src failed.
        exit /b 1
    )
) else (
    echo [SKIP] freetype_src directory already exists, not re-cloning.
)

REM Deleting the old per-arch build dir is MANDATORY - FreeType
REM overwrites ftoption.h directly inside the source tree, so
REM without this step a previous PNG=OFF build state would
REM silently persist. Each architecture gets its OWN build dir
REM (build_x64 / build_x86) so building one never clobbers the
REM other's CMake cache.
if exist freetype_src\%FT_BUILD_SUBDIR% (
    echo Removing old freetype_src\%FT_BUILD_SUBDIR%...
    rmdir /s /q freetype_src\%FT_BUILD_SUBDIR%
)

cmake -G "%GENERATOR%" -A %CMAKE_ARCH% -B freetype_src\%FT_BUILD_SUBDIR% -S freetype_src ^
    -DCMAKE_PREFIX_PATH="%DEPS_PREFIX%" ^
    -DCMAKE_BUILD_TYPE=Release ^
    -DFT_REQUIRE_PNG=ON ^
    -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_BROTLI=ON ^
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
if errorlevel 1 (
    echo [ERROR] CMake configure step failed for FreeType [%DEPS_SUBDIR%].
    exit /b 1
)

cmake --build freetype_src\%FT_BUILD_SUBDIR% --config Release
if errorlevel 1 (
    echo [ERROR] Build step failed for FreeType [%DEPS_SUBDIR%].
    exit /b 1
)

if not exist "freetype_src\%FT_BUILD_SUBDIR%\Release\freetype.lib" (
    echo [ERROR] freetype.lib was not produced - check the log above.
    exit /b 1
)
echo [OK] FreeType [%DEPS_SUBDIR%] done: freetype_src\%FT_BUILD_SUBDIR%\Release\freetype.lib

REM --------------------------------------------------------
REM Step 4: Clean up non-essential files (only once, after the
REM SECOND architecture finishes — see the guard below).
REM --------------------------------------------------------
if not "%DEPS_SUBDIR%"=="arm64" goto :skip_cleanup_here
echo.
echo === STEP 4/4: Cleaning up source trees ===
if "%SKIP_CLEAN%"=="1" (
    echo [SKIP] SKIP_CLEAN=1 was set - leaving source trees untouched.
    goto :skip_cleanup_here
)

if exist zlib (
    if exist zlib\.git rmdir /s /q zlib\.git
    if exist zlib\test rmdir /s /q zlib\test
    if exist zlib\doc rmdir /s /q zlib\doc
    if exist zlib\contrib rmdir /s /q zlib\contrib
    if exist zlib\examples rmdir /s /q zlib\examples
    del /q zlib\*.md 2>nul
    del /q zlib\ChangeLog* 2>nul
    del /q zlib\FAQ 2>nul
)
if exist libpng (
    if exist libpng\.git rmdir /s /q libpng\.git
    if exist libpng\tests rmdir /s /q libpng\tests
    if exist libpng\contrib rmdir /s /q libpng\contrib
    if exist libpng\projects rmdir /s /q libpng\projects
    if exist libpng\scripts rmdir /s /q libpng\scripts
    del /q libpng\*.md 2>nul
    del /q libpng\ANNOUNCE 2>nul
    del /q libpng\CHANGES 2>nul
    del /q libpng\TODO 2>nul
    del /q libpng\TRADEMARK 2>nul
)
if exist freetype_src (
    if exist freetype_src\.git rmdir /s /q freetype_src\.git
    if exist freetype_src\docs rmdir /s /q freetype_src\docs
    if exist freetype_src\tests rmdir /s /q freetype_src\tests
    if exist freetype_src\subprojects rmdir /s /q freetype_src\subprojects
    del /q freetype_src\.clang-format 2>nul
    del /q freetype_src\.gitlab-ci.yml 2>nul
    del /q freetype_src\.gitmodules 2>nul
    del /q freetype_src\.mailmap 2>nul
    del /q freetype_src\autogen.sh 2>nul
    del /q freetype_src\configure 2>nul
    del /q freetype_src\meson.build 2>nul
    del /q freetype_src\meson_options.txt 2>nul
    del /q freetype_src\README.git 2>nul
    del /q freetype_src\vms_make.com 2>nul
)
echo [OK] Source trees cleaned (LICENSE files intentionally kept everywhere).
:skip_cleanup_here

exit /b 0
