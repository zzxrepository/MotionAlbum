using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace LivePhotoViewer.WPF.Core
{
    /// <summary>
    /// Stores reversible viewer orientation without rewriting a Motion Photo container
    /// or breaking an Apple image/MOV resource pair.
    /// </summary>
    public sealed class RotationManager
    {
        private readonly string _filePath;
        private Dictionary<string, int> _values = new(StringComparer.OrdinalIgnoreCase);

        public RotationManager()
        {
            string directory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MotionAlbum");
            Directory.CreateDirectory(directory);
            _filePath = Path.Combine(directory, "rotations.json");
            Load();
        }

        public int Get(string filePath) =>
            _values.TryGetValue(Normalize(filePath), out int turns) ? NormalizeTurns(turns) : 0;

        public void Set(string filePath, int quarterTurns)
        {
            string key = Normalize(filePath);
            int normalized = NormalizeTurns(quarterTurns);
            if (normalized == 0) _values.Remove(key);
            else _values[key] = normalized;
            Save();
        }

        public void Remove(string filePath)
        {
            if (_values.Remove(Normalize(filePath))) Save();
        }

        private static int NormalizeTurns(int turns) => ((turns % 4) + 4) % 4;
        private static string Normalize(string path) => Path.GetFullPath(path);

        private void Load()
        {
            try
            {
                if (!File.Exists(_filePath)) return;
                _values = JsonSerializer.Deserialize<Dictionary<string, int>>(File.ReadAllText(_filePath))
                    ?? new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
                _values = new Dictionary<string, int>(_values, StringComparer.OrdinalIgnoreCase);
            }
            catch { _values = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase); }
        }

        private void Save()
        {
            try { File.WriteAllText(_filePath, JsonSerializer.Serialize(_values)); } catch { }
        }
    }
}
