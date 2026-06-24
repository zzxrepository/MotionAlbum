@echo off
chcp 65001 > nul
cd /d "%~dp0LivePhotoViewer.WPF"

:: 检查 dotnet 是否可用
where dotnet > nul 2>&1
if %errorlevel% neq 0 (
    echo [错误] 未找到 dotnet 命令，请确保已安装 .NET SDK
    pause
    exit /b 1
)

echo ==========================================
echo    图片查看器 - 神马都会亿点点的毛毛张
echo ==========================================
echo.
echo 正在启动...
echo.

dotnet run

if %errorlevel% neq 0 (
    echo.
    echo [错误] 启动失败，按任意键退出...
    pause
)
