using System;
using System.IO;
using System.Text.Json;

namespace LivePhotoViewer.WPF.Core
{
    public sealed class UserSettingsManager
    {
        private sealed class SettingsData
        {
            public bool SidebarVisible { get; set; } = true;
        }

        private readonly string _filePath;
        private SettingsData _data = new();

        public UserSettingsManager()
        {
            string directory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MotionAlbum");
            Directory.CreateDirectory(directory);
            _filePath = Path.Combine(directory, "settings.json");
            try
            {
                if (File.Exists(_filePath))
                    _data = JsonSerializer.Deserialize<SettingsData>(File.ReadAllText(_filePath)) ?? new SettingsData();
            }
            catch { _data = new SettingsData(); }
        }

        public bool SidebarVisible
        {
            get => _data.SidebarVisible;
            set
            {
                if (_data.SidebarVisible == value) return;
                _data.SidebarVisible = value;
                try { File.WriteAllText(_filePath, JsonSerializer.Serialize(_data)); } catch { }
            }
        }
    }
}
