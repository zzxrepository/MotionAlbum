using System.Buffers.Binary;
using System.Text;
using LivePhotoViewer.WPF.Core;
using LivePhotoViewer.WPF.Models;

string sampleRoot = args.FirstOrDefault() ?? FindSampleRoot();
string scratch = Path.Combine(Path.GetTempPath(), $"MotionAlbum-Windows-SelfTest-{Guid.NewGuid():N}");
Directory.CreateDirectory(scratch);

try
{
    RunSyntheticParserTests(scratch);
    RunLibraryIndexTests(scratch);
    if (Directory.Exists(sampleRoot)) RunRealSampleTests(sampleRoot, scratch);
    else Console.WriteLine("[SKIP] 未找到 samples，已完成合成格式测试。");
    Console.WriteLine("Windows 实况解析自检通过。");
    return 0;
}
catch (Exception ex)
{
    Console.Error.WriteLine($"自检失败：{ex.Message}");
    return 1;
}
finally
{
    try { Directory.Delete(scratch, recursive: true); } catch { }
}

static void RunRealSampleTests(string sampleRoot, string scratch)
{
    string[] files = Directory.GetFiles(sampleRoot, "*", SearchOption.AllDirectories);
    string[] images = files.Where(LivePhotoExtractor.IsSupportedImage).ToArray();
    string[] videos = files.Where(LivePhotoExtractor.IsSupportedVideo).ToArray();
    Dictionary<string, string> companions = LivePhotoExtractor.ResolveCompanionVideos(images, videos);

    string[] appleLiveImages = images.Where(path =>
        path.Contains($"{Path.DirectorySeparatorChar}Apple{Path.DirectorySeparatorChar}") &&
        Path.GetFileName(path).StartsWith("Apple_LivePhoto_", StringComparison.OrdinalIgnoreCase)).ToArray();
    Assert(appleLiveImages.Length == 2, $"Apple 测试图片数量异常：{appleLiveImages.Length}");
    Assert(appleLiveImages.All(companions.ContainsKey), "Apple HEIC/JPG 没有全部与 MOV 配对");

    string honorDirectory = Path.Combine(sampleRoot, "荣耀");
    if (Directory.Exists(honorDirectory))
    {
        string[] honorLive = Directory.GetFiles(honorDirectory, "Honor_LivePhoto_*.jpg");
        Assert(honorLive.Length >= 4, "荣耀实况样本不足");
        foreach (string path in honorLive)
        {
            long beforeSize = new FileInfo(path).Length;
            DateTime beforeDate = File.GetLastWriteTimeUtc(path);
            Assert(LivePhotoExtractor.TryGetEmbeddedVideoRange(path, out var range), $"未识别荣耀实况：{Path.GetFileName(path)}");
            Assert(range.Source == LivePhotoSource.HuaweiHonor, $"荣耀来源分类错误：{range.Source}");
            string? video = LivePhotoExtractor.ExtractMp4ToTemp(path, scratch);
            Assert(video != null && File.Exists(video), $"荣耀视频提取失败：{Path.GetFileName(path)}");
            Assert(new FileInfo(video!).Length == range.Length, "提取视频长度与解析范围不一致");
            Assert(new FileInfo(path).Length == beforeSize && File.GetLastWriteTimeUtc(path) == beforeDate, "解析过程修改了原图");
        }
        string still = Path.Combine(honorDirectory, "Honor_StillPhoto_01.jpg");
        if (File.Exists(still)) Assert(!LivePhotoExtractor.IsLivePhoto(still), "荣耀静态照片被误判为实况");
    }

    string huaweiDirectory = Path.Combine(sampleRoot, "Huawei");
    if (Directory.Exists(huaweiDirectory))
    {
        foreach (string still in Directory.GetFiles(huaweiDirectory, "Huawei_StillPhoto_*.jpg"))
            Assert(!LivePhotoExtractor.IsLivePhoto(still), $"华为静态照片被误判：{Path.GetFileName(still)}");
    }
    Console.WriteLine($"[PASS] 真实样本：Apple 配对 {appleLiveImages.Length} 组，荣耀实况与静态误判检查通过。");
}

