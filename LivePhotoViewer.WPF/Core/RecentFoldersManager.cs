using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;

namespace LivePhotoViewer.WPF.Core
{
    public sealed class RecentFoldersManager
    {
        private readonly string _filePath;
        private List<string> _paths = new();

        public RecentFoldersManager()
        {
            string root = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "MotionAlbum");
            Directory.CreateDirectory(root);
            _filePath = Path.Combine(root, "recent-folders.json");
            Load();
        }

        public IReadOnlyList<string> Paths => _paths;

        public void Add(string path)
        {
            string normalized = Path.GetFullPath(path);
            _paths.RemoveAll(value => string.Equals(value, normalized, StringComparison.OrdinalIgnoreCase));
            _paths.Insert(0, normalized);
            if (_paths.Count > 12) _paths.RemoveRange(12, _paths.Count - 12);
            Save();
        }

        public void Clear()
        {
            _paths.Clear();
            Save();
        }

        public void Remove(string path)
        {
            string normalized = Path.GetFullPath(path);
            int removed = _paths.RemoveAll(item => string.Equals(item, normalized, StringComparison.OrdinalIgnoreCase));
            if (removed > 0) Save();
        }

        public void RemoveUnavailable()
        {
            if (_paths.RemoveAll(path => !Directory.Exists(path)) > 0) Save();
        }

        private void Load()
        {
            try
            {
                if (!File.Exists(_filePath)) return;
                _paths = JsonSerializer.Deserialize<List<string>>(File.ReadAllText(_filePath))
                    ?.Where(path => !string.IsNullOrWhiteSpace(path))
                    .Distinct(StringComparer.OrdinalIgnoreCase)
                    .Take(12)
                    .ToList() ?? new List<string>();
            }
            catch { _paths = new List<string>(); }
        }

        private void Save()
        {
            try
            {
                File.WriteAllText(
                    _filePath,
                    JsonSerializer.Serialize(_paths, new JsonSerializerOptions { WriteIndented = true }));
            }
            catch { }
        }
    }
}
