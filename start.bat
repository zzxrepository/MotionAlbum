@echo off
cd /d "%~dp0LivePhotoViewer.WPF"

where dotnet > nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] dotnet not found. Please install .NET SDK.
    pause
    exit /b 1
)

echo ==========================================
echo    LivePhoto Viewer
echo ==========================================
echo.
echo Starting...
echo.

dotnet run

if %errorlevel% neq 0 (
    echo.
    echo [ERROR] Start failed.
    pause
)
