"""
大图查看器窗口 - 支持实况视频播放
"""
import os
from pathlib import Path

import numpy as np
from PIL import Image

from PyQt5.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QPushButton,
    QSizePolicy, QApplication
)
from PyQt5.QtCore import Qt, QTimer, pyqtSignal
from PyQt5.QtGui import QPixmap, QImage, QFont, QKeyEvent

from ..core.extractor import is_live_photo, extract_mp4_to_temp, VideoFrameReader
from ..core.favorites import FavoritesManager


class ViewerWindow(QWidget):
    """大图查看器，支持静态图浏览和实况视频播放。"""

    prev_requested = pyqtSignal()
    next_requested = pyqtSignal()
    fav_changed = pyqtSignal(str, bool)

    def __init__(self, file_path: str, directory: str, fav_manager: FavoritesManager, parent=None):
        super().__init__(parent)
        self.file_path = file_path
        self.directory = directory
        self.fav_manager = fav_manager
        self.is_live = is_live_photo(file_path)
        self.is_fav = fav_manager.is_favorite(directory, Path(file_path).name)

        self._pil_image = None
        self._video_reader = None
        self._video_timer = QTimer(self)
        self._video_timer.timeout.connect(self._on_video_frame)
        self._temp_mp4_path = None

        self.setWindowTitle(f"图片查看器 - {Path(file_path).name}")
        self.setStyleSheet("background-color: #1a1a1a;")
        self.resize(1000, 800)
        self._setup_ui()
        self._load_image()

    def _setup_ui(self):
        main_layout = QVBoxLayout(self)
        main_layout.setContentsMargins(0, 0, 0, 0)
        main_layout.setSpacing(0)

        # 顶部工具栏
        toolbar = QHBoxLayout()
        toolbar.setContentsMargins(12, 8, 12, 8)

        self.btn_prev = QPushButton("◀ 上一张")
        self.btn_next = QPushButton("下一张 ▶")
        self.btn_fav = QPushButton("★ 已收藏" if self.is_fav else "☆ 收藏")
        self.btn_close = QPushButton("✕ 关闭")

        for btn in (self.btn_prev, self.btn_next, self.btn_fav, self.btn_close):
            btn.setStyleSheet("""
                QPushButton {
                    background-color: rgba(255,255,255,0.15);
                    color: white;
                    border-radius: 6px;
                    padding: 6px 14px;
                    font-size: 13px;
                }
                QPushButton:hover {
                    background-color: rgba(255,255,255,0.3);
                }
            """)
            btn.setCursor(Qt.PointingHandCursor)

        toolbar.addWidget(self.btn_prev)
        toolbar.addWidget(self.btn_next)
        toolbar.addStretch()
        toolbar.addWidget(self.btn_fav)
        toolbar.addWidget(self.btn_close)
        main_layout.addLayout(toolbar)

        # 中央显示区域（图片 + 视频覆盖层）
        self.display_area = QLabel(self)
        self.display_area.setAlignment(Qt.AlignCenter)
        self.display_area.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        self.display_area.setStyleSheet("background-color: #000;")
        main_layout.addWidget(self.display_area, stretch=1)

        # 播放控制按钮（覆盖在 display_area 上，通过 move 定位）
        self.play_btn = QPushButton("▶ 播放实况", self.display_area)
        self.play_btn.setFixedSize(140, 40)
        self.play_btn.setStyleSheet("""
            QPushButton {
                background-color: rgba(0,122,255,0.9);
                color: white;
                border-radius: 20px;
                font-size: 14px;
                font-weight: bold;
            }
            QPushButton:hover {
                background-color: #0051d5;
            }
        """)
        self.play_btn.setCursor(Qt.PointingHandCursor)
        self.play_btn.setVisible(False)
        self.play_btn.clicked.connect(self._start_playback)

        # 底部信息栏
        self.info_label = QLabel(self)
        self.info_label.setAlignment(Qt.AlignCenter)
        self.info_label.setStyleSheet("color: #aaa; padding: 6px; font-size: 12px;")
        self.info_label.setFont(QFont("Microsoft YaHei", 9))
        main_layout.addWidget(self.info_label)

        # 信号连接
        self.btn_prev.clicked.connect(self.prev_requested.emit)
        self.btn_next.clicked.connect(self.next_requested.emit)
        self.btn_fav.clicked.connect(self._toggle_fav)
        self.btn_close.clicked.connect(self.close)

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self._refresh_display()
        self._center_play_button()

    def _center_play_button(self):
        if self.play_btn.isVisible():
            x = (self.display_area.width() - self.play_btn.width()) // 2
            y = (self.display_area.height() - self.play_btn.height()) // 2
            self.play_btn.move(x, y)

    def _load_image(self):
        try:
            self._pil_image = Image.open(self.file_path)
            if self._pil_image.mode != "RGB":
                self._pil_image = self._pil_image.convert("RGB")
            self._refresh_display()

            info = f"{self._pil_image.width} x {self._pil_image.height}"
            if self.is_live:
                info += "  |  包含实况视频"
                self.play_btn.setVisible(True)
                self._center_play_button()
            else:
                info += "  |  静态照片"
            self.info_label.setText(info)
        except Exception as e:
            self.display_area.setText(f"无法加载图片: {e}")

    def _refresh_display(self):
        if self._pil_image is None:
            return
        # 计算等比缩放尺寸（适应 display_area）
        avail_w = max(1, self.display_area.width())
        avail_h = max(1, self.display_area.height())
        img_w, img_h = self._pil_image.size
        scale = min(avail_w / img_w, avail_h / img_h, 1.0)
        new_w = int(img_w * scale)
        new_h = int(img_h * scale)
        resized = self._pil_image.resize((new_w, new_h), Image.Resampling.LANCZOS)
        data = resized.tobytes("raw", "RGB")
        qimg = QImage(data, new_w, new_h, new_w * 3, QImage.Format_RGB888)
        pixmap = QPixmap.fromImage(qimg)
        self.display_area.setPixmap(pixmap)

    def _start_playback(self):
        if not self.is_live:
            return
        self.play_btn.setVisible(False)
        # 临时提取 MP4
        self._temp_mp4_path = extract_mp4_to_temp(self.file_path)
        if not self._temp_mp4_path:
            self.info_label.setText("实况视频提取失败")
            self.play_btn.setVisible(True)
            return
        try:
            self._video_reader = VideoFrameReader(self._temp_mp4_path)
            interval_ms = max(16, int(1000 / self._video_reader.fps))
            self._video_timer.start(interval_ms)
            self.info_label.setText(f"正在播放实况视频...  {self._video_reader.frame_count} 帧")
        except Exception as e:
            self.info_label.setText(f"播放失败: {e}")
            self.play_btn.setVisible(True)

    def _on_video_frame(self):
        if self._video_reader is None:
            self._video_timer.stop()
            return
        frame = self._video_reader.next_frame()
        if frame is None:
            self._stop_playback(show_replay=True)
            return
        # 缩放帧以匹配显示区域
        avail_w = max(1, self.display_area.width())
        avail_h = max(1, self.display_area.height())
        fh, fw = frame.shape[:2]
        scale = min(avail_w / fw, avail_h / fh, 1.0)
        new_w = int(fw * scale)
        new_h = int(fh * scale)
        # 使用 PIL 快速缩放 numpy 数组
        pil_frame = Image.fromarray(frame)
        pil_frame = pil_frame.resize((new_w, new_h), Image.Resampling.BILINEAR)
        frame_rgb = np.array(pil_frame)
        data = frame_rgb.tobytes()
        qimg = QImage(data, new_w, new_h, new_w * 3, QImage.Format_RGB888)
        pixmap = QPixmap.fromImage(qimg)
        self.display_area.setPixmap(pixmap)

    def _stop_playback(self, show_replay: bool = False):
        self._video_timer.stop()
        if self._video_reader:
            self._video_reader.close()
            self._video_reader = None
        # 恢复显示静态图
        self._refresh_display()
        if show_replay:
            self.play_btn.setText("↻ 重播")
            self.play_btn.setVisible(True)
            self._center_play_button()
            self.info_label.setText("实况视频播放结束")

    def _toggle_fav(self):
        self.is_fav = not self.is_fav
        self.fav_manager.set_favorite(self.directory, Path(self.file_path).name, self.is_fav)
        self.btn_fav.setText("★ 已收藏" if self.is_fav else "☆ 收藏")
        self.fav_changed.emit(self.file_path, self.is_fav)

    def keyPressEvent(self, event: QKeyEvent):
        if event.key() == Qt.Key_Left:
            self.prev_requested.emit()
        elif event.key() == Qt.Key_Right:
            self.next_requested.emit()
        elif event.key() == Qt.Key_Escape:
            self.close()
        elif event.key() == Qt.Key_Space:
            if self.is_live and not self._video_timer.isActive():
                self._start_playback()
        else:
            super().keyPressEvent(event)

    def closeEvent(self, event):
        self._stop_playback()
        if self._temp_mp4_path and os.path.exists(self._temp_mp4_path):
            try:
                os.remove(self._temp_mp4_path)
            except Exception:
                pass
        super().closeEvent(event)
