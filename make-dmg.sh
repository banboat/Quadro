#!/bin/bash
# make-dmg.sh — 一条命令: 编译 Quadro.app 并打包成可双击安装的 Quadro-1.0.dmg
# 用法: 在终端中进入本文件所在目录,执行  bash make-dmg.sh
#
# 依赖: build.sh、Quadro.swift(需与本脚本在同一目录)
# 说明: 首次运行可能弹出「终端想要控制 Finder」的授权框,点允许即可;
#       即使拒绝也不会失败,只是 DMG 里的图标位置不做美化。

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Quadro"
BUILD_DIR="build"
BUNDLE="$BUILD_DIR/$APP_NAME.app"
DMG_FINAL="Quadro-1.0.dmg"
TMP_DMG="$BUILD_DIR/$APP_NAME-tmp.dmg"
VOL_NAME="$APP_NAME"

# 1. 构建 .app(内部完成编译 + ad-hoc 签名)
echo "==> 步骤 1/4: 构建 $APP_NAME.app"
if [ ! -f "build.sh" ]; then
  echo "错误: 未找到 build.sh,请把它和本脚本放在同一目录。"
  exit 1
fi
bash build.sh

# 2. 清理旧产物
rm -rf "$TMP_DMG" "$DMG_FINAL"

# 3. 创建可写 DMG 并挂载
echo "==> 步骤 2/4: 创建并挂载 DMG"
hdiutil create -volname "$VOL_NAME" -ov -fs HFS+ -size 200m "$TMP_DMG" >/dev/null

MOUNT_POINT=$(hdiutil attach "$TMP_DMG" -nobrowse -readwrite | grep -o '/Volumes/.*' | head -1)
if [ -z "$MOUNT_POINT" ]; then
  echo "错误: 挂载 DMG 失败。"
  exit 1
fi

# 4. 放入应用和 Applications 快捷方式
echo "==> 步骤 3/4: 放入应用并美化布局"
cp -R "$BUNDLE" "$MOUNT_POINT/"
ln -s /Applications "$MOUNT_POINT/Applications"

# 5. 用 AppleScript 设置图标布局(容错,失败也不影响生成)
osascript <<EOF >/dev/null 2>&1 || true
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {400, 100, 900, 520}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 96
    set position of item "$APP_NAME.app" of container window to {140, 160}
    set position of item "Applications" of container window to {360, 160}
    update without registering applications
    close
  end tell
end tell
EOF

hdiutil detach "$MOUNT_POINT" >/dev/null

# 6. 压缩为只读 DMG
echo "==> 步骤 4/4: 压缩生成 $DMG_FINAL"
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_FINAL" >/dev/null
rm -f "$TMP_DMG"

echo ""
echo "完成: $(pwd)/$DMG_FINAL"
echo "双击打开 DMG 后,把 Quadro 拖到 Applications 即完成安装。"
