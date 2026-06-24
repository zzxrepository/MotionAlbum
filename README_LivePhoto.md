# 荣耀/华为实况照片提取方案

## 问题现象

- 电脑通过数据线（MTP）连接荣耀/华为手机后，在 Windows 资源管理器中只能看到 `.jpg` 静态照片
- 实况照片（动态照片）的动态视频部分无法被 Windows 识别和读取

## 根本原因

荣耀/华为手机的动态照片采用了一种**"隐藏式嵌入"**存储方案：

1. 拍摄实况照片时，手机会同时保存：
   - **静态封面图**：标准的 JPEG 图像数据（到 `FF D9` EOI 标记结束）
   - **动态视频**：完整的 MP4 文件（H.265 HEVC + AAC 音频），以 `ftyp` box 开头
2. 这个 MP4 **不是**放在 JPG 尾部，而是**嵌入在 JPG 图像数据的中间位置**
3. Windows / MTP 协议只识别到 JPEG 的静态图像部分，因此完全看不到视频

## 解决方案

本项目提供了两套方案：

| 方案 | 适用场景 | 优点 |
|------|---------|------|
| **方案 A：Python 提取工具** | 已经把照片复制到电脑 | 无需安装额外软件，双击即用 |
| **方案 B：ADB 一键提取** | 想直接从手机提取 | 绕过 MTP，保留最原始的文件 |

---

## 方案 A：Python 提取工具（推荐）

### 环境要求

- Python 3.x（已自带，无需额外库）
- 可选：ffmpeg / ffprobe（用于显示视频时长信息）

### 单文件提取

```bash
# 基础用法：自动命名输出
python honor_livephoto_extractor.py -i "IMG_20260617_140640.jpg"

# 指定输出路径
python honor_livephoto_extractor.py -i "IMG_20260617_140640.jpg" -o "output.mp4"
```

### 批量提取

```bash
# 批量提取整个文件夹
python honor_livephoto_extractor.py -b "E:\手机照片\Camera"

# 提取到指定输出目录
python honor_livephoto_extractor.py -b "E:\手机照片\Camera" -o "E:\提取的视频"

# 递归处理子文件夹
python honor_livephoto_extractor.py -b "E:\手机照片" -r

# 提取后自动生成 HTML 查看器
python honor_livephoto_extractor.py -b "E:\手机照片\Camera" --html
```

### 生成的 HTML 查看器

执行 `--html` 后，会在输出目录生成 `live_photo_viewer.html`：

- 用浏览器打开即可看到所有照片的缩略图
- 点击 **"▶ 播放实况"** 按钮，即可在原地播放动态视频
- 支持点击暂停，自动停止其他正在播放的视频
- 无动态视频的照片会显示为灰色静态图

---

## 方案 B：ADB 一键提取

如果你希望**直接从手机**提取，绕过 Windows MTP 的限制，可以使用 ADB 方式。

### 前置条件

1. **手机开启 USB 调试**：
   - 设置 → 关于手机 → 连续点击"版本号"7 次，开启开发者模式
   - 设置 → 系统和更新 → 开发人员选项 → USB 调试 → 开启
2. **电脑安装 Android Platform Tools**（包含 `adb.exe`）：
   - 下载地址：https://developer.android.com/studio/releases/platform-tools
   - 解压后放到任意目录，并添加到系统 PATH

### 使用方法

右键点击 `adb_helper.ps1`，选择"使用 PowerShell 运行"：

```powershell
# 一键拉取并提取
.\adb_helper.ps1
```

脚本会自动完成：
1. 搜索并检测 `adb.exe`
2. 检测连接的手机
3. 从手机 `/sdcard/DCIM/Camera` 拉取所有 JPG 到本地 `from_phone/` 文件夹
4. 自动调用 Python 提取工具批量提取视频
5. 生成 HTML 查看器

---

## 工具文件说明

| 文件 | 说明 |
|------|------|
| `honor_livephoto_extractor.py` | 核心提取工具（Python） |
| `adb_helper.ps1` | ADB 一键拉取脚本（PowerShell） |
| `live-photo-conv/` | 参考项目源码（已拉取到本地，了解解析原理用） |
| `samples/` | 样本测试目录（从手机复制的测试文件） |

---

## 技术细节

### 文件结构解析

荣耀动态照片的实际二进制结构如下（以 `IMG_20260617_140640.jpg` 为例）：

```
[0] ~ [5,540,911]      JPEG 图像数据（包含嵌入的 MP4 前缀）
[5,540,912]            ftyp box (24 bytes)  <-- MP4 真正开始的位置
[5,540,936]            free box (3192 bytes)
[5,544,128]            mdat box (视频 + 音频数据)
[14,562,396]           mdat 结束
[14,562,396] ~ [14,566,310]   moov box (轨道信息)
[14,566,310] ~ [EOF]          uuid box (荣耀 EIS 防抖矩阵元数据)
```

### 提取原理

1. 在文件中全局搜索 `ftyp` 字符串
2. 向前回退 4 字节（MP4 box size 字段）
3. 从该位置截取到文件末尾，即为完整的 MP4
4. ffprobe 验证：H.265 (HEVC) 视频 + AAC 音频，约 2~3 秒时长

### 为什么 Windows 看不到？

- Windows 资源管理器通过 MTP 访问手机时，依赖文件扩展名和 MIME 类型判断文件类型
- 由于文件扩展名是 `.jpg`，系统只调用 JPEG 解码器，读取到 `FF D9` (EOI) 就停止了
- 根本不会去扫描文件内部的 `ftyp` 标记
- 因此动态视频被完全"隐身"

---

## 提取效果

经实测，提取出的 MP4 文件：

- **编码**：H.265 / HEVC (Main Profile)
- **分辨率**：1728 × 1296
- **帧率**：30 fps
- **音频**：AAC-LC，48000Hz，立体声
- **时长**：约 2~3 秒
- **兼容性**：可在 VLC、PotPlayer、Windows Media Player 等任何播放器正常播放

---

## 常见问题

**Q：提取后视频无法播放？**
A：请确保使用的是 `honor_livephoto_extractor.py` 提取出的 MP4。如果直接复制 JPG 文件并把扩展名改成 `.mp4` 是无法播放的，因为还需要正确截取从 `ftyp` 开始的数据。

**Q：所有 JPG 都能提取出视频吗？**
A：不是。只有拍摄时开启了"动态照片"模式的才会嵌入视频。普通照片提取时会提示"未找到 MP4 ftyp 标记"。

**Q：HEIC 文件也能提取吗？**
A：本工具主要针对荣耀/华为的 `.jpg` 实况照片。如果是 iPhone 迁移过来的 `.heic` Live Photo，建议使用 `live-photo-conv` 项目处理（需 MSYS2 环境编译）。

**Q：这个方案会破坏原文件吗？**
A：不会。提取过程是只读的，原 JPG 文件不会被修改。
