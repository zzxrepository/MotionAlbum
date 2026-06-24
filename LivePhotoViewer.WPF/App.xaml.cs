using System.Windows;
using LibVLCSharp.Shared;
using LivePhotoViewer.WPF.Core;

namespace LivePhotoViewer.WPF
{
    public partial class App : Application
    {
        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);
            // 提前初始化 LibVLC，避免在播放窗口中初始化导致卡顿或弹窗
            LibVLCSharp.Shared.Core.Initialize();
            // 应用用户保存的主题偏好
            ThemeManager.ApplyTheme(ThemeManager.CurrentTheme);
        }
    }
}
