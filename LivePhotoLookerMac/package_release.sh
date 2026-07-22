#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"

APP_DISPLAY_NAME="灵动相册"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$SCRIPT_DIR/Resources/Info.plist")
ARCHIVE_NAME="MotionAlbum-v${VERSION}-macOS"
DIST_DIR="$SCRIPT_DIR/dist"
APP_PATH="$DIST_DIR/${APP_DISPLAY_NAME}.app"
RELEASE_DIR="$SCRIPT_DIR/release"
DMG_STAGING_DIR="$(mktemp -d)"

trap 'rm -rf "$DMG_STAGING_DIR"' EXIT

"$SCRIPT_DIR/build_app.sh"

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

ditto -c -k --keepParent "$APP_PATH" "$RELEASE_DIR/${ARCHIVE_NAME}.zip"

cp -R "$APP_PATH" "$DMG_STAGING_DIR/"
ln -s /Applications "$DMG_STAGING_DIR/Applications"
ARTIFACTS=("${ARCHIVE_NAME}.zip")
if hdiutil create \
    -volname "${APP_DISPLAY_NAME} ${VERSION}" \
    -srcfolder "$DMG_STAGING_DIR" \
    -ov \
    -format UDZO \
    "$RELEASE_DIR/${ARCHIVE_NAME}.dmg" 2>/dev/null; then
    ARTIFACTS=("${ARCHIVE_NAME}.dmg" "${ARTIFACTS[@]}")
else
    echo "警告：当前环境无法生成 DMG，已保留 ZIP 安装包。"
fi

(
    cd "$RELEASE_DIR"
    shasum -a 256 "${ARTIFACTS[@]}" > SHA256SUMS.txt
)

echo "Release 产物已生成："
if [[ -f "$RELEASE_DIR/${ARCHIVE_NAME}.dmg" ]]; then
    echo "$RELEASE_DIR/${ARCHIVE_NAME}.dmg"
fi
echo "$RELEASE_DIR/${ARCHIVE_NAME}.zip"
echo "$RELEASE_DIR/SHA256SUMS.txt"
