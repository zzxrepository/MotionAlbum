# Copy sample files from phone Camera folder to local directory
$shell = New-Object -ComObject Shell.Application
$folder = $shell.Namespace(0x11)
$phone = $null
foreach ($item in $folder.Items()) {
    if ($item.Name -like '*magic8*') { $phone = $item; break }
}

if (-not $phone) {
    Write-Host "Phone not found"
    exit 1
}

$internal = $phone.GetFolder.Items() | Select-Object -First 1
$dcim = $internal.GetFolder.Items() | Where-Object { $_.Name -like '*DCIM*' }
$camera = $dcim.GetFolder.Items() | Where-Object { $_.Name -like '*Camera*' -or $_.Name -like '*camera*' }
$camFolder = $camera.GetFolder

$targetDir = "e:\DevWorkspace\Tests\TraeTutorialsProjectCode\14_Project_Cursor_Test\samples"
if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir | Out-Null }

# Find a few JPG files from 2026-06-17 (likely motion photos)
$sampleJpg = @()
foreach ($item in $camFolder.Items()) {
    if ($item.Name -match 'IMG_20260617.*\.jpg$') {
        $sampleJpg += $item
        if ($sampleJpg.Count -ge 5) { break }
    }
}

# Also copy one HEIC and one VID for comparison
$sampleHeic = $null
$sampleVid = $null
foreach ($item in $camFolder.Items()) {
    if (-not $sampleHeic -and $item.Name -match 'IMG_20260617.*\.HEIC$') { $sampleHeic = $item }
    if (-not $sampleVid -and $item.Name -match 'VID_20260617.*\.mp4$') { $sampleVid = $item }
    if ($sampleHeic -and $sampleVid) { break }
}

$dest = $shell.Namespace($targetDir)

Write-Host "Copying samples to $targetDir ..."
foreach ($f in $sampleJpg) {
    Write-Host "  Copying $($f.Name) ..."
    $dest.CopyHere($f, 16)
}
if ($sampleHeic) {
    Write-Host "  Copying $($sampleHeic.Name) ..."
    $dest.CopyHere($sampleHeic, 16)
}
if ($sampleVid) {
    Write-Host "  Copying $($sampleVid.Name) ..."
    $dest.CopyHere($sampleVid, 16)
}

Write-Host "Done. Files in $targetDir :"
Get-ChildItem $targetDir | ForEach-Object { Write-Host "  $($_.Name) - $([math]::Round($_.Length/1KB,1)) KB" }
