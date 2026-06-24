using System.Collections.Generic;

namespace LivePhotoViewer.WPF.Models
{
    /// <summary>
    /// 目录树节点模型，用于 TreeView 绑定
    /// </summary>
    public class DirectoryNode
    {
        public string Name { get; set; } = string.Empty;
        public string FullPath { get; set; } = string.Empty;
        public bool IsSelected { get; set; }
        public int PhotoCount { get; set; }
        public List<DirectoryNode> Children { get; set; } = new();

        /// <summary>
        /// 显示文本：名称 + 照片数量
        /// </summary>
        public string DisplayText => PhotoCount > 0 ? $"{Name} ({PhotoCount})" : Name;
    }
}
