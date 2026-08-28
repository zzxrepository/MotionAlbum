using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Imaging;

namespace LivePhotoViewer.WPF.Core
{
    /// <summary>调用 Windows Shell 缩略图服务，为 MOV/MP4/HEIF 等文件取得系统预览。</summary>
    internal static class ShellThumbnailProvider
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct NativeSize
        {
            public NativeSize(int width, int height) { Width = width; Height = height; }
            public int Width;
            public int Height;
        }

        [Flags]
        private enum ThumbnailFlags
        {
            BiggerSizeOk = 0x1,
            ScaleUp = 0x100
        }

        [ComImport]
        [Guid("BCC18B79-BA16-442F-80C4-8A59C30C463B")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IShellItemImageFactory
        {
            [PreserveSig]
            int GetImage(NativeSize size, ThumbnailFlags flags, out IntPtr bitmapHandle);
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        private static extern void SHCreateItemFromParsingName(
            [MarshalAs(UnmanagedType.LPWStr)] string path,
            IntPtr bindContext,
            ref Guid interfaceId,
            [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory factory);

        [DllImport("gdi32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DeleteObject(IntPtr handle);

        public static byte[]? CreateJpeg(string path, int maximumSize)
        {
            if (!OperatingSystem.IsWindows() || !File.Exists(path)) return null;
            IShellItemImageFactory? factory = null;
            IntPtr bitmapHandle = IntPtr.Zero;
            try
            {
                Guid interfaceId = typeof(IShellItemImageFactory).GUID;
                SHCreateItemFromParsingName(path, IntPtr.Zero, ref interfaceId, out factory);
                int result = factory.GetImage(
                    new NativeSize(maximumSize, maximumSize),
                    ThumbnailFlags.BiggerSizeOk | ThumbnailFlags.ScaleUp,
                    out bitmapHandle);
                if (result != 0 || bitmapHandle == IntPtr.Zero) return null;
                var source = Imaging.CreateBitmapSourceFromHBitmap(
                    bitmapHandle,
                    IntPtr.Zero,
                    Int32Rect.Empty,
                    BitmapSizeOptions.FromEmptyOptions());
                source.Freeze();
                var encoder = new JpegBitmapEncoder { QualityLevel = 88 };
                encoder.Frames.Add(BitmapFrame.Create(source));
                using var output = new MemoryStream();
                encoder.Save(output);
                return output.ToArray();
            }
            catch
            {
                return null;
            }
            finally
            {
                if (bitmapHandle != IntPtr.Zero) DeleteObject(bitmapHandle);
                if (factory != null && Marshal.IsComObject(factory)) Marshal.FinalReleaseComObject(factory);
            }
        }
    }
}
