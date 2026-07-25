# 灵动相册（MotionAlbum）

灵动相册是一款面向 macOS 的实况照片查看与筛选工具。它可以读取从手机导出的原始照片文件，识别其中的动态视频资源，让你在电脑上预览实况、筛选照片、添加标签，并把精选原图同步回安卓手机，继续以“实况照片”的方式在微信等手机应用里发送。

这个项目最初是为了解决一个很具体的问题：手机里的实况照片导到电脑后看起来只是普通 JPG，系统图片查看器无法播放动态部分；筛选后再发给别人时，也常常变成静态图片。灵动相册的目标不是改造原图，而是安全地识别、查看、整理和回传原始文件。

## 功能特性

- 读取荣耀 / 华为导出的原始 JPG，不拆包、不改写原文件。
- 支持苹果 Live Photo 常见的 `IMG_0001.HEIC + IMG_0001.MOV` 同名配对结构。
- 自动识别 JPG 尾部内嵌的 MP4 实况视频，或照片旁边的同名 MOV/MP4，并在缩略图上标记 LIVE；目录里的独立 MOV/MP4/M4V 也会作为普通视频显示和播放。
- 类似手机相册的照片墙浏览，支持通过滑杆或触控板捏合调整缩略图大小；小缩略图模式只显示必要角标，大缩略图模式会展开文件名、大小和标签。
- 支持按拍摄时间新到旧、拍摄时间旧到新、修改时间、文件名排序；按时间分组浏览时会根据缩略图大小自动调整粒度：小缩略图按月聚合，大缩略图按天展示。图库支持一键回到顶部，查看器返回图库时会定位到刚刚查看的照片。
- 搜索支持照片名、标签、地点名称、目录名、路径、设备型号等字段；如果照片内含 GPS，会在需要时后台解析成大致地点名称再参与搜索。
- 实况 / 视频 / 全部 / 精选等筛选。
- 双击打开大图后在主窗口内查看，不额外弹出照片窗口；支持自动播放实况和普通视频、上一张 / 下一张、切换静态图与动态内容。
- 查看器支持放大、缩小、适合窗口和触控板捏合缩放，只影响预览显示，不改写原文件。
- 实况播放结束后回到封面图；也可以像手机相册一样进入封面帧编辑，在胶片缩略条中左右滑动选择停留帧。
- 给照片添加标签，并按标签快速筛选。
- 支持单张或精选批量移入 macOS 废纸篓；如果外接硬盘不支持系统废纸篓，会改为移入同目录下隐藏的 `.MotionAlbumTrash` 安全删除区，方便恢复；如果照片有同名 MOV/MP4 实况视频，会和原图一起移动。
- 解析并展示照片里的 EXIF 元信息，例如设备型号、拍摄时间、像素尺寸；如果照片保存了 GPS，灵动相册会尽量反解析成大致地点名称，解析不到时不显示坐标。
- 打开历史目录，目录移动或失效时会提示，避免直接崩溃。
- 顶部工具栏支持轮播短句；左侧底部展示作者署名。公开默认短句以公版诗词和自拟句为主，也可以在本机添加自己的语句。
- 导出当前筛选结果，保留原始照片文件；如果存在苹果同名 MOV/MP4，也会一起导出。
- 通过 adb 把精选照片复制到手机 `DCIM/MotionAlbum`，便于在手机微信里继续按实况照片发送。
- 针对大量图片目录做了流式扫描、缩略图解码限流、后台实况识别、后台 EXIF 索引、SQLite 持久化图库索引和磁盘缩略图缓存；同一大目录再次打开时会先显示上次索引结果，再后台核对变更，尽量避免一次性读入大文件造成卡顿或崩溃。

## 支持平台

| 平台 | 状态 | 说明 |
| --- | --- | --- |
| macOS | 当前主线 | 原生 SwiftUI 应用，优先维护 |
| Windows | 预览保留 | WPF 版本仍不完善，后续再继续开发 |

> 目前推荐在 macOS 上使用。Windows 目录会保留在仓库里，但暂时不要把它当作正式发行版。

## 快速开始

### 环境要求

- macOS 13 Ventura 或更高版本
- Xcode Command Line Tools
- 如需同步到手机：Android Debug Bridge（adb）

