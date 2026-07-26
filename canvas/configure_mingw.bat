@echo off
setlocal

rem Configure environment variables for your system
set VULKAN_SDK=C:\opt\VulkanSDK\1.4.309.0
set GLFW3_ROOT=C:\opt\glfw-3.4.bin.WIN64
set BOOST_DIR=C:\opt\boost_1_88_0

rem Add MinGW-w64 to PATH (adjust path as needed)
rem Download from: https://www.mingw-w64.org/downloads/ or use MSYS2
set MINGW_PATH=C:\msys64\mingw64\bin
set PATH=%MINGW_PATH%;%PATH%

rem Set build type (Debug or Release)
if "%1"=="" (
    set BUILD_TYPE=Debug
) else (
    set BUILD_TYPE=%1
)

set BUILD_DIR=.build.MinGW.%BUILD_TYPE%

echo Configuring for %BUILD_TYPE% build with MinGW-w64 in %BUILD_DIR%

rem Configure with MinGW Makefiles
cmake -S . -B %BUILD_DIR% -G "MinGW Makefiles" ^
    -DCMAKE_BUILD_TYPE=%BUILD_TYPE% ^
    -DCMAKE_C_COMPILER=gcc ^
    -DCMAKE_CXX_COMPILER=g++ ^
    -DVULKAN_SDK=%VULKAN_SDK% ^
    -DGLFW3_ROOT=%GLFW3_ROOT% ^
    -DBOOST_DIR=%BOOST_DIR%

if %ERRORLEVEL% neq 0 (
    echo Configuration failed!
    exit /b %ERRORLEVEL%
)

echo Configuration completed successfully!
echo To build, run: build_mingw.bat [Debug/Release]
echo To build and run, use: build_mingw.bat [Debug/Release] run
