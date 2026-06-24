#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
图片查看器 (Live Photo Viewer)
开发者: 神马都会亿点点的毛毛张

启动方式:
    python -m livephoto_viewer.main
    或直接运行 run.bat
"""
import sys
import os

# 确保项目根目录在路径中
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from PyQt5.QtWidgets import QApplication
from PyQt5.QtCore import Qt
from PyQt5.QtGui import QFont

from livephoto_viewer.gui.main_window import MainWindow


def main():
    # 启用高分屏支持
    QApplication.setAttribute(Qt.AA_EnableHighDpiScaling, True)
    QApplication.setAttribute(Qt.AA_UseHighDpiPixmaps, True)

    app = QApplication(sys.argv)
    app.setFont(QFont("Microsoft YaHei", 10))
    app.setStyle("Fusion")

    window = MainWindow()
    window.show()
    sys.exit(app.exec_())


if __name__ == "__main__":
    main()
