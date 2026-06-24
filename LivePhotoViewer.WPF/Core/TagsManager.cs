using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;

namespace LivePhotoViewer.WPF.Core
{
    /// <summary>
    /// 标签管理器：支持给照片添加多标签，持久化存储到 JSON
    /// </summary>
    public class TagsManager
    {
        private readonly string _filePath;
        private Dictionary<string, Dictionary<string, List<string>>> _tags = new();

        public TagsManager()
        {
            string dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "LivePhotoViewer");
            Directory.CreateDirectory(dir);
            _filePath = Path.Combine(dir, "tags.json");
            Load();
        }

        private void Load()
        {
            try
            {
                if (File.Exists(_filePath))
                {
                    string json = File.ReadAllText(_filePath);
                    _tags = JsonSerializer.Deserialize<Dictionary<string, Dictionary<string, List<string>>>>(json)
                        ?? new Dictionary<string, Dictionary<string, List<string>>>();
                }
                else
                {
                    _tags = new Dictionary<string, Dictionary<string, List<string>>>();
                }
            }
            catch
            {
                _tags = new Dictionary<string, Dictionary<string, List<string>>>();
            }
        }

        private void Save()
        {
            try
            {
                string json = JsonSerializer.Serialize(_tags, new JsonSerializerOptions { WriteIndented = true });
                File.WriteAllText(_filePath, json);
            }
            catch { }
        }

        private static string NormalizeDir(string directory)
        {
            return Path.GetFullPath(directory);
        }

        public List<string> GetTags(string directory, string fileName)
        {
            string d = NormalizeDir(directory);
            if (_tags.TryGetValue(d, out var dict) && dict.TryGetValue(fileName, out var list))
                return new List<string>(list);
            return new List<string>();
        }

        public void AddTag(string directory, string fileName, string tag)
        {
            string d = NormalizeDir(directory);
            if (!_tags.ContainsKey(d))
                _tags[d] = new Dictionary<string, List<string>>();
            if (!_tags[d].ContainsKey(fileName))
                _tags[d][fileName] = new List<string>();

            string trimmed = tag.Trim();
            if (string.IsNullOrEmpty(trimmed)) return;

            if (!_tags[d][fileName].Contains(trimmed))
            {
                _tags[d][fileName].Add(trimmed);
                Save();
            }
        }

        public void RemoveTag(string directory, string fileName, string tag)
        {
            string d = NormalizeDir(directory);
            if (_tags.TryGetValue(d, out var dict) && dict.TryGetValue(fileName, out var list))
            {
                list.Remove(tag.Trim());
                if (list.Count == 0)
                    dict.Remove(fileName);
                if (dict.Count == 0)
                    _tags.Remove(d);
                Save();
            }
        }

        public HashSet<string> GetAllTags(string directory)
        {
            string d = NormalizeDir(directory);
            var result = new HashSet<string>();
            if (_tags.TryGetValue(d, out var dict))
            {
                foreach (var list in dict.Values)
                {
                    foreach (var tag in list)
                        result.Add(tag);
                }
            }
            return result;
        }

        public bool HasTag(string directory, string fileName, string tag)
        {
            var tags = GetTags(directory, fileName);
            return tags.Contains(tag.Trim());
        }
    }
}
