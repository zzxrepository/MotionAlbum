# 灵动相册（MotionAlbum）

灵动相册是一款面向 macOS 与 Windows 的本地实况照片管理工具。它读取手机导入电脑后的原始照片和配套视频，识别 Apple Live Photo、华为/荣耀动态照片以及常见 Android Motion Photo，在桌面端完成浏览、播放、筛选、标记、导出和整理。

应用默认只读取原始媒体，不会为了预览而改写 JPG、HEIC、MOV 或 MP4。实况视频需要拆出时，会写入独立的本地缓存。

## 主要能力

- 将用户选择的大目录作为图库根目录建立索引，并在侧边栏按层级浏览其中的照片目录。
- 默认只展示当前选中目录本层的照片；需要汇总时可选择“包含所选目录的子目录”，切换目录无需重新扫描。
- 目录树显示每个目录连同下级目录的媒体总数；侧边栏可像 VS Code 一样左右拖动，并记住上次宽度。
- 识别图片尾部内嵌 MP4 的 Android / 华为系动态照片。
- 将 Apple 图片资源与 MOV 配对，在图库中合并为一张 Live Photo。
- 在主窗口内播放实况和普通视频，并在静态封面与动态内容之间切换。
- 使用方向键或 `WASD` 浏览，按 `Enter` 打开当前照片。
- 通过缩放按钮、滑杆、`Ctrl` + 滚轮或触控缩放调整照片墙；最大档按单张居中展示。
- 按拍摄时间、修改时间或文件名排序，可按月或按日分组。
- 按全部、实况、视频、我喜欢和具体标签筛选。
- 搜索文件名、目录、标签、设备型号、拍摄软件、地点或 GPS 坐标。
- 读取 EXIF 拍摄时间、像素尺寸、设备、软件和 GPS 信息。
- 使用爱心维护“我喜欢”，不改变照片内容。
- 为照片添加本地标签，并按标签统计和筛选。
- 保存实况播放结束时的停留画面；该设置只影响本机预览。
- 导出当前筛选中的原始资源，Apple Live Photo 的配套 MOV 会一起导出。
- 将“我喜欢”的原始资源通过 adb 同步到安卓手机的 `DCIM/MotionAlbum`。
- 将单张或批量媒体移入系统废纸篓 / 回收站，并同时处理配套视频。
- 记住最近打开的目录、侧边栏显示状态与宽度、标签、喜欢状态和停留画面。

## 支持的实况格式

| 来源 | 电脑中常见结构 | 识别方式 |
| --- | --- | --- |
| Apple | `HEIC/JPG + MOV` | 优先匹配 Apple 内容标识 UUID，元数据缺失时按同目录同名降级配对 |
| 华为 / 荣耀 JPG | JPG 后附 MP4 及厂商尾部数据 | 定位并校验 MP4 `ftyp` 和 box 范围，只提取真实视频部分 |
| 华为 / 荣耀 HEIC | HEIC 容器后附第二段 MP4 | 结合 `LIVE_` 尾标与第二个有效 `ftyp` 定位视频 |
| 小米 / Google / 新版 vivo | Motion Photo V1 / V2 | 解析 XMP `MicroVideoOffset`、`MediaDataOffset` 或容器 `Item:Length` |
| OPPO | Motion Photo V2 | 解析容器项目，并使用 `OpCamera:VideoLength` 限定纯视频范围 |
| 通用内嵌格式 | JPG 后附标准 MP4 | 校验 `ftyp`、`moov`、`mdat` 等 box 后提取 |
| 普通视频 | MOV / MP4 / M4V | 作为独立媒体显示和播放 |

目前扫描的图片扩展名包括 JPG、JPEG、HEIC、HEIF、PNG、WebP、TIFF 和 BMP。内嵌实况解析主要针对 JPG/JPEG 与 HEIC/HEIF；其他图片格式按静态照片处理。

## 工作原理