安装 Xcode Command Line Tools：

```bash
xcode-select --install
```

安装 adb：

```bash
brew install android-platform-tools
```

### 构建 macOS 应用

```bash
cd LivePhotoLookerMac
./build_app.sh
open "dist/灵动相册.app"
```

`build_app.sh` 会先运行自检，再构建 Release 版本、生成 app 图标并做本地签名。生成的应用位于：

```text
LivePhotoLookerMac/dist/灵动相册.app
```

如果你只是想验证源码是否能通过编译：

```bash
cd LivePhotoLookerMac
swift build -c release -Xswiftc -warnings-as-errors
swift run MotionAlbum --self-test
```

`samples/` 是本地样本目录，默认不会进入 Git 仓库。存在样本时，自检会校验荣耀实况样本；没有样本时，会跳过样本解析，只运行基础稳定性测试。

## 发布版本与安装包

当前建议版本号：`v0.1.0`。

这个版本已经具备核心功能，但仍属于第一个公开预览版，所以不建议直接叫 `1.0.0`。后续可以按这个节奏编号：

- `0.1.1`：只修 bug，不加明显新功能。
- `0.2.0`：增加新功能，例如更完整的设备同步、批量性能优化。
- `1.0.0`：功能边界稳定，普通用户安装和使用流程比较可靠。

生成 GitHub Release 可上传的安装包：

```bash
cd LivePhotoLookerMac
./package_release.sh
```

脚本会生成：

```text
LivePhotoLookerMac/release/MotionAlbum-v0.1.0-macOS.dmg
LivePhotoLookerMac/release/MotionAlbum-v0.1.0-macOS.zip
LivePhotoLookerMac/release/SHA256SUMS.txt
```

如果当前 macOS 环境无法调用 `hdiutil` 创建磁盘镜像，脚本会保留 `.zip` 安装包和 `SHA256SUMS.txt`，不会中断整个发布流程。

发布到 GitHub 时，建议创建 tag `v0.1.0`，然后在 GitHub Release 中上传上面的 `.dmg`、`.zip` 和 `SHA256SUMS.txt`。

> 当前脚本使用本机临时签名，尚未做 Apple Developer ID 签名和 notarization。公开给陌生用户下载时，macOS 可能会提示“无法验证开发者”。如果要做更正式的公开发行，后续建议补上 Developer ID 签名和 notarization 流程。

## 使用说明

1. 在首页点击“打开文件夹”，选择从手机导出的照片或视频目录。默认会包含子文件夹，适合外接硬盘或旅行照片库这类多级目录。
2. 等待后台识别完成。实况照片会显示 LIVE 标记，普通视频会显示 VIDEO 标记。
3. 双击照片或视频进入主窗口内的查看界面，实况和普通视频会自动播放，也可以切回静态封面；左右方向键可切换上一张 / 下一张。
4. 对喜欢的照片勾选“精选”，或添加自定义标签。
5. 使用左侧筛选、标签视图或顶部搜索框缩小范围；搜索框可以输入文件名、标签、地点、目录名或设备型号。
6. 不想保留的照片可以右键卡片或在查看器中点击“移入废纸篓”；批量清理时先勾选精选，再点击“移入废纸篓精选”。外接硬盘没有废纸篓时，文件会进入同目录隐藏的 `.MotionAlbumTrash` 安全删除区。
7. 需要备份时，点击“导出当前筛选”。
8. 需要发微信实况照片时，先连接安卓手机并开启 USB 调试，再点击“同步精选到安卓手机”。灵动相册会把原始照片文件复制到手机 `DCIM/MotionAlbum`，之后请在手机微信里从相册选择发送。

### 关于封面帧

默认情况下，灵动相册显示的是手机导出的静态照片本身，也就是原始封面图；它不是随机帧，也不是固定取视频 1.5 秒的位置。进入“编辑封面帧”后，你可以从实况视频里选一个时间点作为灵动相册里的停留帧。这个设置只保存在本机，不会改写原始 JPG/HEIC/MOV 文件。

### 关于苹果 Live Photo

苹果 Live Photo 通常由两部分组成：

```text
IMG_0001.HEIC
IMG_0001.MOV
```

