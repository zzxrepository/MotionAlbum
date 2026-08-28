using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.VisualBasic.FileIO;

namespace LivePhotoViewer.WPF.Core
{
    public sealed record TrashResult(
        IReadOnlyList<string> ProcessedPaths,
        int RecycledCount,
        int FallbackMovedCount,
        int MissingCount,
        int FailedCount);

    public static class TrashService
    {
        public static async Task<TrashResult> MoveToTrashAsync(
            IReadOnlyList<string> paths,
            Action<int, int>? progress = null,
            CancellationToken cancellationToken = default)
        {
            return await Task.Run(() =>
            {
                var processed = new List<string>();
                int recycled = 0, fallback = 0, missing = 0, failed = 0;
                for (int index = 0; index < paths.Count; index++)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    string path = paths[index];
                    if (!File.Exists(path))
                    {
                        missing++;
                        progress?.Invoke(index + 1, paths.Count);
                        continue;
                    }
                    try
                    {
                        FileSystem.DeleteFile(path, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin);
                        processed.Add(path);
                        recycled++;
                    }
                    catch
                    {
                        try
                        {
                            string destination = FallbackDestination(path);
                            File.Move(path, destination);
                            processed.Add(path);
                            fallback++;
                        }
                        catch { failed++; }
                    }
                    progress?.Invoke(index + 1, paths.Count);
                }
                return new TrashResult(processed, recycled, fallback, missing, failed);
            }, cancellationToken);
        }

        private static string FallbackDestination(string source)
        {
            string sourceDirectory = Path.GetDirectoryName(source) ?? throw new IOException("文件没有父目录");
            string trashRoot = Path.Combine(sourceDirectory, ".MotionAlbumTrash");
            Directory.CreateDirectory(trashRoot);
            try { File.SetAttributes(trashRoot, File.GetAttributes(trashRoot) | FileAttributes.Hidden); } catch { }
            string batch = Path.Combine(trashRoot, DateTime.Now.ToString("yyyyMMdd-HHmmss"));
            Directory.CreateDirectory(batch);
            string fileName = Path.GetFileName(source);
            string destination = Path.Combine(batch, fileName);
            if (!File.Exists(destination)) return destination;
            string stem = Path.GetFileNameWithoutExtension(fileName);
            string extension = Path.GetExtension(fileName);
            for (int index = 2; ; index++)
            {
                destination = Path.Combine(batch, $"{stem} ({index}){extension}");
                if (!File.Exists(destination)) return destination;
            }
        }
    }
}
