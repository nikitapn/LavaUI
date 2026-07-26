@echo off
setlocal

rem Add MinGW-w64 to PATH (adjust path as needed)
set MINGW_PATH=C:\msys64\mingw64\bin
set PATH=%MINGW_PATH%;%PATH%

rem Set build type (Debug or Release)
if "%1"=="" (
    set BUILD_TYPE=Debug
) else (
    set BUILD_TYPE=%1
)

set BUILD_DIR=.build.MinGW.%BUILD_TYPE%

if not exist "%BUILD_DIR%" (
    echo Build directory %BUILD_DIR% does not exist. Run configure_mingw.bat first.
    exit /b 1
)

echo Building %BUILD_TYPE% configuration with MinGW-w64...

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
    cd %BUILD_DIR%\bin
    2d.exe
)
