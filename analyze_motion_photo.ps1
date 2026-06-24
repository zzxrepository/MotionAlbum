# Analyze JPG files for Motion Photo / embedded MP4 data
$sampleDir = "e:\DevWorkspace\Tests\TraeTutorialsProjectCode\14_Project_Cursor_Test\samples"

function Find-JpegEoi($bytes) {
    $lastEoi = -1
    for ($i = 0; $i -lt $bytes.Length - 1; $i++) {
        if ($bytes[$i] -eq 0xFF -and $bytes[$i+1] -eq 0xD9) {
            $lastEoi = $i
        }
    }
    return $lastEoi
}

function Find-Mp4Signature($bytes, $startOffset) {
    $signatures = @(
        [byte[]](0x66, 0x74, 0x79, 0x70),  # ftyp
        [byte[]](0x6D, 0x6F, 0x6F, 0x76),  # moov
        [byte[]](0x6D, 0x64, 0x61, 0x74)   # mdat
    )
    $results = @()
    for ($i = $startOffset; $i -lt $bytes.Length - 8; $i++) {
        foreach ($sig in $signatures) {
            $match = $true
            for ($j = 0; $j -lt 4; $j++) {
                if ($bytes[$i + $j] -ne $sig[$j]) { $match = $false; break }
            }
            if ($match) {
                # Read box size (big-endian) from 4 bytes before signature
                if ($i -ge 4) {
                    $boxSize = ([uint32]$bytes[$i-4] -shl 24) -bor ([uint32]$bytes[$i-3] -shl 16) -bor ([uint32]$bytes[$i-2] -shl 8) -bor [uint32]$bytes[$i-1]
                    if ($boxSize -gt 8 -and $boxSize -lt $bytes.Length) {
                        $results += @{ Offset=$i-4; Type=[System.Text.Encoding]::ASCII.GetString($sig); Size=$boxSize }
                    }
                }
            }
        }
    }
    return $results
}

Get-ChildItem $sampleDir -Filter "*.jpg" | Sort-Object Name | ForEach-Object {
    $path = $_.FullName
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $sizeKb = [math]::Round($_.Length / 1KB, 1)

    Write-Host "`n📄 $($_.Name) ($sizeKb KB)"

    $eoi = Find-JpegEoi $bytes
    if ($eoi -ge 0) {
        $trailing = $bytes.Length - ($eoi + 2)
        Write-Host "   JPEG EOI at: $eoi (0x$($eoi.ToString('X')))"
        Write-Host "   Trailing bytes after EOI: $trailing"

        if ($trailing -gt 100) {
            $mp4Sigs = Find-Mp4Signature $bytes ($eoi + 2)
            if ($mp4Sigs.Count -gt 0) {
                $first = $mp4Sigs | Sort-Object Offset | Select-Object -First 1
                Write-Host "   ✅ FOUND MP4 box '$($first.Type)' at offset $($first.Offset) (0x$($first.Offset.ToString('X')))"
                Write-Host "   ✅ LIKELY MOTION PHOTO!"

                # Extract MP4
                $mp4Offset = $first.Offset
                $mp4Data = $bytes[$mp4Offset..($bytes.Length-1)]
                $mp4Path = $path -replace '\.jpg$', '_extracted.mp4'
                [System.IO.File]::WriteAllBytes($mp4Path, $mp4Data)
                Write-Host "   💾 Extracted $($mp4Data.Length) bytes -> $(Split-Path $mp4Path -Leaf)"
            } else {
                Write-Host "   No MP4 signature found in trailing data"
            }
        }
    } else {
        Write-Host "   No JPEG EOI marker found"
    }

    # Check for XMP motion photo markers in text
    $text = [System.Text.Encoding]::ASCII.GetString($bytes)
    $markers = @('MotionPhoto', 'MicroVideo', 'GCamera:MotionPhoto', 'HONOR:MotionPhoto', 'Huawei:MotionPhoto')
    $foundMarker = $false
    foreach ($m in $markers) {
        if ($text.Contains($m)) {
            Write-Host "   🏷️  XMP marker found: $m"
            $foundMarker = $true
            break
        }
    }
    if (-not $foundMarker) {
        Write-Host "   No XMP motion photo markers"
    }
}

Write-Host "`n✅ Analysis complete."
