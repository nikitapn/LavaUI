@echo off
setlocal

echo Cleaning build directories...

if exist ".build.MSVC.Debug" (
    echo Removing .build.MSVC.Debug
    rmdir /s /q ".build.MSVC.Debug"
)

if exist ".build.MSVC.Release" (
    echo Removing .build.MSVC.Release
    rmdir /s /q ".build.MSVC.Release"
)

if exist ".build.MinGW.Debug" (
    echo Removing .build.MinGW.Debug
    rmdir /s /q ".build.MinGW.Debug"
)

if exist ".build.MinGW.Release" (
    echo Removing .build.MinGW.Release
    rmdir /s /q ".build.MinGW.Release"
)

if exist ".build.MSVC" (
    echo Removing .build.MSVC
    rmdir /s /q ".build.MSVC"
)

rem Clean temporary files
if exist "temp_filelist.txt" del "temp_filelist.txt"
if exist "last_filelist.txt" del "last_filelist.txt"

echo Clean completed!
