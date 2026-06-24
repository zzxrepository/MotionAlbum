using System;
using System.IO;
using System.Linq;
using System.Text;

namespace LivePhotoViewer.WPF.Core
{
    /// <summary>
    /// 从荣耀/华为 JPG 实况照片中提取嵌入的 MP4 视频
    /// </summary>
    public static class LivePhotoExtractor
    {
        private static readonly byte[] FtypMarker = Encoding.ASCII.GetBytes("ftyp");

        /// <summary>
        /// 快速检测文件是否为包含实况视频的 JPG
        /// </summary>
        public static bool IsLivePhoto(string filePath)
        {
            try
            {
                using var fs = new FileStream(filePath, FileMode.Open, FileAccess.Read);
                long length = fs.Length;
                byte[] data;

                if (length <= 10 * 1024 * 1024)
                {
                    data = new byte[length];
                    fs.ReadExactly(data, 0, (int)length);
                }
                else
                {
                    var front = new byte[8 * 1024 * 1024];
                    fs.ReadExactly(front, 0, front.Length);
                    fs.Seek(Math.Max(0, length - 2 * 1024 * 1024), SeekOrigin.Begin);
                    var back = new byte[2 * 1024 * 1024];
                    fs.ReadExactly(back, 0, back.Length);
                    data = front.Concat(back).ToArray();
                }

                return FindFtypPosition(data) >= 0;
            }
            catch
            {
                return false;
            }
        }

        /// <summary>
        /// 从 JPG 中提取嵌入的 MP4 到临时文件，返回临时文件路径；如果不是实况照片返回 null
        /// </summary>
        public static string? ExtractMp4ToTemp(string jpgPath, string? tempDir = null)
        {
            try
            {
                byte[] data = File.ReadAllBytes(jpgPath);
                int ftypPos = FindFtypPosition(data);
                if (ftypPos < 0) return null;

                int videoOffset = ftypPos - 4;
                if (videoOffset < 0) return null;

                ReadOnlySpan<byte> videoData = data.AsSpan(videoOffset);

                string stem = Path.GetFileNameWithoutExtension(jpgPath);
                tempDir ??= Path.GetTempPath();
                string tempPath = Path.Combine(tempDir, $"livephoto_{stem}.mp4");

                using var fs = new FileStream(tempPath, FileMode.Create, FileAccess.Write);
                fs.Write(videoData);
                return tempPath;
            }
            catch
            {
                return null;
            }
        }

        /// <summary>
        /// 在二进制数据中搜索 ftyp 标记并验证
        /// </summary>
        private static int FindFtypPosition(byte[] data)
        {
            for (int i = 0; i <= data.Length - 8; i++)
            {
                if (data[i] == 'f' && data[i + 1] == 't' && data[i + 2] == 'y' && data[i + 3] == 'p')
                {
                    if (i >= 4)
                    {
                        uint boxSize = (uint)((data[i - 4] << 24) | (data[i - 3] << 16) | (data[i - 2] << 8) | data[i - 1]);
                        if (boxSize >= 8 && boxSize <= 1024)
                        {
                            // 验证 brand 为可打印 ASCII
                            bool validBrand = true;
                            for (int b = 0; b < 4; b++)
                            {
                                byte ch = data[i + 4 + b];
                                if (ch < 32 || ch > 126)
                                {
                                    validBrand = false;
                                    break;
                                }
                            }
                            if (validBrand) return i;
                        }
                    }
                }
            }
            return -1;
        }
    }
}
