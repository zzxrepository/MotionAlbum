"""
Analyze JPG files for Motion Photo / Live Photo data.
Checks for:
1. Google Motion Photo: MP4 data appended after JPEG EOI (FF D9)
2. Samsung Motion Photo: Similar appended MP4
3. XMP metadata indicating motion photo
"""
import os
import struct
import json

SAMPLES_DIR = r"e:\DevWorkspace\Tests\TraeTutorialsProjectCode\14_Project_Cursor_Test\samples"

def find_jpeg_eoi(data):
    """Find the last JPEG End-Of-Image marker (FF D9)."""
    # Start from beginning to handle embedded thumbnails, but we want the LAST one
    pos = 0
    last_eoi = -1
    while True:
        idx = data.find(b'\xff\xd9', pos)
        if idx == -1:
            break
        last_eoi = idx
        pos = idx + 2
    return last_eoi

def find_mp4_box(data, start=0):
    """Look for 'ftyp' or 'moov' MP4 box signatures."""
    signatures = [b'ftyp', b'moov', b'mdat', b'wide']
    found = []
    for sig in signatures:
        pos = start
        while True:
            idx = data.find(sig, pos)
            if idx == -1:
                break
            # MP4 box: 4-byte size (big-endian), then 4-byte type
            if idx >= 4:
                box_size = struct.unpack('>I', data[idx-4:idx])[0]
                if 8 <= box_size <= len(data):
                    found.append((sig.decode(), idx-4, box_size))
            pos = idx + 1
    return found

def analyze_file(filepath):
    result = {
        'filename': os.path.basename(filepath),
        'size_kb': round(os.path.getsize(filepath) / 1024, 1),
        'jpeg_eoi_pos': None,
        'trailing_bytes': 0,
        'has_mp4_after_eoi': False,
        'mp4_offset': None,
        'xmp_motion_photo': False,
        'xmp_details': None,
        'likely_motion_photo': False,
    }

    with open(filepath, 'rb') as f:
        data = f.read()

    # 1. Find JPEG EOI
    eoi = find_jpeg_eoi(data)
    result['jpeg_eoi_pos'] = eoi
    if eoi != -1:
        result['trailing_bytes'] = len(data) - (eoi + 2)

    # 2. Search for MP4 boxes in trailing data
    if result['trailing_bytes'] > 100:
        mp4_boxes = find_mp4_box(data, eoi + 2 if eoi != -1 else 0)
        if mp4_boxes:
            result['has_mp4_after_eoi'] = True
            # Get the earliest box offset
            earliest = min(mp4_boxes, key=lambda x: x[1])
            result['mp4_offset'] = earliest[1]

    # 3. Search XMP metadata for motion photo indicators
    text = data.decode('latin-1', errors='ignore')
    xmp_markers = [
        'MotionPhoto',
        'MicroVideo',
        'LivePhoto',
        'GCamera:MotionPhoto',
        'Samsung:MotionPhoto',
        'HONOR:MotionPhoto',
        'Huawei:MotionPhoto',
    ]
    for marker in xmp_markers:
        if marker in text:
            result['xmp_motion_photo'] = True
            # Extract surrounding context
            idx = text.find(marker)
            start = max(0, idx - 100)
            end = min(len(text), idx + 200)
            result['xmp_details'] = text[start:end].replace('\x00', ' ')
            break

    # 4. Heuristic: if trailing bytes > 100KB and contains MP4, likely motion photo
    if result['has_mp4_after_eoi'] and result['trailing_bytes'] > 50 * 1024:
        result['likely_motion_photo'] = True

    return result

def extract_mp4(src_path, dst_path, offset):
    """Extract MP4 data from offset to end of file."""
    with open(src_path, 'rb') as f:
        f.seek(offset)
        mp4_data = f.read()
    with open(dst_path, 'wb') as f:
        f.write(mp4_data)
    print(f"  Extracted {len(mp4_data)} bytes -> {dst_path}")

if __name__ == '__main__':
    files = [f for f in os.listdir(SAMPLES_DIR) if f.lower().endswith('.jpg')]
    print("=" * 60)
    print("Motion Photo Analysis Report")
    print("=" * 60)

    for fname in sorted(files):
        fpath = os.path.join(SAMPLES_DIR, fname)
        r = analyze_file(fpath)

        print(f"\n📄 {r['filename']} ({r['size_kb']} KB)")
        print(f"   JPEG EOI at: {r['jpeg_eoi_pos']} (0x{r['jpeg_eoi_pos']:X})")
        print(f"   Trailing bytes after EOI: {r['trailing_bytes']:,}")
        print(f"   Has MP4 after EOI: {r['has_mp4_after_eoi']}")
        if r['mp4_offset']:
            print(f"   MP4 offset: {r['mp4_offset']} (0x{r['mp4_offset']:X})")
        print(f"   XMP Motion Photo marker: {r['xmp_motion_photo']}")
        print(f"   Likely Motion Photo: {r['likely_motion_photo']}")

        if r['xmp_details']:
            print(f"   XMP snippet: {r['xmp_details'][:120]}...")

        # Auto-extract if looks like motion photo
        if r['likely_motion_photo'] and r['mp4_offset']:
            mp4_name = fname.replace('.jpg', '_extracted.mp4')
            mp4_path = os.path.join(SAMPLES_DIR, mp4_name)
            extract_mp4(fpath, mp4_path, r['mp4_offset'])

    print("\n" + "=" * 60)
    print("Analysis complete.")