static void RunSyntheticParserTests(string scratch)
{
    byte[] mp4 = MakeMinimalMp4();
    var cases = new[]
    {
        ("xiaomi-v1.jpg", $"<x:xmpmeta GCamera:MicroVideoOffset=\"{mp4.Length}\" />", LivePhotoSource.AndroidMotionPhotoV1),
        ("android-v2.jpg", $"<x:xmpmeta MotionPhoto=\"1\"><Container:Item Item:Semantic=\"MotionPhoto\" Item:Mime=\"video/mp4\" Item:Length=\"{mp4.Length}\" /></x:xmpmeta>", LivePhotoSource.AndroidMotionPhotoV2),
        ("oppo-v2.jpg", $"<x:xmpmeta MotionPhoto=\"1\" OpCamera:VideoLength=\"{mp4.Length}\"><Container:Item Item:Semantic=\"MotionPhoto\" Item:Mime=\"video/mp4\" Item:Length=\"{mp4.Length}\" /></x:xmpmeta>", LivePhotoSource.OppoMotionPhoto),
        ("huawei-honor.jpg", "JPEG-HEADER", LivePhotoSource.HuaweiHonor)
    };

    foreach (var item in cases)
    {
        string path = Path.Combine(scratch, item.Item1);
        byte[] prefix = Encoding.UTF8.GetBytes(item.Item2);
        byte[] suffix = item.Item3 == LivePhotoSource.HuaweiHonor ? Encoding.ASCII.GetBytes("LIVE_00000000") : Array.Empty<byte>();
        File.WriteAllBytes(path, prefix.Concat(mp4).Concat(suffix).ToArray());
        Assert(LivePhotoExtractor.TryGetEmbeddedVideoRange(path, out var range), $"合成格式未识别：{item.Item1}");
        Assert(range.Source == item.Item3, $"合成格式来源错误：{item.Item1} -> {range.Source}");
        string? video = LivePhotoExtractor.ExtractMp4ToTemp(path, scratch);
        Assert(video != null && File.ReadAllBytes(video!).SequenceEqual(mp4), $"合成格式提取内容错误：{item.Item1}");
    }
    Console.WriteLine("[PASS] 小米/Android V1、V2、OPPO、华为/荣耀合成格式测试通过。");
}

static void RunLibraryIndexTests(string scratch)
{
    string root = Path.Combine(scratch, "indexed-library");
    Directory.CreateDirectory(root);
    string image = Path.Combine(root, "fingerprint.jpg");
    File.WriteAllBytes(image, Encoding.ASCII.GetBytes("first-version"));
    var info = new FileInfo(image);
    var photo = new PhotoItem
    {
        FilePath = image,
        FileName = info.Name,
        Directory = root,
        MediaKind = MediaKind.Image,
        FileSize = info.Length,
        ModifiedAt = info.LastWriteTime,
        TimelineDate = info.LastWriteTime,
        IsLivePhoto = true,
        LivePhotoSource = LivePhotoSource.AndroidMotionPhotoV2,
        IsLiveStatusKnown = true,
        IsMetadataLoaded = true,
        Width = 1920,
        Height = 1080,
        DeviceText = "SelfTest Camera"
    };
    var store = new LibraryIndexStore();
    store.Save(root, recursively: true, new[] { photo });
    Dictionary<string, LibraryIndexEntry> loaded = store.Load(root, recursively: true);
    Assert(loaded.TryGetValue(image, out LibraryIndexEntry? entry), "图库索引没有恢复照片");
    if (entry == null) throw new InvalidOperationException("图库索引条目为空");
    Assert(entry.Matches(photo), "未修改文件的图库索引指纹不匹配");
    var restored = new PhotoItem
    {
        FilePath = image,
        FileName = info.Name,
        Directory = root,
        MediaKind = MediaKind.Image,
        FileSize = info.Length,
        ModifiedAt = info.LastWriteTime,
        TimelineDate = info.LastWriteTime
    };
    entry.Apply(restored);
    Assert(restored.IsLivePhoto && restored.Width == 1920 && restored.DeviceText == "SelfTest Camera",
        "图库索引没有完整恢复识别和元数据状态");

    File.AppendAllText(image, "-changed");
    info.Refresh();
    restored.FileSize = info.Length;
    restored.ModifiedAt = info.LastWriteTime;
    Assert(!entry.Matches(restored), "文件变化后仍错误复用了旧图库索引");
    Console.WriteLine("[PASS] Windows 图库索引指纹与缓存失效测试通过。");
}

static byte[] MakeMinimalMp4()
{
    byte[] ftypPayload = Encoding.ASCII.GetBytes("isom\0\0\0\0");
    return MakeBox("ftyp", ftypPayload)
        .Concat(MakeBox("moov", Array.Empty<byte>()))
        .Concat(MakeBox("mdat", Array.Empty<byte>()))
        .ToArray();
}

static byte[] MakeBox(string type, byte[] payload)
{
    byte[] box = new byte[8 + payload.Length];
    BinaryPrimitives.WriteUInt32BigEndian(box.AsSpan(0, 4), (uint)box.Length);
    Encoding.ASCII.GetBytes(type).CopyTo(box, 4);
    payload.CopyTo(box, 8);
    return box;
}

static string FindSampleRoot()
{
    DirectoryInfo? directory = new(AppContext.BaseDirectory);
    while (directory != null)
    {
        string candidate = Path.Combine(directory.FullName, "samples");
        if (Directory.Exists(candidate)) return candidate;
        directory = directory.Parent;
    }
    return Path.Combine(Directory.GetCurrentDirectory(), "samples");
}

static void Assert(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
}