### 1. 扫描与配对

应用先枚举受支持的图片和视频。Apple 资源会读取图片与 MOV 中的候选标识符进行一对一配对；只有双方均缺少可用 Apple 标识时，才使用同目录、同文件名作为降级规则。已经配对的 MOV 不会在图库中重复出现。

### 2. 实况检测

对于单文件动态照片，解析器读取文件头尾的有限窗口，识别 XMP 偏移、厂商尾标和 MP4 box。所有候选偏移都会再次校验，避免把普通图片中的文本片段误判为视频。

### 3. 安全提取与播放

播放器需要独立视频时，应用按照已经验证的偏移和长度精确复制视频数据到缓存，不会把华为/荣耀防抖数据、`LIVE_` 尾标或 OPPO trailer 一并交给播放器，也不会修改原图。

- macOS 使用 AVFoundation / AVKit 播放。
- Windows 使用 LibVLCSharp 播放。

播放结束默认回到原始静态封面。如果设置了停留画面，应用会在播放结束后回到保存的时间点并暂停。

### 4. 元数据与本地索引

缩略图、EXIF 和实况识别在后台限流处理，避免同时读取大量原图。

- macOS 使用 SQLite 保存图库索引。
- Windows 使用带文件大小、修改时间和配套视频指纹的本地 JSON 索引。

文件发生变化后，旧索引会自动失效并重新识别。标签、喜欢状态和停留画面使用独立的本地状态文件保存。

## 平台实现

| 平台 | 界面与运行时 | 播放与元数据 |
| --- | --- | --- |
| macOS 13+ | SwiftUI / Swift Package Manager | AVFoundation、ImageIO、Core Location、SQLite |
| Windows 10/11 | WPF / .NET 10 | LibVLCSharp、Windows Imaging Component、Shell Thumbnail API |

两端采用相同的媒体模型和整理逻辑，并使用各平台原生控件呈现界面。停留画面编辑在 macOS 中使用胶片候选帧，在 Windows 中使用可实时预览的时间轴。

macOS 26 Tahoe 会在浮动侧栏、图库工具区、状态条和单图查看器工具条使用系统原生 Liquid Glass，并根据窗口宽度自适应排列控件；macOS 13–15 使用系统材质、高光描边和阴影作为兼容回退。照片墙与照片本身不叠加玻璃效果，以保持色彩和细节准确。

## 使用方法

1. 打开应用，选择一个用于管理照片的大目录；应用会在后台为其中的媒体建立索引。
2. 在侧边栏展开目录树并单击一个目录，右侧只展示这个目录本层的照片和视频。
3. 需要同时查看所选目录的所有下级目录时，勾选“包含所选目录的子目录”；取消后立即恢复为仅看本层。
4. 带有 `LIVE` 标记的照片可以播放动态内容，独立视频显示 `VIDEO` 标记。
5. 单击照片会将它设为当前查看项；双击或按 `Enter` 进入查看器。
6. 使用爱心加入“我喜欢”，或在查看器中添加标签。
7. 使用侧边栏筛选、顶部搜索和排序控件缩小范围。
8. 需要备份时导出当前筛选；需要整理时将单张或当前目录范围内的“我喜欢”移入废纸篓 / 回收站。
9. 连接已启用 USB 调试的安卓手机后，可将当前目录范围内的“我喜欢”同步到 `DCIM/MotionAlbum`。

目录树只列出含有受支持媒体的目录及其必要的父目录，空目录不会占用侧边栏空间。目录行右侧的数字表示该层直接包含的媒体数量；macOS 悬停目录行还会显示连同子目录的总数。

### 常用操作

