@echo off
cd /d "%~dp0LivePhotoViewer.WPF"

echo ==========================================
echo    Publish LivePhoto Viewer
echo ==========================================
echo.

dotnet publish -c Release -o "../publish" --self-contained false -p:PublishSingleFile=true

if %errorlevel% neq 0 (
    echo [ERROR] Publish failed.
    pause
    exit /b 1
)

echo.
echo [OK] Published to: %~dp0publish
echo.
pause
