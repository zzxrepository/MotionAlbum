"""
收藏/标注管理模块
收藏信息持久化存储在用户数据目录的 favorites.json 中。
"""
import os
import json
from pathlib import Path
from typing import Dict, Set


class FavoritesManager:
    """管理用户对照片的收藏/标注状态。"""

    def __init__(self):
        self._data_dir = Path(os.path.expanduser("~")) / "AppData" / "Roaming" / "LivePhotoViewer"
        self._data_dir.mkdir(parents=True, exist_ok=True)
        self._file = self._data_dir / "favorites.json"
        self._favorites: Dict[str, Dict[str, bool]] = {}
        self._load()

    def _load(self):
        if self._file.exists():
            try:
                with open(self._file, "r", encoding="utf-8") as f:
                    self._favorites = json.load(f)
            except Exception:
                self._favorites = {}
        else:
            self._favorites = {}

    def _save(self):
        try:
            with open(self._file, "w", encoding="utf-8") as f:
                json.dump(self._favorites, f, ensure_ascii=False, indent=2)
        except Exception:
            pass

    def _norm_dir(self, directory: str) -> str:
        return str(Path(directory).resolve())

    def is_favorite(self, directory: str, filename: str) -> bool:
        d = self._norm_dir(directory)
        return self._favorites.get(d, {}).get(filename, False)

    def set_favorite(self, directory: str, filename: str, state: bool = True):
        d = self._norm_dir(directory)
        if d not in self._favorites:
            self._favorites[d] = {}
        if state:
            self._favorites[d][filename] = True
        else:
            self._favorites[d].pop(filename, None)
        self._save()

    def toggle(self, directory: str, filename: str) -> bool:
        new_state = not self.is_favorite(directory, filename)
        self.set_favorite(directory, filename, new_state)
        return new_state

    def get_favorites(self, directory: str) -> Set[str]:
        d = self._norm_dir(directory)
        return {k for k, v in self._favorites.get(d, {}).items() if v}

    def clear_dir(self, directory: str):
        d = self._norm_dir(directory)
        if d in self._favorites:
            del self._favorites[d]
            self._save()