| 操作 | 图库 | 查看器 |
| --- | --- | --- |
| 上下左右移动 | 方向键 / `WASD` | `←` / `→` 切换前后照片 |
| 打开照片 | 双击或 `Enter` | — |
| 返回图库 | — | `Esc` |
| 缩放 | 按钮、滑杆、Windows `Ctrl` + 滚轮 | 按钮、滚轮；macOS `⌘` / Windows `Ctrl` + `+` / `-` |
| 恢复查看器缩放 | — | macOS `⌘` / Windows `Ctrl` + `0` |
| 收起侧边栏 | macOS `⌘B` / Windows `Ctrl+B` | 顶部侧边栏按钮 |
| 调整侧边栏宽度 | 左右拖动侧边栏与图库之间的分隔条 | — |
| 打开目录 | macOS `⌘O` / Windows `Ctrl+O` | 顶部打开目录按钮 |
| 刷新目录 | Windows `Ctrl+R` | — |
| 导出当前筛选 | Windows `Ctrl+E` | — |

照片右键菜单提供查看、加入/取消喜欢、在 Finder / 文件资源管理器中显示和移入废纸篓 / 回收站等操作。

## 构建 macOS 版本

环境要求：

- macOS 13 Ventura 或更高版本
- Xcode Command Line Tools
- 可选：Android Debug Bridge，用于同步安卓手机

```bash
xcode-select --install
brew install android-platform-tools   # 可选

cd LivePhotoLookerMac
./build_app.sh
open "dist/灵动相册.app"
```

`build_app.sh` 会先运行自检，再构建 Release 应用并使用本机临时签名。产物位于：

```text
LivePhotoLookerMac/dist/灵动相册.app
```

只验证源码时可以运行：

```bash
cd LivePhotoLookerMac
swift build -c release -Xswiftc -warnings-as-errors
swift run MotionAlbum --self-test
```

生成 ZIP、可用时生成 DMG，并写出 SHA256：

```bash
cd LivePhotoLookerMac
./package_release.sh
```

当前脚本使用临时签名，没有进行 Apple Developer ID 签名和 notarization。分发给其他用户时，macOS 可能提示无法验证开发者。

## 构建 Windows 版本

环境要求：

- Windows 10/11
- [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0)
- 建议安装 Windows HEIF 图像扩展，用于显示 HEIC/HEIF 静态封面
- 可选：Android platform-tools，用于同步安卓手机

在 PowerShell 中运行：

```powershell
cd LivePhotoViewer.WPF
.\build_windows.ps1 -Runtime win-x64 -Package
```

32 位 Windows 可以使用：

```powershell
.\build_windows.ps1 -Runtime win-x86 -Package
```

脚本会运行跨平台解析自检，然后生成无需另装 .NET Runtime 的自包含目录和 ZIP：

```text
LivePhotoViewer.WPF/dist/MotionAlbum-win-x64/MotionAlbum.exe
LivePhotoViewer.WPF/dist/MotionAlbum-v<version>-win-x64.zip
LivePhotoViewer.WPF/dist/MotionAlbum-v<version>-win-x64.zip.sha256
```

Windows 11 ARM64 当前使用 `win-x64` 包和系统 x64 模拟层；项目依赖的 LibVLC Windows 包暂未提供原生 ARM64 播放库。

## 自检与样本

本地 `samples/` 用于放置不同品牌的真实测试资源，并已加入 `.gitignore`，不会提交到仓库。

Windows 解析自检也可以在 macOS 或 Linux 上运行，因为测试项目只链接跨平台解析和索引代码：

```bash
dotnet run \
  --project LivePhotoViewer.WPF.SelfTest/LivePhotoViewer.WPF.SelfTest.csproj \
  -c Release -- samples
```

当前自检覆盖：

- Android Motion Photo V1。
- Android Motion Photo V2。
- OPPO 视频长度处理。
- 华为/荣耀 JPG 与 HEIC 定位。
- Apple HEIC/JPG 与 MOV 配对。
- MP4 精确范围提取。
- 静态照片防误判。
- 图库索引恢复与文件变化后的缓存失效。

## Apple Live Photo 与微信保存的 JPG

