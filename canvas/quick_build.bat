@echo off
setlocal

rem Quick build script - configures and builds in one go
rem Usage: quick_build.bat [msvc|mingw] [Debug|Release] [run]

set COMPILER=msvc
set BUILD_TYPE=Debug
set RUN_AFTER=

rem Parse arguments
if not "%1"=="" set COMPILER=%1
if not "%2"=="" set BUILD_TYPE=%2
if "%3"=="run" set RUN_AFTER=run

echo Quick build using %COMPILER% compiler in %BUILD_TYPE% mode

if /i "%COMPILER%"=="msvc" (
    echo Configuring with MSVC...
    call configure_msvc.bat %BUILD_TYPE%
    if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
    
    echo Building with MSVC...
    call build_msvc.bat %BUILD_TYPE% %RUN_AFTER%
) else if /i "%COMPILER%"=="mingw" (
    echo Configuring with MinGW...
    call configure_mingw.bat %BUILD_TYPE%
    if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
    
    echo Building with MinGW...
    call build_mingw.bat %BUILD_TYPE% %RUN_AFTER%
) else (
    echo Invalid compiler: %COMPILER%
    echo Usage: quick_build.bat [msvc^|mingw] [Debug^|Release] [run]
    exit /b 1
)
