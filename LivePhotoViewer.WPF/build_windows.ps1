param(
    [ValidateSet("win-x64", "win-x86")]
    [string]$Runtime = "win-x64",
    [switch]$Package
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repositoryRoot = Split-Path -Parent $projectRoot
$projectFile = Join-Path $projectRoot "LivePhotoViewer.WPF.csproj"
$selfTestProject = Join-Path $repositoryRoot "LivePhotoViewer.WPF.SelfTest/LivePhotoViewer.WPF.SelfTest.csproj"
$samples = Join-Path $repositoryRoot "samples"
$distRoot = Join-Path $projectRoot "dist"
$publishDirectory = Join-Path $distRoot "MotionAlbum-$Runtime"

Write-Host "[1/3] 运行多品牌实况照片解析自检..." -ForegroundColor Cyan
dotnet run --project $selfTestProject -c Release -- $samples

Write-Host "[2/3] 发布 Windows 自包含版本 ($Runtime)..." -ForegroundColor Cyan
if (Test-Path $publishDirectory) {
    Remove-Item -LiteralPath $publishDirectory -Recurse -Force
}
dotnet publish $projectFile `
    -c Release `
    -r $Runtime `
    --self-contained true `
    -p:PublishSingleFile=false `
    -p:DebugType=None `
    -p:DebugSymbols=false `
    -o $publishDirectory

# VideoLAN.Windows 同时携带 x86/x64 两套原生库，发布时只保留当前架构。
$unusedVlcRuntime = if ($Runtime -eq "win-x64") { "win-x86" } else { "win-x64" }
$unusedVlcDirectory = Join-Path $publishDirectory "libvlc/$unusedVlcRuntime"
if (Test-Path $unusedVlcDirectory) {
    Remove-Item -LiteralPath $unusedVlcDirectory -Recurse -Force
}

$executable = Join-Path $publishDirectory "MotionAlbum.exe"
if (-not (Test-Path $executable)) {
    throw "发布失败：没有生成 $executable"
}

Write-Host "[3/3] 完成：$executable" -ForegroundColor Green
if ($Package) {
    [xml]$projectXml = Get-Content -LiteralPath $projectFile
    $version = $projectXml.Project.PropertyGroup.Version | Select-Object -First 1
    $archive = Join-Path $distRoot "MotionAlbum-v$version-$Runtime.zip"
    if (Test-Path $archive) { Remove-Item -LiteralPath $archive -Force }
    Compress-Archive -Path (Join-Path $publishDirectory "*") -DestinationPath $archive -CompressionLevel Optimal
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$archive.sha256" -Value "$hash  $(Split-Path -Leaf $archive)" -Encoding ascii
    Write-Host "安装包：$archive" -ForegroundColor Green
    Write-Host "校验值：$archive.sha256" -ForegroundColor Green
}
