using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace LivePhotoViewer.WPF.Core
{
    /// <summary>
    /// 缩略图与实况检测缓存管理器
    /// </summary>
    public static class ThumbnailCache
    {
        private static readonly string CacheDir = Path.Combine(
            Path.GetTempPath(), "MotionAlbum", "cache");

        private static readonly string MetaDir = Path.Combine(
            Path.GetTempPath(), "MotionAlbum", "meta");

        static ThumbnailCache()
        {
            Directory.CreateDirectory(CacheDir);
            Directory.CreateDirectory(MetaDir);
        }

        private static string GetFileHash(string filePath)
        {
            using var md5 = MD5.Create();
            var bytes = md5.ComputeHash(Encoding.UTF8.GetBytes(filePath + File.GetLastWriteTimeUtc(filePath).Ticks));
            return BitConverter.ToString(bytes).Replace("-", "").ToLowerInvariant();
        }

        public static string? GetThumbnailPath(string filePath)
        {
            string hash = GetFileHash(filePath);
            string path = Path.Combine(CacheDir, $"{hash}.jpg");
            return File.Exists(path) ? path : null;
        }

        public static void SaveThumbnail(string filePath, byte[] jpegBytes)
        {
            string hash = GetFileHash(filePath);
            File.WriteAllBytes(Path.Combine(CacheDir, $"{hash}.jpg"), jpegBytes);
        }

        /// <summary>
        /// 获取目录的实况检测缓存
        /// </summary>
        public static Dictionary<string, bool>? LoadLiveCache(string directory)
        {
            try
            {
                string metaPath = Path.Combine(MetaDir, $"{GetDirHash(directory)}.json");
                if (!File.Exists(metaPath)) return null;
                string json = File.ReadAllText(metaPath);
                return JsonSerializer.Deserialize<Dictionary<string, bool>>(json);
            }
            catch { return null; }
        }

        public static void SaveLiveCache(string directory, Dictionary<string, bool> cache)
        {
            try
            {
                string metaPath = Path.Combine(MetaDir, $"{GetDirHash(directory)}.json");
                File.WriteAllText(metaPath, JsonSerializer.Serialize(cache));
            }
            catch { }
        }

        private static string GetDirHash(string directory)
        {
            using var md5 = MD5.Create();
            var bytes = md5.ComputeHash(Encoding.UTF8.GetBytes(directory));
            return BitConverter.ToString(bytes).Replace("-", "").ToLowerInvariant();
        }

        /// <summary>
        /// 生成缩略图 JPEG 字节（后台线程安全）
        /// </summary>
        public static byte[]? GenerateThumbnailBytes(string filePath, int maxSize = 200)
        {
            byte[]? shellThumbnail = ShellThumbnailProvider.CreateJpeg(filePath, maxSize);
            if (shellThumbnail != null) return shellThumbnail;
            try
            {
                using var input = File.OpenRead(filePath);
                BitmapFrame frame = BitmapFrame.Create(input, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
                double ratio = Math.Min(1, Math.Min((double)maxSize / frame.PixelWidth, (double)maxSize / frame.PixelHeight));
                BitmapSource source = ratio < 1
                    ? new TransformedBitmap(frame, new ScaleTransform(ratio, ratio))
                    : frame;
                var encoder = new JpegBitmapEncoder { QualityLevel = 88 };
                encoder.Frames.Add(BitmapFrame.Create(source));
                using var output = new MemoryStream();
                encoder.Save(output);
                return output.ToArray();
            }
            catch { return null; }
        }
    }
}
