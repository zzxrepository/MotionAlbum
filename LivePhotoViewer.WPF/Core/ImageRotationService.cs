using System;
using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace LivePhotoViewer.WPF.Core
{
    internal static class ImageRotationService
    {
        public static bool CanWrite(string path)
        {
            string extension = Path.GetExtension(path).ToLowerInvariant();
            return extension is ".jpg" or ".jpeg" or ".png" or ".bmp" or ".tif" or ".tiff";
        }

        public static void SaveRotated(
            string sourcePath,
            string destinationPath,
            int clockwiseQuarterTurns,
            bool overwriteOriginal)
        {
            int turns = ((clockwiseQuarterTurns % 4) + 4) % 4;
            if (turns == 0) return;
            if (!CanWrite(destinationPath))
                throw new NotSupportedException("Windows 版当前可写入 JPG、PNG、BMP 和 TIFF；HEIC/WebP 可以预览旋转，但请先转换为这些格式再保存。");

            string destinationDirectory = Path.GetDirectoryName(destinationPath) ?? Path.GetTempPath();
            Directory.CreateDirectory(destinationDirectory);
            string temporaryPath = Path.Combine(
                destinationDirectory,
                $".MotionAlbum-rotate-{Guid.NewGuid():N}{Path.GetExtension(destinationPath)}");

            try
            {
                BitmapFrame frame;
                using (var input = new FileStream(sourcePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                {
                    BitmapDecoder decoder = BitmapDecoder.Create(
                        input,
                        BitmapCreateOptions.PreservePixelFormat,
                        BitmapCacheOption.OnLoad);
                    frame = decoder.Frames[0];
                }

                double angle = turns * 90.0;
                var transformed = new TransformedBitmap(frame, new RotateTransform(angle));
                transformed.Freeze();

                BitmapMetadata? metadata = CloneMetadata(frame.Metadata as BitmapMetadata);
                BitmapFrame outputFrame = BitmapFrame.Create(
                    transformed,
                    frame.Thumbnail,
                    metadata,
                    frame.ColorContexts);
                BitmapEncoder encoder = CreateEncoder(destinationPath);
                encoder.Frames.Add(outputFrame);
                using (var output = new FileStream(temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                    encoder.Save(output);

                // The save dialog can legitimately target an existing file. Always encode to a
                // sibling temporary file first, then swap it into place so a failed encoder never
                // leaves either the original or an existing destination half-written.
                File.Move(temporaryPath, overwriteOriginal ? sourcePath : destinationPath, overwrite: true);
            }
            catch
            {
                if (File.Exists(temporaryPath))
                {
                    try { File.Delete(temporaryPath); } catch { }
                }
                throw;
            }
        }

        private static BitmapMetadata? CloneMetadata(BitmapMetadata? source)
        {
            if (source == null) return null;
            try
            {
                var metadata = (BitmapMetadata)source.Clone();
                if (!metadata.IsFrozen)
                {
                    try { metadata.SetQuery("/app1/ifd/{ushort=274}", (ushort)1); } catch { }
                    try { metadata.SetQuery("/ifd/{ushort=274}", (ushort)1); } catch { }
                }
                return metadata;
            }
            catch
            {
                return null;
            }
        }

        private static BitmapEncoder CreateEncoder(string destinationPath)
        {
            return Path.GetExtension(destinationPath).ToLowerInvariant() switch
            {
                ".jpg" or ".jpeg" => new JpegBitmapEncoder { QualityLevel = 96 },
                ".png" => new PngBitmapEncoder(),
                ".bmp" => new BmpBitmapEncoder(),
                ".tif" or ".tiff" => new TiffBitmapEncoder(),
                _ => throw new NotSupportedException("不支持写入这种图片格式。")
            };
        }
    }
}
