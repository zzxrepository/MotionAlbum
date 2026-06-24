using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;

namespace LivePhotoViewer.WPF.Core
{
    /// <summary>
    /// 收藏状态管理器，持久化存储到 JSON 文件
    /// </summary>
    public class FavoritesManager
    {
        private readonly string _filePath;
        private Dictionary<string, Dictionary<string, bool>> _favorites = new();

        public FavoritesManager()
        {
            string dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "LivePhotoViewer");
            Directory.CreateDirectory(dir);
            _filePath = Path.Combine(dir, "favorites.json");
            Load();
        }

        private void Load()
        {
            try
            {
                if (File.Exists(_filePath))
                {
                    string json = File.ReadAllText(_filePath);
                    _favorites = JsonSerializer.Deserialize<Dictionary<string, Dictionary<string, bool>>>(json)
                        ?? new Dictionary<string, Dictionary<string, bool>>();
                }
                else
                {
                    _favorites = new Dictionary<string, Dictionary<string, bool>>();
                }
            }
            catch
            {
                _favorites = new Dictionary<string, Dictionary<string, bool>>();
            }
        }

        private void Save()
        {
            try
            {
                string json = JsonSerializer.Serialize(_favorites, new JsonSerializerOptions { WriteIndented = true });
                File.WriteAllText(_filePath, json);
            }
            catch { }
        }

        private static string NormalizeDir(string directory)
        {
            return Path.GetFullPath(directory);
        }

        public bool IsFavorite(string directory, string fileName)
        {
            string d = NormalizeDir(directory);
            return _favorites.TryGetValue(d, out var dict) && dict.TryGetValue(fileName, out bool val) && val;
        }

        public void SetFavorite(string directory, string fileName, bool state)
        {
            string d = NormalizeDir(directory);
            if (!_favorites.ContainsKey(d))
                _favorites[d] = new Dictionary<string, bool>();

            if (state)
                _favorites[d][fileName] = true;
            else
                _favorites[d].Remove(fileName);

            Save();
        }

        public bool Toggle(string directory, string fileName)
        {
            bool newState = !IsFavorite(directory, fileName);
            SetFavorite(directory, fileName, newState);
            return newState;
        }

        public HashSet<string> GetFavorites(string directory)
        {
            string d = NormalizeDir(directory);
            if (_favorites.TryGetValue(d, out var dict))
                return new HashSet<string>(dict.Where(kv => kv.Value).Select(kv => kv.Key));
            return new HashSet<string>();
        }

        public void ClearDirectory(string directory)
        {
            string d = NormalizeDir(directory);
            if (_favorites.Remove(d))
                Save();
        }
    }
}
