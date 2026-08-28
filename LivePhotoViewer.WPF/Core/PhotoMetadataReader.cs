using System;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Windows.Media.Imaging;

namespace LivePhotoViewer.WPF.Core
{
    public readonly record struct PhotoMetadataInfo(
        int PixelWidth,
        int PixelHeight,
        DateTime? CapturedAt,
        string? Manufacturer,
        string? Model,
        string? Software,
        double? Latitude,
        double? Longitude)
    {
        public string DeviceText => string.Join(" ", new[] { Manufacturer, Model }
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .Select(value => value!)
            .Distinct(StringComparer.OrdinalIgnoreCase));
    }

    /// <summary>通过 Windows Imaging Component 读取常见 JPEG/HEIF EXIF，不改写原文件。</summary>
    public static class PhotoMetadataReader
    {
        public static PhotoMetadataInfo Read(string path)
        {
            try
            {
                using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
                var frame = BitmapFrame.Create(stream, BitmapCreateOptions.DelayCreation, BitmapCacheOption.None);
                var metadata = frame.Metadata as BitmapMetadata;
                string? manufacturer = FirstString(metadata,
                    "/app1/ifd/{ushort=271}", "/ifd/{ushort=271}", "/tiff/{ushort=271}");
                string? model = FirstString(metadata,
                    "/app1/ifd/{ushort=272}", "/ifd/{ushort=272}", "/tiff/{ushort=272}");
                string? software = FirstString(metadata,
                    "/app1/ifd/{ushort=305}", "/ifd/{ushort=305}", "/tiff/{ushort=305}");
                string? capturedText = FirstString(metadata,
                    "/app1/ifd/exif/{uint=36867}",
                    "/app1/ifd/exif/{ushort=36867}",
                    "/ifd/exif/{uint=36867}",
                    "/app1/ifd/{ushort=306}",
                    "/ifd/{ushort=306}");
                double? latitude = ReadCoordinate(metadata, isLatitude: true);
                double? longitude = ReadCoordinate(metadata, isLatitude: false);
                return new PhotoMetadataInfo(
                    frame.PixelWidth,
                    frame.PixelHeight,
                    ParseExifDate(capturedText),
                    manufacturer?.Trim(),
                    model?.Trim(),
                    software?.Trim(),
                    latitude,
                    longitude);
            }
            catch
            {
                return default;
            }
        }

        private static string? FirstString(BitmapMetadata? metadata, params string[] queries)
        {
            if (metadata == null) return null;
            foreach (string query in queries)
            {
                try
                {
                    object? value = metadata.GetQuery(query);
                    if (value != null && !string.IsNullOrWhiteSpace(value.ToString())) return value.ToString();
                }
                catch { }
            }
            return null;
        }

        private static DateTime? ParseExifDate(string? value)
        {
            if (string.IsNullOrWhiteSpace(value)) return null;
            string[] formats = { "yyyy:MM:dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy:MM:dd HH:mm:ssK" };
            return DateTime.TryParseExact(
                value.Trim().TrimEnd('\0'),
                formats,
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeLocal,
                out DateTime date) ? date : null;
        }

        private static double? ReadCoordinate(BitmapMetadata? metadata, bool isLatitude)
        {
            if (metadata == null) return null;
            ushort referenceTag = isLatitude ? (ushort)1 : (ushort)3;
            ushort coordinateTag = isLatitude ? (ushort)2 : (ushort)4;
            object? reference = FirstValue(metadata,
                $"/app1/ifd/gps/{{ushort={referenceTag}}}",
                $"/ifd/gps/{{ushort={referenceTag}}}");
            object? coordinate = FirstValue(metadata,
                $"/app1/ifd/gps/{{ushort={coordinateTag}}}",
                $"/ifd/gps/{{ushort={coordinateTag}}}");
            double? value = CoordinateValue(coordinate);
            if (value == null) return null;
            string direction = reference?.ToString()?.Trim().TrimEnd('\0') ?? string.Empty;
            if (direction.Equals("S", StringComparison.OrdinalIgnoreCase) ||
                direction.Equals("W", StringComparison.OrdinalIgnoreCase)) value = -value;
            return value is >= -180 and <= 180 ? value : null;
        }

        private static object? FirstValue(BitmapMetadata metadata, params string[] queries)
        {
            foreach (string query in queries)
            {
                try
                {
                    object? value = metadata.GetQuery(query);
                    if (value != null) return value;
                }
                catch { }
            }
            return null;
        }

        private static double? CoordinateValue(object? value)
        {
            if (value is ulong[] rationals && rationals.Length >= 3)
            {
                double degrees = RationalValue(rationals[0]);
                double minutes = RationalValue(rationals[1]);
                double seconds = RationalValue(rationals[2]);
                return degrees + minutes / 60 + seconds / 3600;
            }
            if (value is uint[] unsigned && unsigned.Length >= 6)
            {
                double degrees = unsigned[1] == 0 ? 0 : (double)unsigned[0] / unsigned[1];
                double minutes = unsigned[3] == 0 ? 0 : (double)unsigned[2] / unsigned[3];
                double seconds = unsigned[5] == 0 ? 0 : (double)unsigned[4] / unsigned[5];
                return degrees + minutes / 60 + seconds / 3600;
            }
            return null;
        }

        private static double RationalValue(ulong packed)
        {
            // WIC packs a TIFF RATIONAL as numerator in the low DWORD and denominator in the high DWORD.
            uint numerator = (uint)(packed & uint.MaxValue);
            uint denominator = (uint)(packed >> 32);
            return denominator == 0 ? 0 : (double)numerator / denominator;
        }
    }
}
