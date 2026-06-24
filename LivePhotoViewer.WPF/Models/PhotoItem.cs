using System.Collections.Generic;

namespace LivePhotoViewer.WPF.Models
{
    /// <summary>
    /// 照片数据模型
    /// </summary>
    public class PhotoItem
    {
        public string FilePath { get; set; } = string.Empty;
        public string FileName { get; set; } = string.Empty;
        public string Directory { get; set; } = string.Empty;
        public bool IsLivePhoto { get; set; }
        public bool IsFavorite { get; set; }
        public int Width { get; set; }
        public int Height { get; set; }
        public List<string> Tags { get; set; } = new();

        /// <summary>
        /// 临时提取的 MP4 文件路径（缓存，避免重复提取）
        /// </summary>
        public string? TempMp4Path { get; set; }
    }
}