这两个文件需要放在同一个目录下，并保持同名。灵动相册会把它们识别成同一张实况照片。只导出成单独 `.jpg` 的文件通常已经丢失动态视频，无法再凭空恢复成实况。

### 关于轮播短句

灵动相册顶部工具栏会轮播一些短句。默认内置短句主要使用公版诗词和项目自拟句，适合公开发布。

如果你想在自己电脑上添加私人喜欢的句子，可以创建这个文件：

```text
~/Library/Application Support/MotionAlbum/quotes.txt
```

每行一句即可，也可以使用下面的格式带上来源：

```text
句子 — 来源
```

本地 `quotes.txt` 不会进入 Git 仓库，也不会上传。若添加歌词，请确认只用于个人本机使用，公开发布版本不建议内置完整受版权保护歌词。

## 隐私与安全

- 灵动相册不会上传照片，也没有云端服务。
- 原始照片和配套视频只会被读取、复制，不会被改写。
- 删除操作默认移入 macOS 废纸篓，不做不可恢复的硬删除；移动成功后会清理本机保存的精选、标签和封面帧记录。
- 标签、精选状态、历史目录保存在本机应用支持目录。
- 临时提取的视频缓存只用于本机播放，可随系统临时文件清理。
- `samples/` 默认被 `.gitignore` 忽略，避免把个人照片误传到公开仓库。

## 目录结构

```text
.
├── LivePhotoLookerMac/      # 当前 macOS 主版本
├── LivePhotoViewer.WPF/     # Windows WPF 预览版，暂未正式维护
├── legacy/                  # 早期脚本和实验代码，仅作参考
├── samples/                 # 本地测试照片，默认忽略，不提交
├── README.md
└── .gitignore
```

## 大照片库性能路线

灵动相册当前已经把重操作拆成了几层：先扫描基础文件列表并显示界面，缩略图按需解码并落盘缓存，实况识别和 EXIF/GPS 元信息在后台低并发补齐；同一目录会写入 SQLite 图库索引，下次打开时先用索引快速展示，再后台核对目录变更。

如果要长期支撑数十万张、1T 级照片库，后续还需要继续演进到更完整的图库索引架构：

- 继续扩展 SQLite 索引，把标签、地点反解析结果、封面帧和搜索字段统一进入数据库，减少多份本地状态文件。
- 缩略图分层缓存已经接入第一版，后续可按小图、中图、查看器预览图做更细的生成、淘汰和预取策略。
- 目录扫描做增量更新：通过文件路径、大小、修改时间和 inode/file resource identifier 判断新增、移动、删除。
- 搜索从当前内存过滤逐步升级为数据库查询，并为文件名、标签、地点、目录建立更完整的索引。
- 图库视图继续演进为分页 / 虚拟化数据源，避免 10 万级以上照片一次性生成过多 SwiftUI 视图状态。
- 后台任务统一进入可取消队列，切目录、快速滚动、删除、导出时优先保证界面响应。

## 开发路线

- 完善 macOS 版本的批量性能测试和真实设备同步测试。
- 增加更明确的 GitHub Release 打包流程。
- 继续完善 SQLite 持久化图库索引，推进分页加载、数据库搜索和更精细的增量更新。
- 继续打磨 Windows WPF 版本。
- 研究更多品牌和更多“动态照片 / 实况照片”文件结构。

## 参考资料

- [GitHub Docs: About READMEs](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes)
- [GitHub Docs: Managing releases in a repository](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository)
- [Semantic Versioning](https://semver.org/)
- [Android Developers: Android Debug Bridge](https://developer.android.com/tools/adb)
- [Apple Developer Documentation: Core Data Fetch Requests](https://developer.apple.com/documentation/coredata/nsfetchrequest)
- [digiKam Documentation: Database Settings](https://docs.digikam.org/en/setup_application/database_settings.html)
- [PhotoPrism User Guide: Index](https://docs.photoprism.app/user-guide/library/index/)
- [PhotoPrism User Guide: Storage](https://docs.photoprism.app/user-guide/library/originals/)
- [荣耀支持：实况照片相关说明](https://www.honor.com/cn/support/content/zh-cn15868878/)
- [wszqkzqk/live-photo-conv](https://github.com/wszqkzqk/live-photo-conv)
