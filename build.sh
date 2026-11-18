#!/bin/bash
# build.sh — 把 Quadro.swift 编译并打包成可双击运行的 Quadro.app
# 用法: 在终端中进入本文件所在目录,执行  bash build.sh

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Quadro"
BUILD_DIR="build"
BUNDLE="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$BUNDLE/Contents/MacOS"
RES_DIR="$BUNDLE/Contents/Resources"

# 检查编译工具
if ! command -v swiftc >/dev/null 2>&1; then
  echo "错误: 未找到 swiftc。请先安装 Xcode 命令行工具:"
  echo "  xcode-select --install"
  exit 1
fi

rm -rf "$BUNDLE"
mkdir -p "$MACOS_DIR" "$RES_DIR"

# 嵌入应用图标(若存在 Quadro.iconset)
if [ -d "Quadro.iconset" ] && command -v iconutil >/dev/null 2>&1; then
  iconutil -c icns Quadro.iconset -o "$RES_DIR/AppIcon.icns" 2>/dev/null || \
    echo "提示: 图标转换失败,将使用系统默认图标"
fi

# SDK 选择:
# Swift 6.4 的 macOS 27 SDK 把 @State 实现成了宏,而 Command Line Tools
# 不带 SwiftUIMacros 插件,直接编译会报 "plugin for module 'SwiftUIMacros' not found"。
# 如果机器上还留着 macOS 26.x SDK,优先用它;装了完整 Xcode 的机器不受影响。
SDK="${QUADRO_SDK:-}"
if [ -z "$SDK" ]; then
  for cand in 26.5 26; do
    candidate="/Library/Developer/CommandLineTools/SDKs/MacOSX${cand}.sdk"
    if [ -d "$candidate" ]; then SDK="$candidate"; break; fi
  done
fi
if [ -z "$SDK" ]; then
  SDK="$(xcrun --show-sdk-path)"
fi
TARGET="${QUADRO_TARGET:-arm64-apple-macos12.0}"
echo "正在编译 $APP_NAME (SDK: $SDK, target: $TARGET) ..."
swiftc -sdk "$SDK" -target "$TARGET" -O -parse-as-library \
  -o "$MACOS_DIR/$APP_NAME" \
  Quadro.swift \
  -framework SwiftUI -framework AppKit

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Quadro</string>
    <key>CFBundleDisplayName</key>
    <string>Quadro</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.quadro</string>
    <key>CFBundleExecutable</key>
    <string>Quadro</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

# 代码签名(Apple Silicon 上未签名的二进制无法运行,必须签)
# 优先使用稳定的自签名证书,避免每次重编译签名身份变化,导致 macOS 反复要求目录权限
if command -v codesign >/dev/null 2>&1; then
  SIGN_ID=""
  CERT_NAME="Quadro Developer"

  if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    SIGN_ID="$CERT_NAME"
  elif command -v openssl >/dev/null 2>&1; then
    CERT_TMP="$(mktemp -d)"
    if openssl req -new -newkey rsa:2048 -nodes -x509 -days 3650 \
         -subj "/CN=$CERT_NAME/O=Quadro/OU=Developer" \
         -keyout "$CERT_TMP/key.pem" -out "$CERT_TMP/cert.pem" \
         -addext "keyUsage=digitalSignature" \
         -addext "extendedKeyUsage=codeSigning" 2>/dev/null \
       && openssl pkcs12 -export -inkey "$CERT_TMP/key.pem" -in "$CERT_TMP/cert.pem" \
            -out "$CERT_TMP/cert.p12" -passout pass:quadro 2>/dev/null \
       && security import "$CERT_TMP/cert.p12" -P quadro -T /usr/bin/codesign 2>/dev/null; then
      if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
        SIGN_ID="$CERT_NAME"
      fi
    fi
    rm -rf "$CERT_TMP"
  fi

  if [ -n "$SIGN_ID" ]; then
    codesign --force --deep --sign "$SIGN_ID" "$BUNDLE" >/dev/null 2>&1 \
      || { echo "提示: 证书签名失败,改用临时签名"; codesign --force --deep --sign - "$BUNDLE" >/dev/null 2>&1; }
  else
    codesign --force --deep --sign - "$BUNDLE" >/dev/null 2>&1
  fi
fi

echo ""
echo "构建完成: $BUNDLE"
echo "打开方式(二选一):"
echo "  1) 在 Finder 中双击 $APP_NAME.app"
echo "  2) 终端执行: open \"$BUNDLE\""
