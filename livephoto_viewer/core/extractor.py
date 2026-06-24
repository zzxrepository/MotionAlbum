"""
实况照片提取核心模块
"""
import os
import struct
import tempfile
import shutil
from pathlib import Path
from typing import Optional, Tuple, Iterator
import numpy as np


def find_mp4_ftyp(data: bytes) -> int:
    """在二进制数据中搜索 MP4 ftyp 标记的位置，返回 ftyp 字符串起始偏移；未找到返回 -1。"""
    pos = 0
    while True:
        idx = data.find(b'ftyp', pos)
        if idx == -1:
            return -1
        if idx >= 4:
            box_size = struct.unpack('>I', data[idx - 4:idx])[0]
            if 8 <= box_size <= 1024:
                brand = data[idx + 4:idx + 8]
                if all(32 <= b <= 126 for b in brand):
                    return idx
        pos = idx + 1


def is_live_photo(path: str) -> bool:
    """快速检测文件是否为包含实况视频的 JPG。"""
    try:
        with open(path, 'rb') as f:
            # 只读取前 8MB 和最后 2MB 进行快速检测
            f.seek(0, 2)
            size = f.tell()
            f.seek(0)
            if size <= 10 * 1024 * 1024:
                data = f.read()
            else:
                data = f.read(8 * 1024 * 1024)
                f.seek(max(0, size - 2 * 1024 * 1024))
                data += f.read(2 * 1024 * 1024)
            return find_mp4_ftyp(data) != -1
    except Exception:
        return False


def extract_mp4_to_temp(jpg_path: str, temp_dir: Optional[str] = None) -> Optional[str]:
    """
    从 JPG 实况照片中提取嵌入的 MP4，保存到临时文件。
    返回临时文件路径；如果不是实况照片则返回 None。
    """
    try:
        with open(jpg_path, 'rb') as f:
            data = f.read()
        ftyp_pos = find_mp4_ftyp(data)
        if ftyp_pos == -1:
            return None
        video_offset = ftyp_pos - 4
        video_data = data[video_offset:]

        stem = Path(jpg_path).stem
        if temp_dir is None:
            temp_dir = tempfile.gettempdir()
        temp_path = os.path.join(temp_dir, f"livephoto_{stem}.mp4")
        with open(temp_path, 'wb') as f:
            f.write(video_data)
        return temp_path
    except Exception:
        return None


def get_video_info(path: str) -> Optional[dict]:
    """获取视频基本信息，返回 dict 或 None。"""
    try:
        import imageio
        reader = imageio.get_reader(path)
        meta = reader.get_meta_data()
        reader.close()
        return {
            'duration': meta.get('duration', 0),
            'fps': meta.get('fps', 30),
            'size': meta.get('size', (0, 0)),
            'frame_count': meta.get('nframes', 0),
        }
    except Exception:
        return None


class VideoFrameReader:
    """
    基于 imageio 的视频帧读取器，配合 PyQt 的 QTimer 使用。
    """
    def __init__(self, mp4_path: str):
        import imageio
        self.reader = imageio.get_reader(mp4_path)
        meta = self.reader.get_meta_data()
        self.fps = meta.get('fps', 30) or 30
        self.frame_count = meta.get('nframes', 0)
        self.duration = meta.get('duration', 0)
        self.width, self.height = meta.get('size', (0, 0))
        self.current_frame = 0
        self._finished = False

    def next_frame(self) -> Optional[np.ndarray]:
        """读取下一帧，返回 RGB numpy 数组；结束返回 None。"""
        if self._finished or (self.frame_count > 0 and self.current_frame >= self.frame_count):
            return None
        try:
            frame = self.reader.get_data(self.current_frame)
            self.current_frame += 1
            return frame
        except Exception:
            self._finished = True
            return None

    def reset(self):
        """重置到第一帧。"""
        self.current_frame = 0
        self._finished = False

    def close(self):
        """关闭读取器释放资源。"""
        try:
            self.reader.close()
        except Exception:
            pass
