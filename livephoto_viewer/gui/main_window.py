"""
主窗口 - 缩略图浏览与目录管理
"""
import os
from pathlib import Path

from PyQt5.QtWidgets import (
    QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QPushButton, QLabel, QFileDialog, QScrollArea, QGridLayout,
    QSizePolicy, QMessageBox
)
from PyQt5.QtCore import Qt, pyqtSignal
from PyQt5.QtGui import QFont

from ..core.favorites import FavoritesManager
from .thumbnail_widget import ThumbnailWidget
from .viewer_window import ViewerWindow


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("图片查看器")
        self.resize(1200, 800)
        self.setStyleSheet("background-color: #f5f5f7;")

        self.fav_manager = FavoritesManager()
        self.current_dir = ""
        self.jpg_files = []
        self.thumbnail_widgets = []
        self.viewer_window = None
        self.show_only_favorites = False

        self._setup_ui()
        self._setup_menu()

    def _setup_ui(self):
        central = QWidget()
        self.setCentralWidget(central)
        main_layout = QVBoxLayout(central)
        main_layout.setContentsMargins(16, 16, 16, 16)
        main_layout.setSpacing(12)

        # 顶部工具栏
        toolbar = QHBoxLayout()
        toolbar.setSpacing(10)

        self.btn_open = QPushButton("📂 选择文件夹")
        self.btn_open.setStyleSheet(self._btn_style("#007aff"))
        self.btn_open.setCursor(Qt.PointingHandCursor)
        self.btn_open.clicked.connect(self._choose_directory)

        self.btn_fav_filter = QPushButton("☆ 只显示收藏")
        self.btn_fav_filter.setCheckable(True)
        self.btn_fav_filter.setStyleSheet(self._btn_style("#ff9500"))
        self.btn_fav_filter.setCursor(Qt.PointingHandCursor)
        self.btn_fav_filter.toggled.connect(self._toggle_fav_filter)

        self.status_label = QLabel("请选择一个包含照片的文件夹")
        self.status_label.setFont(QFont("Microsoft YaHei", 10))
        self.status_label.setStyleSheet("color: #666;")

        toolbar.addWidget(self.btn_open)
        toolbar.addWidget(self.btn_fav_filter)
        toolbar.addStretch()
        toolbar.addWidget(self.status_label)
        main_layout.addLayout(toolbar)

        # 缩略图滚动区域
        self.scroll_area = QScrollArea()
        self.scroll_area.setWidgetResizable(True)
        self.scroll_area.setStyleSheet("border: none; background-color: transparent;")

        self.grid_widget = QWidget()
        self.grid_layout = QGridLayout(self.grid_widget)
        self.grid_layout.setSpacing(16)
        self.grid_layout.setContentsMargins(8, 8, 8, 8)
        self.scroll_area.setWidget(self.grid_widget)
        main_layout.addWidget(self.scroll_area, stretch=1)

    def _setup_menu(self):
        menubar = self.menuBar()
        file_menu = menubar.addMenu("文件(&F)")

        act_open = file_menu.addAction("打开文件夹...")
        act_open.setShortcut("Ctrl+O")
        act_open.triggered.connect(self._choose_directory)

        act_exit = file_menu.addAction("退出")
        act_exit.setShortcut("Alt+F4")
        act_exit.triggered.connect(self.close)

    def _btn_style(self, color: str) -> str:
        return f"""
            QPushButton {{
                background-color: {color};
                color: white;
                border-radius: 8px;
                padding: 8px 18px;
                font-size: 13px;
                font-weight: bold;
            }}
            QPushButton:hover {{
                background-color: {color};
                opacity: 0.8;
            }}
            QPushButton:checked {{
                background-color: #ff9500;
            }}
        """

    def _choose_directory(self):
        path = QFileDialog.getExistingDirectory(self, "选择照片文件夹", self.current_dir or os.path.expanduser("~"))
        if path:
            self.load_directory(path)

    def load_directory(self, path: str):
        self.current_dir = path
        self.jpg_files = sorted([
            str(p) for p in Path(path).glob("*.jpg")
        ])
        if not self.jpg_files:
            QMessageBox.information(self, "提示", "该文件夹中没有找到 .jpg 照片。")
            self.status_label.setText(f"{path}  |  0 张照片")
            return

        self._refresh_grid()
        total = len(self.jpg_files)
        fav_count = len(self.fav_manager.get_favorites(path))
        self.status_label.setText(
            f"{Path(path).name}  |  共 {total} 张  |  已收藏 {fav_count} 张"
        )

    def _refresh_grid(self):
        # 清空旧控件
        while self.grid_layout.count():
            item = self.grid_layout.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        self.thumbnail_widgets.clear()

        fav_set = self.fav_manager.get_favorites(self.current_dir)
        files_to_show = []
        for fp in self.jpg_files:
            name = Path(fp).name
            if self.show_only_favorites and name not in fav_set:
                continue
            files_to_show.append(fp)

        cols = max(3, self.width() // 220)
        for idx, fp in enumerate(files_to_show):
            name = Path(fp).name
            is_fav = name in fav_set
            tw = ThumbnailWidget(fp, is_fav=is_fav)
            tw.clicked.connect(self._on_thumbnail_click)
            tw.fav_toggled.connect(self._on_fav_toggle)
            self.grid_layout.addWidget(tw, idx // cols, idx % cols)
            self.thumbnail_widgets.append(tw)

    def _on_thumbnail_click(self, file_path: str):
        self._open_viewer(file_path)

    def _open_viewer(self, file_path: str):
        if self.viewer_window is not None:
            self.viewer_window.close()
            self.viewer_window = None

        self.viewer_window = ViewerWindow(
            file_path, self.current_dir, self.fav_manager, parent=self
        )
        self.viewer_window.prev_requested.connect(self._viewer_prev)
        self.viewer_window.next_requested.connect(self._viewer_next)
        self.viewer_window.fav_changed.connect(self._on_viewer_fav_changed)
        self.viewer_window.show()

    def _viewer_prev(self):
        if not self.viewer_window:
            return
        curr = self.viewer_window.file_path
        try:
            idx = self.jpg_files.index(curr)
            if idx > 0:
                self._open_viewer(self.jpg_files[idx - 1])
        except ValueError:
            pass

    def _viewer_next(self):
        if not self.viewer_window:
            return
        curr = self.viewer_window.file_path
        try:
            idx = self.jpg_files.index(curr)
            if idx < len(self.jpg_files) - 1:
                self._open_viewer(self.jpg_files[idx + 1])
        except ValueError:
            pass

    def _on_fav_toggle(self, file_path: str):
        name = Path(file_path).name
        new_state = self.fav_manager.toggle(self.current_dir, name)
        if self.show_only_favorites and not new_state:
            self._refresh_grid()
        self._update_status()

    def _on_viewer_fav_changed(self, file_path: str, state: bool):
        name = Path(file_path).name
        for tw in self.thumbnail_widgets:
            if Path(tw.file_path).name == name:
                tw.set_favorite(state)
                break
        self._update_status()

    def _toggle_fav_filter(self, checked: bool):
        self.show_only_favorites = checked
        self._refresh_grid()

    def _update_status(self):
        total = len(self.jpg_files)
        fav_count = len(self.fav_manager.get_favorites(self.current_dir))
        self.status_label.setText(
            f"{Path(self.current_dir).name}  |  共 {total} 张  |  已收藏 {fav_count} 张"
        )

    def resizeEvent(self, event):
        super().resizeEvent(event)
        if self.thumbnail_widgets:
            self._refresh_grid()
