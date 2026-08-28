using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using LivePhotoViewer.WPF.Models;

namespace LivePhotoViewer.WPF.Core
{
    public readonly record struct EmbeddedVideoRange(long Offset, long Length, LivePhotoSource Source);

    /// <summary>
    /// Apple 双文件 Live Photo、华为/荣耀以及 Android Motion Photo 解析器。
    /// 检测只读取固定大小窗口；提取严格复制已验证的 MP4 box 范围，避免把
    /// LIVE_、防抖矩阵或 OPPO trailer 一并交给播放器。
    /// </summary>
    public static class LivePhotoExtractor
    {
        private const int ChunkSize = 1024 * 1024;
        private const int MetadataProbeSize = 1024 * 1024;
        private const int TailProbeSize = 512 * 1024;
        private static readonly Regex UuidRegex = new(
            "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
            RegexOptions.Compiled);

        public static readonly HashSet<string> SupportedImageExtensions = new(
            new[] { ".jpg", ".jpeg", ".heic", ".heif", ".png", ".webp", ".tif", ".tiff", ".bmp" },
            StringComparer.OrdinalIgnoreCase);

        public static readonly HashSet<string> SupportedVideoExtensions = new(
            new[] { ".mov", ".mp4", ".m4v" },
            StringComparer.OrdinalIgnoreCase);

        private static string VideoCacheDirectory
        {
            get
            {
                string path = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "MotionAlbum", "video-cache");
                Directory.CreateDirectory(path);
                return path;
            }
        }

        public static bool IsSupportedImage(string path) =>
            SupportedImageExtensions.Contains(Path.GetExtension(path));

        public static bool IsSupportedVideo(string path) =>
            SupportedVideoExtensions.Contains(Path.GetExtension(path));

        public static bool IsLivePhoto(string filePath, string? companionVideoPath = null)
        {
            if (!string.IsNullOrWhiteSpace(companionVideoPath) && IsLikelyVideoFile(companionVideoPath))
                return true;
            return TryGetEmbeddedVideoRange(filePath, out _);
        }

        public static bool TryGetEmbeddedVideoRange(string filePath, out EmbeddedVideoRange range)
        {
            range = default;
            try
            {
                if (!File.Exists(filePath) || !IsSupportedImage(filePath)) return false;
                string extension = Path.GetExtension(filePath);
                if (!new[] { ".jpg", ".jpeg", ".heic", ".heif" }.Contains(extension, StringComparer.OrdinalIgnoreCase))
                    return false;

                long fileSize = new FileInfo(filePath).Length;
                if (fileSize < 16) return false;
                string metadata = ReadMetadataText(filePath, fileSize);

                if ((metadata.Contains("MotionPhoto", StringComparison.OrdinalIgnoreCase) ||
                     metadata.Contains("video/mp4", StringComparison.OrdinalIgnoreCase)) &&
                    TryContainerMotionPhotoRange(filePath, fileSize, metadata, out range))
                {
                    return true;
                }

                long microVideoLength = FirstInteger(metadata,
                    "(?:[A-Za-z_][\\w.-]*:)?MicroVideoOffset\\s*=\\s*[\\\"'](\\d+)[\\\"']",
                    "(?:[A-Za-z_][\\w.-]*:)?MediaDataOffset\\s*=\\s*[\\\"'](\\d+)[\\\"']");
                if (microVideoLength > 0 && microVideoLength < fileSize)
                {
                    long suggestedOffset = fileSize - microVideoLength;
                    long? validatedOffset = ValidateVideoStart(filePath, suggestedOffset, microVideoLength);
                    if (validatedOffset == suggestedOffset)
                    {
                        range = new EmbeddedVideoRange(
                            suggestedOffset,
                            microVideoLength,
                            LivePhotoSource.AndroidMotionPhotoV1);
                        return true;
                    }
                }

                bool hasHuaweiTail = TailContains(filePath, fileSize, "LIVE_");
                bool isHeif = extension.Equals(".heic", StringComparison.OrdinalIgnoreCase) ||
                              extension.Equals(".heif", StringComparison.OrdinalIgnoreCase);
                var offsets = FindFtypOffsets(filePath, isHeif ? 2 : 1);

                if (isHeif)
                {
                    if (!hasHuaweiTail || offsets.Count < 2) return false;
                    long offset = offsets[1];
                    long? length = ParseMp4Length(filePath, offset, fileSize - offset);
                    if (length is null) return false;
                    range = new EmbeddedVideoRange(offset, length.Value, LivePhotoSource.HuaweiHonor);
                    return true;
                }

                if (offsets.Count == 0) return false;
                long embeddedOffset = offsets[0];
                long? embeddedLength = ParseMp4Length(filePath, embeddedOffset, fileSize - embeddedOffset);
                if (embeddedLength is null) return false;
                range = new EmbeddedVideoRange(
                    embeddedOffset,
                    embeddedLength.Value,
                    hasHuaweiTail ? LivePhotoSource.HuaweiHonor : LivePhotoSource.EmbeddedMp4);
                return true;
            }
            catch
            {
                range = default;
                return false;
            }
        }

