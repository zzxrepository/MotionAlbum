using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace LivePhotoViewer.WPF.Core
{
    /// <summary>
    /// 缩略图与实况检测缓存管理器
    /// </summary>
    public static class ThumbnailCache
    {
        private static readonly string CacheDir = Path.Combine(
            Path.GetTempPath(), "LivePhotoViewer", "cache");

        private static readonly string MetaDir = Path.Combine(
            Path.GetTempPath(), "LivePhotoViewer", "meta");

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
            try
            {
                using var stream = File.OpenRead(filePath);
                using var img = System.Drawing.Image.FromStream(stream, false, false);
                int w = img.Width;
                int h = img.Height;
                double ratio = Math.Min((double)maxSize / w, (double)maxSize / h);
                int newW = Math.Max(1, (int)(w * ratio));
                int newH = Math.Max(1, (int)(h * ratio));

                using var thumb = img.GetThumbnailImage(newW, newH, null, IntPtr.Zero);
                using var ms = new MemoryStream();
                thumb.Save(ms, System.Drawing.Imaging.ImageFormat.Jpeg);
                return ms.ToArray();
            }
            catch { return null; }
        }
    }
}
