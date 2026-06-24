@echo off
chcp 65001 > nul
cd /d "%~dp0LivePhotoViewer.WPF"

echo ==========================================
echo    发布 图片查看器
echo ==========================================
echo.

:: 发布为框架依赖（文件小，要求本机已装 .NET 10 运行时）
dotnet publish -c Release -o "../publish" --self-contained false -p:PublishSingleFile=true

if %errorlevel% neq 0 (
    echo [错误] 发布失败
    pause
    exit /b 1
)

echo.
echo [OK] 发布完成！输出目录: %~dp0publish
echo.
pause
