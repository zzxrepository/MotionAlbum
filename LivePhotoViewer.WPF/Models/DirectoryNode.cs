using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace LivePhotoViewer.WPF.Models
{
    /// <summary>
    /// 目录树节点模型，用于 TreeView 绑定
    /// </summary>
    public class DirectoryNode : INotifyPropertyChanged
    {
        private bool _isSelected;
        private bool _isExpanded;

        public string Name { get; set; } = string.Empty;
        public string FullPath { get; set; } = string.Empty;
        public bool IsMediaFile { get; set; }
        public bool IsVideo { get; set; }
        public string? MediaStableId { get; set; }
        public bool IsSelected
        {
            get => _isSelected;
            set => SetField(ref _isSelected, value);
        }

        public bool IsExpanded
        {
            get => _isExpanded;
            set => SetField(ref _isExpanded, value);
        }
        public int PhotoCount { get; set; }
        public int TotalPhotoCount { get; set; }
        public long PhotoSize { get; set; }
        public long TotalPhotoSize { get; set; }
        public List<DirectoryNode> Children { get; set; } = new();

        /// <summary>
        /// 显示文本：名称 + 照片数量
        /// </summary>
        public string IconText => IsMediaFile ? (IsVideo ? "▷" : "▧") : "▱";
        public string DisplayText => IsMediaFile
            ? Name
            : $"{Name} ({TotalPhotoCount:N0} · {FormatBytes(TotalPhotoSize)})";
        public string ToolTipText => IsMediaFile
            ? $"{FullPath}\n{(IsVideo ? "视频" : "照片")}"
            : TotalPhotoCount == PhotoCount
                ? $"{FullPath}\n共 {TotalPhotoCount:N0} 个媒体文件，占用 {FormatBytes(TotalPhotoSize)}"
                : $"{FullPath}\n共 {TotalPhotoCount:N0} 个媒体文件，其中本层 {PhotoCount:N0} 个；分支占用 {FormatBytes(TotalPhotoSize)}，本层占用 {FormatBytes(PhotoSize)}";

        public event PropertyChangedEventHandler? PropertyChanged;

        private void SetField(ref bool field, bool value, [CallerMemberName] string? propertyName = null)
        {
            if (field == value) return;
            field = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
        }

        private static string FormatBytes(long bytes)
        {
            if (bytes < 1024) return $"{bytes} B";
            if (bytes < 1024 * 1024) return $"{bytes / 1024.0:F1} KB";
            if (bytes < 1024L * 1024 * 1024) return $"{bytes / (1024.0 * 1024):F1} MB";
            return $"{bytes / (1024.0 * 1024 * 1024):F2} GB";
        }
    }
}
