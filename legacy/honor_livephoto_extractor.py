#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
荣耀/华为动态照片提取工具 (Honor/Huawei Live Photo Extractor)

原理：荣耀/华为手机的"动态照片"（实况照片）实际上是在 JPG 文件内部嵌入了一个
完整的 MP4 视频（H.265 + AAC）。MP4 以 `ftyp` box 开头，位于 JPG 图像数据的中间。
Windows 资源管理器 / MTP 协议只识别到 JPG 的静态部分，因此无法显示动态效果。

本工具会：
1. 在 JPG 文件中搜索 MP4 的 `ftyp` 标记
2. 从 `ftyp` box 的开头（包含 4 字节的 size 字段）提取到文件末尾
3. 导出为标准的 .mp4 视频文件，可在任何播放器中播放

依赖：Python 3.x（无第三方库依赖）
可选：ffmpeg / ffprobe（用于验证提取的视频）
"""

import os
import sys
import struct
import argparse
import subprocess
from pathlib import Path
from datetime import datetime


def find_mp4_ftyp(data: bytes) -> int:
    """
    在二进制数据中搜索 MP4 `ftyp` box 的位置。
    返回 ftyp 字符串的起始偏移量；如果未找到，返回 -1。
    """
    pos = 0
    while True:
        idx = data.find(b'ftyp', pos)
        if idx == -1:
            return -1
        # 验证：ftyp 前面 4 字节应该是 box size（big-endian）
        if idx >= 4:
            box_size = struct.unpack('>I', data[idx - 4:idx])[0]
            # ftyp box 的 size 应该在合理范围内（通常 12~40 字节）
            if 8 <= box_size <= 1024:
                # 再验证 ftyp 后面 4 字节是 major brand（可打印 ASCII）
                brand = data[idx + 4:idx + 8]
                if brand.isalnum() or all(32 <= b <= 126 for b in brand):
                    return idx
        pos = idx + 1


def extract_video_from_livephoto(src_path: str, dst_path: str = None, overwrite: bool = False) -> dict:
    """
    从单个动态照片文件中提取 MP4 视频。

    Args:
        src_path: 源动态照片路径（JPG）
        dst_path: 输出 MP4 路径（默认自动命名）
        overwrite: 是否覆盖已存在的文件

    Returns:
        dict 包含操作结果信息
    """
    result = {
        'src': src_path,
        'dst': None,
        'success': False,
        'message': '',
        'video_offset': -1,
        'video_size': 0,
        'duration_sec': None,
    }

    if not os.path.isfile(src_path):
        result['message'] = f'文件不存在: {src_path}'
        return result

    with open(src_path, 'rb') as f:
        data = f.read()

    ftyp_pos = find_mp4_ftyp(data)
    if ftyp_pos == -1:
        result['message'] = '未找到 MP4 ftyp 标记，可能不是动态照片'
        return result

    # MP4 box size 在 type 之前 4 字节
    video_offset = ftyp_pos - 4
    video_size = len(data) - video_offset

    # 自动命名输出文件
    if dst_path is None:
        src_stem = Path(src_path).stem
        src_dir = Path(src_path).parent
        # 命名规则：IMG_xxx.jpg -> VID_xxx.mp4 (与荣耀/华为图库一致)
        if src_stem.startswith('IMG_'):
            dst_name = 'VID' + src_stem[3:] + '.mp4'
        else:
            dst_name = src_stem + '.mp4'
        dst_path = str(src_dir / dst_name)

    if os.path.exists(dst_path) and not overwrite:
        result['message'] = f'目标文件已存在: {dst_path}'
        return result

    # 写入提取的视频
    with open(dst_path, 'wb') as f:
        f.write(data[video_offset:])

    result['dst'] = dst_path
    result['success'] = True
    result['video_offset'] = video_offset
    result['video_size'] = video_size
    result['message'] = f'成功提取 {video_size:,} 字节 -> {dst_path}'

    # 尝试用 ffprobe 获取时长
    try:
        ffprobe_cmd = ['ffprobe', '-v', 'error', '-show_entries', 'format=duration',
                       '-of', 'default=noprint_wrappers=1:nokey=1', dst_path]
        output = subprocess.check_output(ffprobe_cmd, stderr=subprocess.STDOUT, timeout=10)
        duration = float(output.strip())
        result['duration_sec'] = duration
    except Exception:
        pass

    return result


def batch_extract(src_dir: str, dst_dir: str = None, recursive: bool = False,
                  overwrite: bool = False, copy_non_live: bool = False) -> list:
    """
    批量提取文件夹中的动态照片。

    Args:
        src_dir: 源文件夹路径
        dst_dir: 输出文件夹路径（默认与源文件夹相同）
        recursive: 是否递归处理子文件夹
        overwrite: 是否覆盖已存在的文件
        copy_non_live: 对于非动态照片，是否复制到输出目录

    Returns:
        list[dict] 每个文件的处理结果
    """
    src_path = Path(src_dir)
    if dst_dir is None:
        dst_path = src_path
    else:
        dst_path = Path(dst_dir)
        dst_path.mkdir(parents=True, exist_ok=True)

    results = []
    pattern = '**/*.jpg' if recursive else '*.jpg'

    for jpg_file in sorted(src_path.glob(pattern)):
        # 跳过已经提取出的 _extracted.mp4 等文件所在的目录（如果混合存放）
        rel_dir = jpg_file.parent.relative_to(src_path)
        out_dir = dst_path / rel_dir
        out_dir.mkdir(parents=True, exist_ok=True)

        res = extract_video_from_livephoto(str(jpg_file), None, overwrite)
        if res['success'] and res['dst']:
            # 移动自动命名的文件到目标目录
            auto_dst = Path(res['dst'])
            if auto_dst.parent != out_dir:
                final_dst = out_dir / auto_dst.name
                if final_dst.exists() and overwrite:
                    final_dst.unlink()
                if not final_dst.exists():
                    auto_dst.rename(final_dst)
                    res['dst'] = str(final_dst)
        results.append(res)

        if not res['success'] and copy_non_live:
            # 复制非动态照片（普通 JPG）到输出目录
            import shutil
            shutil.copy2(str(jpg_file), str(out_dir / jpg_file.name))

    return results


def generate_html_viewer(image_dir: str, output_html: str = None) -> str:
    """
    生成一个 HTML 查看器，可以并排显示静态图片和播放提取出的视频。

    Args:
        image_dir: 包含 JPG 和对应 MP4 的文件夹
        output_html: 输出 HTML 文件路径

    Returns:
        生成的 HTML 文件路径
    """
    img_dir = Path(image_dir)
    if output_html is None:
        output_html = str(img_dir / 'live_photo_viewer.html')

    jpg_files = sorted(img_dir.glob('*.jpg'))

    items = []
    for jpg in jpg_files:
        mp4 = jpg.with_suffix('.mp4')
        has_video = mp4.exists()
        rel_jpg = jpg.name
        rel_mp4 = mp4.name if has_video else ''
        items.append({
            'jpg': rel_jpg,
            'mp4': rel_mp4,
            'has_video': has_video,
            'name': jpg.stem,
        })

    html_content = f'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>动态照片查看器 - {img_dir.name}</title>
<style>
    body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; margin: 0; padding: 20px; background: #f5f5f5; }}
    h1 {{ text-align: center; color: #333; }}
    .stats {{ text-align: center; margin-bottom: 20px; color: #666; }}
    .grid {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 20px; }}
    .card {{ background: #fff; border-radius: 12px; box-shadow: 0 2px 8px rgba(0,0,0,0.1); overflow: hidden; transition: transform 0.2s; }}
    .card:hover {{ transform: translateY(-4px); box-shadow: 0 4px 16px rgba(0,0,0,0.15); }}
    .media {{ position: relative; width: 100%; height: 240px; background: #000; display: flex; align-items: center; justify-content: center; overflow: hidden; }}
    .media img, .media video {{ max-width: 100%; max-height: 100%; object-fit: contain; }}
    .media video {{ display: none; position: absolute; top: 0; left: 0; width: 100%; height: 100%; }}
    .card.playing .media img {{ display: none; }}
    .card.playing .media video {{ display: block; }}
    .overlay {{ position: absolute; bottom: 8px; right: 8px; background: rgba(0,0,0,0.6); color: #fff; padding: 4px 10px; border-radius: 16px; font-size: 12px; pointer-events: none; }}
    .info {{ padding: 12px 16px; }}
    .filename {{ font-size: 14px; color: #333; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }}
    .meta {{ font-size: 12px; color: #999; margin-top: 4px; }}
    .btn {{ display: block; width: 100%; padding: 10px; border: none; background: #007aff; color: #fff; font-size: 14px; cursor: pointer; transition: background 0.2s; }}
    .btn:hover {{ background: #0051d5; }}
    .btn.playing {{ background: #ff2d55; }}
    .no-video {{ background: #e0e0e0; color: #888; display: flex; align-items: center; justify-content: center; height: 100%; }}
</style>
</head>
<body>
<h1>动态照片查看器</h1>
<div class="stats">共 {len(items)} 张照片，其中 {sum(1 for i in items if i['has_video'])} 张包含动态视频</div>
<div class="grid">
'''

    for item in items:
        btn_text = '▶ 播放实况' if item['has_video'] else '无动态视频'
        overlay = '<span class="overlay">LIVE</span>' if item['has_video'] else ''
        video_tag = f'<video src="{item["mp4"]}" preload="none" loop playsinline muted></video>' if item['has_video'] else ''
        no_video = '<div class="no-video">无动态视频</div>' if not item['has_video'] else ''

        html_content += f'''    <div class="card" id="card-{item['name']}">
        <div class="media">
            <img src="{item['jpg']}" alt="{item['name']}" loading="lazy">
            {video_tag}
            {overlay}
            {no_video}
        </div>
        <div class="info">
            <div class="filename">{item['jpg']}</div>
            <div class="meta">{'包含实况视频' if item['has_video'] else '静态照片'}</div>
        </div>
        <button class="btn" onclick="togglePlay('{item['name']}')" {'disabled' if not item['has_video'] else ''}>{btn_text}</button>
    </div>
'''

    html_content += '''</div>
<script>
function togglePlay(name) {
    const card = document.getElementById('card-' + name);
    const video = card.querySelector('video');
    const btn = card.querySelector('.btn');
    if (!video) return;
    if (card.classList.contains('playing')) {
        video.pause();
        card.classList.remove('playing');
        btn.textContent = '▶ 播放实况';
        btn.classList.remove('playing');
    } else {
        // Pause others
        document.querySelectorAll('.card.playing').forEach(c => {
            const v = c.querySelector('video');
            if (v) v.pause();
            c.classList.remove('playing');
            c.querySelector('.btn').textContent = '▶ 播放实况';
            c.querySelector('.btn').classList.remove('playing');
        });
        video.play();
        card.classList.add('playing');
        btn.textContent = '⏸ 暂停';
        btn.classList.add('playing');
    }
}
</script>
</body>
</html>
'''

    with open(output_html, 'w', encoding='utf-8') as f:
        f.write(html_content)

    return output_html


def _set_utf8_stdout():
    """Try to set stdout encoding to utf-8 on Windows to avoid garbled Chinese text."""
    import io
    try:
        if sys.platform == 'win32':
            sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
            sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8')
    except Exception:
        pass


def main():
    _set_utf8_stdout()
    parser = argparse.ArgumentParser(
        description='荣耀/华为动态照片提取工具 - 从 JPG 实况照片中提取 MP4 视频',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''
使用示例:
  # 提取单个文件
  python honor_livephoto_extractor.py -i "IMG_20260617_192759.jpg"

  # 批量提取文件夹中的所有动态照片
  python honor_livephoto_extractor.py -b "E:\\手机照片\\Camera" -o "E:\\提取的视频"

  # 批量提取并生成 HTML 查看器
  python honor_livephoto_extractor.py -b "E:\\手机照片\\Camera" --html
        '''
    )
    parser.add_argument('-i', '--input', help='单个动态照片 JPG 文件路径')
    parser.add_argument('-o', '--output', help='输出 MP4 文件路径（单文件模式）或输出目录（批量模式）')
    parser.add_argument('-b', '--batch', help='批量处理：指定源文件夹路径')
    parser.add_argument('-r', '--recursive', action='store_true', help='递归处理子文件夹')
    parser.add_argument('--overwrite', action='store_true', help='覆盖已存在的文件')
    parser.add_argument('--html', action='store_true', help='批量处理后生成 HTML 查看器')
    parser.add_argument('--copy-static', action='store_true', help='批量时同时复制非动态照片')

    args = parser.parse_args()

    if args.input:
        res = extract_video_from_livephoto(args.input, args.output, args.overwrite)
        status_mark = '[OK]' if res['success'] else '[FAIL]'
        print(f"{status_mark} {res['message']}")
        if res['duration_sec']:
            print(f"   视频时长: {res['duration_sec']:.2f} 秒")
    elif args.batch:
        print(f"[INFO] 开始批量处理: {args.batch}")
        results = batch_extract(args.batch, args.output, args.recursive, args.overwrite, args.copy_static)
        success_count = sum(1 for r in results if r['success'])
        fail_count = len(results) - success_count
        print(f"\n[RESULT] 处理完成: {success_count} 成功, {fail_count} 失败 (共 {len(results)} 个文件)")
        for r in results:
            if not r['success']:
                print(f"   [WARN] {r['src']}: {r['message']}")

        if args.html and (args.output or args.batch):
            html_dir = args.output or args.batch
            html_path = generate_html_viewer(html_dir)
            print(f"\n[HTML] 查看器已生成: {html_path}")
    else:
        parser.print_help()


if __name__ == '__main__':
    main()
