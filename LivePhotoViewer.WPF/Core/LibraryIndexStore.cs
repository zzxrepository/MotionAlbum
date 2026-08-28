using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using LivePhotoViewer.WPF.Models;

namespace LivePhotoViewer.WPF.Core
{
    public sealed class LibraryIndexEntry
    {
        public string FilePath { get; set; } = string.Empty;
        public long FileSize { get; set; }
        public long ModifiedUtcTicks { get; set; }
        public string? CompanionVideoPath { get; set; }
        public long CompanionFileSize { get; set; }
        public long CompanionModifiedUtcTicks { get; set; }
        public bool IsLivePhoto { get; set; }
        public LivePhotoSource LivePhotoSource { get; set; }
        public bool IsLiveStatusKnown { get; set; }
        public bool IsMetadataLoaded { get; set; }
        public int Width { get; set; }
        public int Height { get; set; }
        public DateTime? CapturedAt { get; set; }
        public string DeviceText { get; set; } = string.Empty;
        public string Software { get; set; } = string.Empty;
        public double? Latitude { get; set; }
        public double? Longitude { get; set; }
        public string PlaceName { get; set; } = string.Empty;

        public bool Matches(PhotoItem photo)
        {
            if (FileSize != photo.FileSize || ModifiedUtcTicks != photo.ModifiedAt.ToUniversalTime().Ticks)
                return false;
            string indexedCompanion = CompanionVideoPath ?? string.Empty;
            string actualCompanion = photo.CompanionVideoPath ?? string.Empty;
            if (!string.Equals(indexedCompanion, actualCompanion, StringComparison.OrdinalIgnoreCase)) return false;
            if (actualCompanion.Length == 0) return true;
            try
            {
                var info = new FileInfo(actualCompanion);
                return info.Exists && info.Length == CompanionFileSize &&
                       info.LastWriteTimeUtc.Ticks == CompanionModifiedUtcTicks;
            }
            catch { return false; }
        }

        public void Apply(PhotoItem photo)
        {
            photo.IsLivePhoto = IsLivePhoto;
            photo.LivePhotoSource = LivePhotoSource;
            photo.IsLiveStatusKnown = IsLiveStatusKnown;
            photo.IsMetadataLoaded = IsMetadataLoaded;
            photo.Width = Width;
            photo.Height = Height;
            photo.CapturedAt = CapturedAt;
            photo.TimelineDate = CapturedAt ?? photo.ModifiedAt;
            photo.DeviceText = DeviceText;
            photo.Software = Software;
            photo.Latitude = Latitude;
            photo.Longitude = Longitude;
            photo.PlaceName = PlaceName;
        }

        public static LibraryIndexEntry FromPhoto(PhotoItem photo)
        {
            long companionSize = 0;
            long companionTicks = 0;
            if (!string.IsNullOrWhiteSpace(photo.CompanionVideoPath))
            {
                try
                {
                    var info = new FileInfo(photo.CompanionVideoPath);
                    companionSize = info.Exists ? info.Length : 0;
                    companionTicks = info.Exists ? info.LastWriteTimeUtc.Ticks : 0;
                }
                catch { }
            }
            return new LibraryIndexEntry
            {
                FilePath = photo.FilePath,
                FileSize = photo.FileSize,
                ModifiedUtcTicks = photo.ModifiedAt.ToUniversalTime().Ticks,
                CompanionVideoPath = photo.CompanionVideoPath,
                CompanionFileSize = companionSize,
                CompanionModifiedUtcTicks = companionTicks,
                IsLivePhoto = photo.IsLivePhoto,
                LivePhotoSource = photo.LivePhotoSource,
                IsLiveStatusKnown = photo.IsLiveStatusKnown,
                IsMetadataLoaded = photo.IsMetadataLoaded,
                Width = photo.Width,
                Height = photo.Height,
                CapturedAt = photo.CapturedAt,
                DeviceText = photo.DeviceText,
                Software = photo.Software,
                Latitude = photo.Latitude,
                Longitude = photo.Longitude,
                PlaceName = photo.PlaceName
            };
        }
    }

    public sealed class LibraryIndexStore
    {
        private readonly string _directory;
        private readonly JsonSerializerOptions _jsonOptions = new() { WriteIndented = false };

        public LibraryIndexStore()
        {
            _directory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "MotionAlbum", "library-index");
            Directory.CreateDirectory(_directory);
        }

        public Dictionary<string, LibraryIndexEntry> Load(string root, bool recursively)
        {
            try
            {
                string file = IndexPath(root, recursively);
                if (!File.Exists(file)) return new Dictionary<string, LibraryIndexEntry>(StringComparer.OrdinalIgnoreCase);
                var entries = JsonSerializer.Deserialize<List<LibraryIndexEntry>>(File.ReadAllText(file), _jsonOptions)
                    ?? new List<LibraryIndexEntry>();
                return entries.Where(entry => entry.FilePath.Length > 0)
                    .GroupBy(entry => entry.FilePath, StringComparer.OrdinalIgnoreCase)
                    .ToDictionary(group => group.Key, group => group.Last(), StringComparer.OrdinalIgnoreCase);
            }
            catch { return new Dictionary<string, LibraryIndexEntry>(StringComparer.OrdinalIgnoreCase); }
        }

        public void Save(string root, bool recursively, IEnumerable<PhotoItem> photos)
        {
            try
            {
                string destination = IndexPath(root, recursively);
                string partial = destination + ".partial";
                File.WriteAllText(partial, JsonSerializer.Serialize(photos.Select(LibraryIndexEntry.FromPhoto), _jsonOptions));
                File.Move(partial, destination, true);
            }
            catch { }
        }

        private string IndexPath(string root, bool recursively)
        {
            byte[] hash = SHA256.HashData(Encoding.UTF8.GetBytes($"{Path.GetFullPath(root)}|{recursively}"));
            return Path.Combine(_directory, $"{Convert.ToHexString(hash.AsSpan(0, 12)).ToLowerInvariant()}.json");
        }
    }
}
