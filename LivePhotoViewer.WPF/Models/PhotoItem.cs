using System;
using System.Collections.Generic;
using System.IO;

namespace LivePhotoViewer.WPF.Models
{
    public enum MediaKind
    {
        Image,
        Video
    }

    public enum LivePhotoSource
    {
        None,
        AppleSidecar,
        HuaweiHonor,
        AndroidMotionPhotoV1,
        AndroidMotionPhotoV2,
        OppoMotionPhoto,
        EmbeddedMp4
    }

    /// <summary>
    /// Windows 与 macOS 版本共用的照片语义模型。一个 Apple Live Photo 在图库中只占
    /// 一个 PhotoItem，MOV/MP4 通过 CompanionVideoPath 归属于静态图片。
    /// </summary>
    public sealed class PhotoItem
    {
        public string FilePath { get; set; } = string.Empty;
        public string FileName { get; set; } = string.Empty;
        public string Directory { get; set; } = string.Empty;
        public string? CompanionVideoPath { get; set; }
        public MediaKind MediaKind { get; set; } = MediaKind.Image;
        public bool IsLivePhoto { get; set; }
        public LivePhotoSource LivePhotoSource { get; set; }
        public bool IsFavorite { get; set; }
        public int Width { get; set; }
        public int Height { get; set; }
        public long FileSize { get; set; }
        public long OriginalResourceFileSize { get; set; }
        public DateTime ModifiedAt { get; set; }
        public DateTime TimelineDate { get; set; }
        public DateTime? CapturedAt { get; set; }
        public string DeviceText { get; set; } = string.Empty;
        public string Software { get; set; } = string.Empty;
        public double? Latitude { get; set; }
        public double? Longitude { get; set; }
        public string PlaceName { get; set; } = string.Empty;
        public double? HoldFrameTime { get; set; }
        public bool IsMetadataLoaded { get; set; }
        public bool IsLiveStatusKnown { get; set; }
        public List<string> Tags { get; set; } = new();
        public string? TempMp4Path { get; set; }

        public string StableId => Path.GetFullPath(FilePath);
        public bool IsVideo => MediaKind == MediaKind.Video;
        public string CoordinateText => Latitude is double latitude && Longitude is double longitude
            ? $"{latitude:F5}, {longitude:F5}"
            : string.Empty;

        public IEnumerable<string> OriginalResourcePaths
        {
            get
            {
                yield return FilePath;
                if (!string.IsNullOrWhiteSpace(CompanionVideoPath))
                    yield return CompanionVideoPath;
            }
        }
    }
}
