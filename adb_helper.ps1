#Requires -Version 5.1
<#
.SYNOPSIS
    通过 ADB 从荣耀/华为手机批量拉取动态照片并提取视频
.DESCRIPTION
    1. 自动搜索 adb.exe（常见路径）
    2. 检测已连接的手机并开启 USB 调试
    3. 从手机 /sdcard/DCIM/Camera 拉取 JPG 文件到本地
    4. 调用 honor_livephoto_extractor.py 批量提取实况视频
.NOTES
    使用前请确保：
    - 手机已开启 USB 调试（设置 -> 开发者选项 -> USB 调试）
    - 电脑上安装了 Android Platform Tools（包含 adb.exe）
#>

$ErrorActionPreference = "Stop"

# ========== 1. 搜索 adb.exe ==========
function Find-Adb {
    $candidates = @(
        "adb.exe",
        "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe",
        "$env:PROGRAMFILES\Android\platform-tools\adb.exe",
        "${env:PROGRAMFILES(x86)}\Android\platform-tools\adb.exe",
        "C:\platform-tools\adb.exe",
        "D:\platform-tools\adb.exe",
        "$env:USERPROFILE\Downloads\platform-tools\adb.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return (Resolve-Path $c).Path }
    }
    # 最后尝试 PATH
    $inPath = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($inPath) { return $inPath.Source }
    return $null
}

$Adb = Find-Adb
if (-not $Adb) {
    Write-Host "❌ 未找到 adb.exe" -ForegroundColor Red
    Write-Host ""
    Write-Host "请按以下步骤安装 ADB："
    Write-Host "  1. 访问 https://developer.android.com/studio/releases/platform-tools"
    Write-Host "  2. 下载 Windows 版的 Platform Tools"
    Write-Host "  3. 解压到任意文件夹（如 C:\platform-tools）"
    Write-Host "  4. 将 adb.exe 所在目录添加到系统 PATH，或放到本脚本同级目录"
    Write-Host ""
    Write-Host "同时请确保手机已开启 USB 调试："
    Write-Host "  设置 -> 关于手机 -> 连续点击版本号 7 次开启开发者模式"
    Write-Host "  设置 -> 系统和更新 -> 开发人员选项 -> USB 调试 -> 开启"
    exit 1
}
Write-Host "✅ 找到 ADB: $Adb" -ForegroundColor Green

# ========== 2. 检测设备 ==========
Write-Host ""
Write-Host "正在检测连接的设备..."
$devices = & $Adb devices | Select-String "device$"
if (-not $devices) {
    Write-Host "❌ 未检测到已连接的设备，请检查：" -ForegroundColor Red
    Write-Host "  - 手机是否通过 USB 连接"
    Write-Host "  - USB 调试是否已开启"
    Write-Host "  - 手机上是否允许了这台电脑的调试授权"
    exit 1
}
Write-Host "✅ 已连接设备:" -ForegroundColor Green
$devices | ForEach-Object { Write-Host "   $_" }

# ========== 3. 选择工作目录 ==========
$Workspace = Split-Path -Parent $MyInvocation.MyCommand.Definition
$PhoneCamera = "/sdcard/DCIM/Camera"
$LocalDir = Join-Path $Workspace "from_phone"
New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null

Write-Host ""
Write-Host "工作目录: $LocalDir"

# ========== 4. 列出手机照片 ==========
Write-Host ""
Write-Host "正在列出手机 Camera 目录中的 JPG 文件..."
$remoteFiles = & $Adb shell "ls -1 $PhoneCamera/*.jpg 2>/dev/null" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
$total = ($remoteFiles | Measure-Object).Count
Write-Host "找到 $total 个 JPG 文件"

if ($total -eq 0) {
    Write-Host "没有找到 JPG 文件，退出。"
    exit 0
}

# ========== 5. 拉取文件 ==========
Write-Host ""
Write-Host "开始拉取文件到本地（跳过已存在的）..."
$pulled = 0
foreach ($rf in $remoteFiles) {
    $name = Split-Path $rf -Leaf
    $localFile = Join-Path $LocalDir $name
    if (Test-Path $localFile) {
        Write-Host "  [SKIP] $name"
        continue
    }
    & $Adb pull "$rf" "$localFile" | Out-Null
    Write-Host "  [PULL] $name"
    $pulled++
}
Write-Host "拉取完成: $pulled 个新文件"

# ========== 6. 调用 Python 提取工具 ==========
$Python = "C:\ProgramData\anaconda3\python.exe"
if (-not (Test-Path $Python)) {
    $Python = "$env:USERPROFILE\anaconda3\python.exe"
}
if (-not (Test-Path $Python)) {
    $Python = "python.exe"
}

$Extractor = Join-Path $Workspace "honor_livephoto_extractor.py"
if (-not (Test-Path $Extractor)) {
    Write-Host "❌ 未找到提取工具: $Extractor" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "开始批量提取实况视频..."
& $Python $Extractor -b "$LocalDir" --html --overwrite

Write-Host ""
Write-Host "🎉 全部完成！输出目录: $LocalDir"
Write-Host "   HTML 查看器: $(Join-Path $LocalDir 'live_photo_viewer.html')"
