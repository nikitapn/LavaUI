@echo off
setlocal

rem Set build type (Debug or Release)
if "%1"=="" (
    set BUILD_TYPE=Debug
) else (
    set BUILD_TYPE=%1
)

set BUILD_DIR=.build.MSVC.%BUILD_TYPE%

if not exist "%BUILD_DIR%" (
    echo Build directory %BUILD_DIR% does not exist. Run configure_msvc.bat first.
    exit /b 1
)

rem Initialize MSVC environment
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" x64

echo Building %BUILD_TYPE% configuration...

rem Build the project
cmake --build %BUILD_DIR% --config %BUILD_TYPE% --target all --parallel

if %ERRORLEVEL% neq 0 (
    echo Build failed!
    exit /b %ERRORLEVEL%
)

echo Build completed successfully!

rem Run if requested
if "%2"=="run" (
    echo Running application...
    %BUILD_DIR%\2d.exe
)