        public static string? GetPlayableVideoPath(
            string imagePath,
            string? companionVideoPath,
            string? outputDirectory = null)
        {
            if (!string.IsNullOrWhiteSpace(companionVideoPath) && IsLikelyVideoFile(companionVideoPath))
                return companionVideoPath;
            return ExtractMp4ToTemp(imagePath, outputDirectory);
        }

        public static string? ExtractMp4ToTemp(string imagePath, string? outputDirectory = null)
        {
            if (!TryGetEmbeddedVideoRange(imagePath, out var range)) return null;
            try
            {
                var info = new FileInfo(imagePath);
                outputDirectory ??= VideoCacheDirectory;
                Directory.CreateDirectory(outputDirectory);
                string fingerprint = Fingerprint($"{Path.GetFullPath(imagePath)}|{range.Offset}|{range.Length}|{info.Length}|{info.LastWriteTimeUtc.Ticks}");
                string destination = Path.Combine(outputDirectory, $"{fingerprint}.mp4");
                if (File.Exists(destination) && new FileInfo(destination).Length == range.Length)
                    return destination;

                string partial = destination + ".partial";
                if (File.Exists(partial)) File.Delete(partial);
                using (var input = new FileStream(imagePath, FileMode.Open, FileAccess.Read, FileShare.Read))
                using (var output = new FileStream(partial, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    input.Position = range.Offset;
                    CopyExactly(input, output, range.Length);
                }
                File.Move(partial, destination, true);
                return destination;
            }
            catch
            {
                return null;
            }
        }

        public static Dictionary<string, string> ResolveCompanionVideos(
            IEnumerable<string> imagePaths,
            IEnumerable<string> videoPaths)
        {
            var images = imagePaths.Distinct(StringComparer.OrdinalIgnoreCase).ToList();
            var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            var videos = videoPaths.Where(IsLikelyVideoFile).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
            var imageUuids = images.ToDictionary(
                path => path,
                path => ReadCandidateUuids(path, requireAppleKey: false).ToArray(),
                StringComparer.OrdinalIgnoreCase);
            var videoUuids = videos.ToDictionary(
                path => path,
                path => ReadCandidateUuids(path, requireAppleKey: true).ToArray(),
                StringComparer.OrdinalIgnoreCase);
            var videosByUuid = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
            foreach (string video in videos)
            {
                foreach (string uuid in videoUuids[video])
                {
                    if (!videosByUuid.TryGetValue(uuid, out var list))
                    {
                        list = new List<string>();
                        videosByUuid[uuid] = list;
                    }
                    list.Add(video);
                }
            }

            var usedVideos = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string image in images)
            {
                foreach (string uuid in imageUuids[image])
                {
                    if (!videosByUuid.TryGetValue(uuid, out var candidates)) continue;
                    string? video = candidates.FirstOrDefault(path => !usedVideos.Contains(path));
                    if (video == null) continue;
                    result[image] = video;
                    usedVideos.Add(video);
                    break;
                }
            }

            // Apple 元数据缺失时才按“同目录 + 同名”降级配对，且一个 MOV 只归属一张图。
            var videosByStem = videos
                .Where(path => videoUuids[path].Length == 0 && !usedVideos.Contains(path))
                .GroupBy(SidecarKey, StringComparer.OrdinalIgnoreCase)
                .ToDictionary(group => group.Key, group => group.OrderBy(path => path).ToList(), StringComparer.OrdinalIgnoreCase);
            foreach (string image in images.Where(path => !result.ContainsKey(path) && imageUuids[path].Length == 0))
            {
                if (!videosByStem.TryGetValue(SidecarKey(image), out var candidates)) continue;
                string? video = candidates.FirstOrDefault(path => !usedVideos.Contains(path));
                if (video == null) continue;
                result[image] = video;
                usedVideos.Add(video);
            }
            return result;
        }

