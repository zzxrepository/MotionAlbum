#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"

export CLANG_MODULE_CACHE_PATH="$SCRIPT_DIR/.build/clang-module-cache"
export SWIFTPM_CACHE_PATH="$SCRIPT_DIR/.build/swiftpm-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_CACHE_PATH"

swift run --disable-sandbox MotionAlbum --self-test
swift build --disable-sandbox -c release

APP_NAME="灵动相册.app"
DIST_DIR="$SCRIPT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME"

rm -rf "$APP_DIR"
find "$DIST_DIR" -maxdepth 1 -type d -name "*.app" ! -name "$APP_NAME" -exec rm -rf {} +
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$SCRIPT_DIR/.build/release/MotionAlbum" "$APP_DIR/Contents/MacOS/MotionAlbum"
cp "$SCRIPT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

ICON_SOURCE="$SCRIPT_DIR/Resources/app_icon.png"
if [[ -f "$ICON_SOURCE" ]]; then
    cp "$ICON_SOURCE" "$APP_DIR/Contents/Resources/app_icon.png"

    ICONSET_ROOT="$(mktemp -d)"
    ICONSET_DIR="$ICONSET_ROOT/app_icon.iconset"
    trap 'rm -rf "$ICONSET_ROOT"' EXIT
    mkdir -p "$ICONSET_DIR"
    sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
    sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
    sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
    sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
    sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
    sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
    sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
    sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
    sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
    sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
    if ! iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/app_icon.icns" 2>/dev/null; then
        python3 - "$ICON_SOURCE" "$APP_DIR/Contents/Resources/app_icon.icns" <<'PY'
import struct
import sys
from pathlib import Path

png = Path(sys.argv[1]).read_bytes()
chunk = b"ic10" + struct.pack(">I", len(png) + 8) + png
Path(sys.argv[2]).write_bytes(b"icns" + struct.pack(">I", len(chunk) + 8) + chunk)
PY
    fi
fi

codesign --force --deep --sign - "$APP_DIR"
echo "构建完成：$APP_DIR"
