@echo off

rem call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" x64

set VULKAN_SDK=C:\opt\VulkanSDK\1.4.309.0
set GLFW3_ROOT=C:\opt\glfw-3.4.bin.WIN64
set BOOST_DIR=C:\opt\boost_1_88_0

cmake -S . -B .build.MSVC -G "Visual Studio 17 2022"