Apple Live Photo 通常包含一张图片和一个配套 MOV：

```text
IMG_0001.HEIC
IMG_0001.MOV
```

如果通过微信“保存图片”后只得到单独 JPG，通常表示图片已经被重新编码，配套 MOV 或内嵌视频已经丢失。此时文件中没有可以解码的动态数据，应用只能把它当作静态照片。只有以下情况仍能播放：

- JPG 本身仍包含可验证的内嵌 MP4。
- 原始 HEIC/JPG 旁边仍保留配套 MOV。
- 导出或传输方式完整保留了 Live Photo 的两项资源。

## 本地数据与隐私

- 应用没有照片上传服务，原始照片和配套视频只在本机读取、缓存、复制或按用户操作移入废纸篓 / 回收站。
- macOS 的地点名称解析可能调用系统地理编码服务，但不会上传照片文件。
- adb 同步只在用户主动执行时，将所选原始资源复制到已连接设备。
- macOS 状态位于 `~/Library/Application Support/MotionAlbum/`。
- Windows 状态位于 `%APPDATA%\MotionAlbum\`，缩略图、视频和图库索引位于临时目录或 `%LOCALAPPDATA%\MotionAlbum\`。
- 自定义轮播短句可以写入对应状态目录中的 `quotes.txt`，每行格式为 `句子` 或 `句子 — 来源`。
- 外接磁盘不支持系统废纸篓 / 回收站时，应用会回退到原文件同卷的隐藏 `.MotionAlbumTrash` 安全删除区，不执行不可恢复的直接删除。

## 已知限制

- 已被聊天软件或图片编辑器重新编码为纯静态 JPG 的实况照片无法恢复动态内容。
- Windows 未安装 HEIF 图像扩展时，仍可识别 Apple 图片与 MOV 的配对，但 HEIC 静态封面可能无法显示。
- 不同手机系统版本可能调整厂商私有尾部结构；遇到未识别样本时，应保留未经编辑的原始文件用于分析。
- “我喜欢”、标签和停留画面是应用本地状态，不会写回照片元数据，也不会自动同步到另一台电脑。
- 大型图库已有后台限流和缓存，但十万级媒体仍需要进一步的分页与虚拟化优化。

## 项目结构

```text
.
├── LivePhotoLookerMac/           # macOS SwiftUI 应用、解析器与打包脚本
├── LivePhotoViewer.WPF/          # Windows WPF 应用、解析器与发布脚本
├── LivePhotoViewer.WPF.SelfTest/ # Windows/跨平台解析自检
├── legacy/                       # 早期实验代码
├── samples/                      # 本地真实样本，不提交
├── CHANGELOG.md
└── README.md
```

关键实现：

- macOS 解析器：`LivePhotoLookerMac/Sources/LivePhotoLooker/Services/LivePhotoParser.swift`
- macOS 图库状态：`LivePhotoLookerMac/Sources/LivePhotoLooker/ViewModels/PhotoLibrary.swift`
- Windows 解析器：`LivePhotoViewer.WPF/Core/LivePhotoExtractor.cs`
- Windows 主界面：`LivePhotoViewer.WPF/MainWindow.xaml` 与 `MainWindow.xaml.cs`
- Windows 自检：`LivePhotoViewer.WPF.SelfTest/Program.cs`

## 技术参考

- [Live Photo Box](https://github.com/LengxiQwQ/live-photo-box)
- [MotionTrans](https://github.com/Huakira/MotionTrans)
- [MotionPhoto2AppleLivePhoto](https://github.com/Albresky/MotionPhoto2AppleLivePhoto)
- [LimitPoint/LivePhoto](https://github.com/LimitPoint/LivePhoto)
- [live-photo-conv](https://github.com/wszqkzqk/live-photo-conv)
- [Android Developers: Android Debug Bridge](https://developer.android.com/tools/adb)

版本变更记录见 [CHANGELOG.md](CHANGELOG.md)。