        private static string SidecarKey(string path) => Path.Combine(
            Path.GetDirectoryName(path) ?? string.Empty,
            Path.GetFileNameWithoutExtension(path));

        private static bool TryContainerMotionPhotoRange(
            string filePath,
            long fileSize,
            string metadata,
            out EmbeddedVideoRange range)
        {
            range = default;
            var tags = Regex.Matches(
                    metadata,
                    "<(?:[A-Za-z_][\\w.-]*:)?Item\\b[^>]*>",
                    RegexOptions.IgnoreCase | RegexOptions.Singleline)
                .Select(match => match.Value)
                .ToList();
            long trailingLength = 0;

            for (int index = tags.Count - 1; index >= 0; index--)
            {
                string attributes = tags[index];
                string semantic = FirstString(attributes, "(?:[A-Za-z_][\\w.-]*:)?Semantic\\s*=\\s*[\\\"']([^\\\"']+)[\\\"']");
                string mime = FirstString(attributes, "(?:[A-Za-z_][\\w.-]*:)?Mime\\s*=\\s*[\\\"']([^\\\"']+)[\\\"']");
                long length = FirstInteger(attributes, "(?:[A-Za-z_][\\w.-]*:)?Length\\s*=\\s*[\\\"'](\\d+)[\\\"']");
                long padding = FirstInteger(attributes, "(?:[A-Za-z_][\\w.-]*:)?Padding\\s*=\\s*[\\\"'](\\d+)[\\\"']");

                bool isMotion = semantic.Equals("MotionPhoto", StringComparison.OrdinalIgnoreCase) ||
                                mime.Equals("video/mp4", StringComparison.OrdinalIgnoreCase);
                if (isMotion)
                {
                    if (length <= 0 || trailingLength > fileSize || length + padding > fileSize - trailingLength)
                        return false;
                    trailingLength += length + padding;
                    long containerOffset = fileSize - trailingLength;
                    long pureLength = FirstInteger(metadata,
                        "OpCamera:VideoLength\\s*=\\s*[\\\"'](\\d+)[\\\"']",
                        "MiCamera:VideoLength\\s*=\\s*[\\\"'](\\d+)[\\\"']");
                    if (pureLength <= 0) pureLength = length;
                    long? videoOffset = ValidateVideoStart(filePath, containerOffset, length);
                    if (videoOffset is null) return false;
                    long skipped = videoOffset.Value - containerOffset;
                    if (skipped < 0 || skipped >= length || pureLength > length - skipped) return false;
                    range = new EmbeddedVideoRange(
                        videoOffset.Value,
                        pureLength,
                        metadata.Contains("OpCamera:VideoLength", StringComparison.OrdinalIgnoreCase)
                            ? LivePhotoSource.OppoMotionPhoto
                            : LivePhotoSource.AndroidMotionPhotoV2);
                    return true;
                }

                if (length < 0 || padding < 0 || length + padding > fileSize - trailingLength) return false;
                trailingLength += length + padding;
            }
            return false;
        }

