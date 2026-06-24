"""
缩略图控件
"""
from pathlib import Path
from PyQt5.QtWidgets import (
    QFrame, QVBoxLayout, QLabel, QPushButton, QGraphicsDropShadowEffect
)
from PyQt5.QtCore import Qt, pyqtSignal
from PyQt5.QtGui import QPixmap, QImage, QFont, QColor
from PIL import Image

from ..core.extractor import is_live_photo


class ThumbnailWidget(QFrame):
    """单个缩略图卡片，显示预览图、文件名、实况角标和收藏按钮。"""

    clicked = pyqtSignal(str)          # 双击时发出文件路径
    fav_toggled = pyqtSignal(str)      # 收藏状态切换时发出文件路径

    def __init__(self, file_path: str, is_fav: bool = False, parent=None):
        super().__init__(parent)
        self.file_path = file_path
        self.is_live = False
        self.is_fav = is_fav
        self._setup_ui()
        self._load_thumbnail()

    def _setup_ui(self):
        self.setFixedSize(200, 240)
        self.setFrameShape(QFrame.StyledPanel)
        self.setCursor(Qt.PointingHandCursor)

        # 阴影效果
        shadow = QGraphicsDropShadowEffect(self)
        shadow.setBlurRadius(12)
        shadow.setColor(QColor(0, 0, 0, 80))
        shadow.setOffset(2, 2)
        self.setGraphicsEffect(shadow)

        self.setStyleSheet("""
            ThumbnailWidget {
                background-color: #ffffff;
                border-radius: 10px;
                border: 2px solid transparent;
            }
            ThumbnailWidget:hover {
                border: 2px solid #007aff;
            }
        """)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(8, 8, 8, 8)
        layout.setSpacing(4)

        # 图片区域容器（用于叠加角标和按钮）
        self.img_container = QLabel(self)
        self.img_container.setFixedSize(180, 180)
        self.img_container.setAlignment(Qt.AlignCenter)
        self.img_container.setStyleSheet("background-color: #f0f0f0; border-radius: 6px;")
        layout.addWidget(self.img_container, alignment=Qt.AlignCenter)

        # 实况角标（左上角）
        self.live_badge = QLabel("LIVE", self.img_container)
        self.live_badge.setAlignment(Qt.AlignCenter)
        self.live_badge.setStyleSheet("""
            background-color: #ff2d55;
            color: white;
            border-radius: 8px;
            padding: 2px 6px;
            font-size: 10px;
            font-weight: bold;
        """)
        self.live_badge.move(6, 6)
        self.live_badge.setVisible(False)

        # 收藏按钮（右上角）
        self.fav_btn = QPushButton("☆", self.img_container)
        self.fav_btn.setFixedSize(28, 28)
        self.fav_btn.move(180 - 28 - 6, 6)
        self.fav_btn.setStyleSheet("""
            QPushButton {
                background-color: rgba(255,255,255,0.9);
                border-radius: 14px;
                color: #888;
                font-size: 14px;
                font-weight: bold;
            }
            QPushButton:hover {
                background-color: white;
                color: #ff9500;
            }
        """)
        self.fav_btn.setCursor(Qt.PointingHandCursor)
        self.fav_btn.clicked.connect(self._on_fav_click)
        self._update_fav_style()

        # 文件名
        self.name_label = QLabel(self)
        self.name_label.setAlignment(Qt.AlignCenter)
        self.name_label.setFont(QFont("Microsoft YaHei", 9))
        self.name_label.setStyleSheet("color: #333;")
        self.name_label.setWordWrap(False)
        name = Path(self.file_path).name
        self.name_label.setText(name if len(name) <= 18 else name[:15] + "...")
        layout.addWidget(self.name_label)

    def _load_thumbnail(self):
        # 检测是否为实况照片
        self.is_live = is_live_photo(self.file_path)
        self.live_badge.setVisible(self.is_live)

        # 生成缩略图
        try:
            img = Image.open(self.file_path)
            img.thumbnail((180, 180), Image.Resampling.LANCZOS)
            if img.mode != "RGB":
                img = img.convert("RGB")
            data = img.tobytes("raw", "RGB")
            qimg = QImage(data, img.width, img.height, img.width * 3, QImage.Format_RGB888)
            pixmap = QPixmap.fromImage(qimg)
            self.img_container.setPixmap(pixmap)
        except Exception:
            self.img_container.setText("无法加载")

    def _on_fav_click(self):
        self.is_fav = not self.is_fav
        self._update_fav_style()
        self.fav_toggled.emit(self.file_path)

    def _update_fav_style(self):
        if self.is_fav:
            self.fav_btn.setText("★")
            self.fav_btn.setStyleSheet("""
                QPushButton {
                    background-color: rgba(255,255,255,0.9);
                    border-radius: 14px;
                    color: #ff9500;
                    font-size: 14px;
                    font-weight: bold;
                }
                QPushButton:hover {
                    background-color: white;
                    color: #ff9500;
                }
            """)
        else:
            self.fav_btn.setText("☆")
            self.fav_btn.setStyleSheet("""
                QPushButton {
                    background-color: rgba(255,255,255,0.9);
                    border-radius: 14px;
                    color: #888;
                    font-size: 14px;
                    font-weight: bold;
                }
                QPushButton:hover {
                    background-color: white;
                    color: #ff9500;
                }
            """)

    def set_favorite(self, state: bool):
        if self.is_fav != state:
            self.is_fav = state
            self._update_fav_style()

    def mouseDoubleClickEvent(self, event):
        self.clicked.emit(self.file_path)
