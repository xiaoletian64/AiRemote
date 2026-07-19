#!/bin/zsh
# build.sh - 编译 MiVibeBoard.app
# 用法: ./build.sh
set -e
cd "$(dirname "$0")"

APP_NAME="MiVibeBoard"
APP="build/${APP_NAME}.app"
EXEC_NAME="MiVibeBoard"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 生成版本脚本：从 git tag 推 v1.0.0 形式
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    GIT_VER=$(git describe --tags --always --dirty 2>/dev/null || echo "1.0.0")
else
    GIT_VER="1.0.0"
fi
echo "Building ${APP_NAME} ${GIT_VER}"

# Apple Silicon 优先；Intel Mac 把 target 改成 x86_64-apple-macos13.0
ARCH_TARGET="${BUILD_TARGET:-arm64-apple-macos13.0}"

swiftc -O \
  -target "$ARCH_TARGET" \
  -module-name "${EXEC_NAME}" \
  Sources/Model.swift Sources/Engine.swift Sources/UI.swift Sources/main.swift \
  -o "$APP/Contents/MacOS/${EXEC_NAME}"

# Ad-hoc 签名：本地运行；首次启动右键 → 打开
xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP"

# 生成 zip/DMG 候选
cd build
ditto -c -k --sequesterRsrc --keepParent "${APP_NAME}.app" "${APP_NAME}-${GIT_VER}.zip"
echo "✅ 已构建: ${APP}"
echo "   打开: open '${APP}'   （首次右键 → 打开）"
echo "   分发: build/${APP_NAME}-${GIT_VER}.zip"
