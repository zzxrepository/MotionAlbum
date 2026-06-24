@echo off
powershell -Command "$s=New-Object -ComObject WScript.Shell;$d=[Environment]::GetFolderPath('Desktop');$l=$s.CreateShortcut((Join-Path $d 'LivePhotoViewer.lnk'));$l.TargetPath='%~dp0start.bat';$l.WorkingDirectory='%~dp0';$l.IconLocation='%~dp0LivePhotoViewer.WPF\Assets\app_icon.ico';$l.Description='LivePhoto Viewer';$l.Save();Write-Host 'Done'"
pause
