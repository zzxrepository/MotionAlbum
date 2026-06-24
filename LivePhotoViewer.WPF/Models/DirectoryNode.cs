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
        public List<DirectoryNode> Children { get; set; } = new();
    }
}
