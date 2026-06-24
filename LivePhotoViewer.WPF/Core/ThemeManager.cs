using System;
using System.IO;
using System.Linq;
using System.Windows;

namespace LivePhotoViewer.WPF.Core
{
    /// <summary>
    /// 主题管理器：支持多主题切换（深色/浅色/Vue/GitHub），持久化用户偏好
    /// </summary>
    public static class ThemeManager
    {
        private const string ThemeConfigFileName = "theme.config";
        private static readonly string ConfigPath =
            Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "LivePhotoViewer",
                ThemeConfigFileName);

        public enum Theme
        {
            Dark,
            Light,
            Vue,
            GitHub
        }

        private static readonly Theme[] ThemeCycle = new[]
        {
            Theme.Dark, Theme.Light, Theme.Vue, Theme.GitHub
        };

        public static Theme CurrentTheme { get; private set; } = Theme.Dark;

        public static event EventHandler? ThemeChanged;

        static ThemeManager()
        {
            Directory.CreateDirectory(Path.GetDirectoryName(ConfigPath)!);
            LoadThemePreference();
        }

        public static void ApplyTheme(Theme theme)
        {
            CurrentTheme = theme;
            string themeFile = theme switch
            {
                Theme.Light => "pack://application:,,,/Themes/LightTheme.xaml",
                Theme.Vue => "pack://application:,,,/Themes/VueTheme.xaml",
                Theme.GitHub => "pack://application:,,,/Themes/GitHubTheme.xaml",
                _ => "pack://application:,,,/Themes/DarkTheme.xaml"
            };

            var dict = new ResourceDictionary();
            dict.Source = new Uri(themeFile, UriKind.Absolute);

            var app = Application.Current;
            if (app != null)
            {
                // 移除已有的主题字典
                for (int i = app.Resources.MergedDictionaries.Count - 1; i >= 0; i--)
                {
                    var d = app.Resources.MergedDictionaries[i];
                    if (d.Source != null && d.Source.OriginalString.Contains("Theme"))
                    {
                        app.Resources.MergedDictionaries.RemoveAt(i);
                    }
                }

                app.Resources.MergedDictionaries.Insert(0, dict);
            }

            SaveThemePreference(theme);
            ThemeChanged?.Invoke(null, EventArgs.Empty);
        }

        public static void ToggleTheme()
        {
            int currentIndex = Array.IndexOf(ThemeCycle, CurrentTheme);
            int nextIndex = (currentIndex + 1) % ThemeCycle.Length;
            ApplyTheme(ThemeCycle[nextIndex]);
        }

        /// <summary>
        /// 获取当前主题的图标和提示文本
        /// </summary>
        public static (string icon, string tooltip) GetThemeDisplay()
        {
            return CurrentTheme switch
            {
                Theme.Light => ("☀", "浅色主题"),
                Theme.Vue => ("🌿", "Vue 主题"),
                Theme.GitHub => ("🐙", "GitHub 主题"),
                _ => ("🌙", "深色主题")
            };
        }

        private static void SaveThemePreference(Theme theme)
        {
            try
            {
                File.WriteAllText(ConfigPath, theme.ToString());
            }
            catch { }
        }

        private static void LoadThemePreference()
        {
            try
            {
                if (File.Exists(ConfigPath))
                {
                    string saved = File.ReadAllText(ConfigPath).Trim();
                    if (Enum.TryParse<Theme>(saved, out var theme))
                    {
                        CurrentTheme = theme;
                    }
                }
            }
            catch { }
        }
    }
}
