@echo off
chcp 65001 >nul
call "D:\IDE\anaconda3\Scripts\activate.bat" livephoto_viewer
python -m livephoto_viewer.main
pause