        private static long? ValidateVideoStart(string filePath, long suggestedOffset, long maximumLength)
        {
            if (maximumLength < 12 || suggestedOffset < 0) return null;
            using var stream = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.Read);
            stream.Position = suggestedOffset;
            int count = (int)Math.Min(maximumLength, 128);
            byte[] data = new byte[count];
            int actual = stream.Read(data, 0, data.Length);
            Array.Resize(ref data, actual);
            foreach (int marker in ValidatedFtypMarkerIndices(data))
            {
                long relativeOffset = marker - 4;
                if (relativeOffset + 12 <= maximumLength) return suggestedOffset + relativeOffset;
            }
            return null;
        }

        private static List<long> FindFtypOffsets(string filePath, int maximumCount)
        {
            var offsets = new List<long>();
            using var stream = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.Read);
            byte[] chunk = new byte[ChunkSize];
            byte[] carry = Array.Empty<byte>();
            long bytesRead = 0;
            while (true)
            {
                int count = stream.Read(chunk, 0, chunk.Length);
                if (count <= 0) break;
                byte[] window = new byte[carry.Length + count];
                Buffer.BlockCopy(carry, 0, window, 0, carry.Length);
                Buffer.BlockCopy(chunk, 0, window, carry.Length, count);
                long windowStart = bytesRead - carry.Length;
                foreach (int marker in ValidatedFtypMarkerIndices(window))
                {
                    long offset = windowStart + marker - 4;
                    if (offsets.Count == 0 || offsets[^1] != offset) offsets.Add(offset);
                    if (offsets.Count >= maximumCount) return offsets;
                }
                bytesRead += count;
                int carryCount = Math.Min(32, window.Length);
                carry = window[^carryCount..];
            }
            return offsets;
        }

        private static IEnumerable<int> ValidatedFtypMarkerIndices(byte[] data)
        {
            for (int index = 4; index + 8 <= data.Length; index++)
            {
                if (data[index] != (byte)'f' || data[index + 1] != (byte)'t' ||
                    data[index + 2] != (byte)'y' || data[index + 3] != (byte)'p') continue;
                uint boxSize = BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(index - 4, 4));
                if (boxSize < 8 || boxSize > 1024) continue;
                bool printableBrand = data.AsSpan(index + 4, 4).ToArray().All(value => value is >= 32 and <= 126);
                if (printableBrand) yield return index;
            }
        }

        private static long? ParseMp4Length(string filePath, long offset, long maximumLength)
        {
            if (maximumLength < 16) return null;
            using var stream = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.Read);
            long limit = offset + maximumLength;
            long position = offset;
            bool sawFtyp = false, sawMoov = false, sawMdat = false;
            int boxCount = 0;
            byte[] header = new byte[16];
            while (position + 8 <= limit && boxCount < 4096)
            {
                stream.Position = position;
                int read = stream.Read(header, 0, header.Length);
                if (read < 8) return null;
                uint size32 = BinaryPrimitives.ReadUInt32BigEndian(header.AsSpan(0, 4));
                string type = Encoding.ASCII.GetString(header, 4, 4);
                long headerLength;
                long boxLength;
                if (size32 == 1)
                {
                    if (read < 16) return null;
                    headerLength = 16;
                    ulong size64 = BinaryPrimitives.ReadUInt64BigEndian(header.AsSpan(8, 8));
                    if (size64 > long.MaxValue) return null;
                    boxLength = (long)size64;
                }
                else if (size32 == 0)
                {
                    headerLength = 8;
                    boxLength = limit - position;
                }
                else
                {
                    headerLength = 8;
                    boxLength = size32;
                }
                if (boxLength < headerLength || boxLength > limit - position) return null;
                if (boxCount == 0 && type != "ftyp") return null;
                sawFtyp |= type == "ftyp";
                sawMoov |= type == "moov";
                sawMdat |= type == "mdat";
                position += boxLength;
                boxCount++;
                if (sawFtyp && sawMoov && sawMdat) return position - offset;
            }
            return null;
        }

        private static bool IsLikelyVideoFile(string path)
        {
            try
            {
                if (!File.Exists(path) || !IsSupportedVideo(path)) return false;
                using var stream = File.OpenRead(path);
                int length = (int)Math.Min(4096, stream.Length);
                byte[] header = new byte[length];
                int read = stream.Read(header, 0, header.Length);
                Array.Resize(ref header, read);
                return ValidatedFtypMarkerIndices(header).Any();
            }
            catch { return false; }
        }

        private static string ReadMetadataText(string path, long fileSize)
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            int headLength = (int)Math.Min(fileSize, MetadataProbeSize);
            byte[] head = new byte[headLength];
            stream.ReadExactly(head);
            if (fileSize <= MetadataProbeSize) return Encoding.UTF8.GetString(head);
            int tailLength = (int)Math.Min(TailProbeSize, fileSize - headLength);
            byte[] tail = new byte[tailLength];
            stream.Position = fileSize - tailLength;
            stream.ReadExactly(tail);
            return Encoding.UTF8.GetString(head) + "\n" + Encoding.UTF8.GetString(tail);
        }

        private static bool TailContains(string path, long fileSize, string marker)
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            int length = (int)Math.Min(4096, fileSize);
            byte[] tail = new byte[length];
            stream.Position = fileSize - length;
            stream.ReadExactly(tail);
            return Encoding.ASCII.GetString(tail).Contains(marker, StringComparison.Ordinal);
        }

        private static IEnumerable<string> ReadCandidateUuids(string path, bool requireAppleKey)
        {
            try
            {
                string text;
                if (requireAppleKey)
                {
                    text = ReadMovieMetadataText(path) ?? string.Empty;
                }
                else
                {
                    long size = new FileInfo(path).Length;
                    text = ReadMetadataText(path, size);
                }
                if (requireAppleKey && !text.Contains("com.apple.quicktime.content.identifier", StringComparison.Ordinal))
                    return Array.Empty<string>();
                return UuidRegex.Matches(text).Select(match => match.Value.ToLowerInvariant()).Distinct().ToArray();
            }
            catch { return Array.Empty<string>(); }
        }

        private static string? ReadMovieMetadataText(string path)
        {
            const long maximumMetadataBoxSize = 64L * 1024 * 1024;
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            long fileSize = stream.Length;
            long position = 0;
            byte[] header = new byte[16];
            while (position + 8 <= fileSize)
            {
                stream.Position = position;
                int read = stream.Read(header, 0, header.Length);
                if (read < 8) return null;
                uint size32 = BinaryPrimitives.ReadUInt32BigEndian(header.AsSpan(0, 4));
                string type = Encoding.ASCII.GetString(header, 4, 4);
                long boxLength;
                if (size32 == 1)
                {
                    if (read < 16) return null;
                    ulong size64 = BinaryPrimitives.ReadUInt64BigEndian(header.AsSpan(8, 8));
                    if (size64 > long.MaxValue) return null;
                    boxLength = (long)size64;
                }
                else if (size32 == 0)
                {
                    boxLength = fileSize - position;
                }
                else
                {
                    boxLength = size32;
                }
                if (boxLength < 8 || boxLength > fileSize - position) return null;
                if (type == "moov")
                {
                    if (boxLength > maximumMetadataBoxSize || boxLength > int.MaxValue) return null;
                    byte[] box = new byte[(int)boxLength];
                    stream.Position = position;
                    stream.ReadExactly(box);
                    return Encoding.UTF8.GetString(box);
                }
                position += boxLength;
            }
            return null;
        }

        private static string FirstString(string text, string pattern)
        {
            var match = Regex.Match(text, pattern, RegexOptions.IgnoreCase | RegexOptions.Singleline);
            return match.Success && match.Groups.Count > 1 ? match.Groups[1].Value : string.Empty;
        }

        private static long FirstInteger(string text, params string[] patterns)
        {
            foreach (string pattern in patterns)
            {
                string value = FirstString(text, pattern);
                if (long.TryParse(value, out long result) && result >= 0) return result;
            }
            return 0;
        }

        private static string Fingerprint(string value)
        {
            byte[] hash = SHA256.HashData(Encoding.UTF8.GetBytes(value));
            return Convert.ToHexString(hash.AsSpan(0, 12)).ToLowerInvariant();
        }

        private static void CopyExactly(Stream input, Stream output, long byteCount)
        {
            byte[] buffer = new byte[ChunkSize];
            long remaining = byteCount;
            while (remaining > 0)
            {
                int requested = (int)Math.Min(buffer.Length, remaining);
                int read = input.Read(buffer, 0, requested);
                if (read <= 0) throw new EndOfStreamException();
                output.Write(buffer, 0, read);
                remaining -= read;
            }
        }
    }
}
