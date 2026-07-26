@echo off
setlocal enabledelayedexpansion

rem Development watch script - rebuilds when files change
rem Usage: dev_watch.bat [msvc|mingw] [Debug|Release]

set COMPILER=msvc
set BUILD_TYPE=Debug

if not "%1"=="" set COMPILER=%1
if not "%2"=="" set BUILD_TYPE=%2

echo Starting development watch mode with %COMPILER% compiler in %BUILD_TYPE% mode
echo Press Ctrl+C to stop watching...

rem Initial configuration and build
call quick_build.bat %COMPILER% %BUILD_TYPE%
if %ERRORLEVEL% neq 0 (
    echo Initial build failed! Fix errors and try again.
    pause
    exit /b %ERRORLEVEL%
)

echo.
echo Watching for changes in src/ directory...
echo.

:watch_loop
    rem Simple file change detection using dir command
    dir /s /a-d /tw src\*.cpp src\*.hpp src\*.h 2>nul | findstr /r "[0-9][0-9]:[0-9][0-9]" > temp_filelist.txt
    
    if not exist last_filelist.txt (
        copy temp_filelist.txt last_filelist.txt >nul
        goto wait
    )
    
    fc temp_filelist.txt last_filelist.txt >nul 2>&1
    if %ERRORLEVEL% neq 0 (
        echo.
        echo [%TIME%] Changes detected, rebuilding...
        echo.
        
        if /i "%COMPILER%"=="msvc" (
            call build_msvc.bat %BUILD_TYPE%
        ) else (
            call build_mingw.bat %BUILD_TYPE%
        )
        
        if %ERRORLEVEL% equ 0 (
            echo [%TIME%] Build successful!
        ) else (
            echo [%TIME%] Build failed!
        )
        echo.
        
        copy temp_filelist.txt last_filelist.txt >nul
    )
    
    :wait
    timeout /t 2 >nul
    goto watch_loop

rem Cleanup
del temp_filelist.txt 2>nul
del last_filelist.txt 2>nul
