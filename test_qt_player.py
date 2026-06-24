import sys
from PyQt5.QtWidgets import QApplication, QWidget, QPushButton, QVBoxLayout
from PyQt5.QtMultimedia import QMediaPlayer, QMediaContent
from PyQt5.QtCore import QUrl

class TestPlayer(QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Test H.265 Player")
        self.resize(400, 300)

        layout = QVBoxLayout(self)

        self.btn = QPushButton("Play extracted MP4")
        self.btn.clicked.connect(self.play)
        layout.addWidget(self.btn)

        self.player = QMediaPlayer()
        self.player.error.connect(self.on_error)
        self.player.mediaStatusChanged.connect(self.on_status)

    def play(self):
        path = "e:/DevWorkspace/Tests/TraeTutorialsProjectCode/14_Project_Cursor_Test/samples/VID_20260617_140640.mp4"
        self.player.setMedia(QMediaContent(QUrl.fromLocalFile(path)))
        self.player.play()
        print("Play requested")

    def on_error(self, error):
        print(f"Error: {error} - {self.player.errorString()}")

    def on_status(self, status):
        print(f"Status: {status}")

app = QApplication(sys.argv)
w = TestPlayer()
w.show()
sys.exit(app.exec_())
