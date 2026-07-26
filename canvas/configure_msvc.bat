@echo off
setlocal

rem Configure environment variables for your system
set VULKAN_SDK=C:\opt\VulkanSDK\1.4.309.0
set GLFW3_ROOT=C:\opt\glfw-3.4.bin.WIN64
set BOOST_DIR=C:\opt\boost_1_88_0

rem Initialize MSVC environment (adjust path as needed)
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" x64

rem Set build type (Debug or Release)
if "%1"=="" (
    set BUILD_TYPE=Debug
) else (
    set BUILD_TYPE=%1
)

set BUILD_DIR=.build.MSVC.%BUILD_TYPE%

echo Configuring for %BUILD_TYPE% build in %BUILD_DIR%

rem Configure with Ninja for faster builds (or use "NMake Makefiles")
cmake -S . -B %BUILD_DIR% -G "Ninja" ^
    -DCMAKE_BUILD_TYPE=%BUILD_TYPE% ^
    -DCMAKE_C_COMPILER=cl ^
    -DCMAKE_CXX_COMPILER=cl ^
    -DVULKAN_SDK=%VULKAN_SDK% ^
    -DGLFW3_ROOT=%GLFW3_ROOT% ^
    -DBOOST_DIR=%BOOST_DIR%

if %ERRORLEVEL% neq 0 (
    echo Configuration failed!
    exit /b %ERRORLEVEL%
)

echo Configuration completed successfully!
echo To build, run: build_msvc.bat [Debug/Release]
echo To build and run, use: build_msvc.bat [Debug/Release] run
