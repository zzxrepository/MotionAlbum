using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace LivePhotoViewer.WPF.Core
{
    public sealed class HoldFrameManager
    {
        private readonly string _filePath;
        private Dictionary<string, double> _values = new(StringComparer.OrdinalIgnoreCase);

        public HoldFrameManager()
        {
            string directory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MotionAlbum");
            Directory.CreateDirectory(directory);
            _filePath = Path.Combine(directory, "hold-frames.json");
            Load();
        }

        public double? Get(string filePath) =>
            _values.TryGetValue(Normalize(filePath), out double seconds) ? seconds : null;

        public void Set(string filePath, double? seconds)
        {
            string key = Normalize(filePath);
            if (seconds is >= 0 and < 86_400) _values[key] = seconds.Value;
            else _values.Remove(key);
            Save();
        }

        public void Remove(string filePath)
        {
            if (_values.Remove(Normalize(filePath))) Save();
        }

        private static string Normalize(string path) => Path.GetFullPath(path);

        private void Load()
        {
            try
            {
                if (!File.Exists(_filePath)) return;
                _values = JsonSerializer.Deserialize<Dictionary<string, double>>(File.ReadAllText(_filePath))
                    ?? new Dictionary<string, double>(StringComparer.OrdinalIgnoreCase);
                _values = new Dictionary<string, double>(_values, StringComparer.OrdinalIgnoreCase);
            }
            catch { _values = new Dictionary<string, double>(StringComparer.OrdinalIgnoreCase); }
        }

        private void Save()
        {
            try { File.WriteAllText(_filePath, JsonSerializer.Serialize(_values)); } catch { }
        }
    }
}
