#!/bin/zsh
# build.sh - 编译 MiVibeBoard.app 并打包 DMG
# 用法: ./build.sh [--dmg] [--universal]
set -e
cd "$(dirname "$0")"

APP_NAME="MiVibeBoard"
APP="build/${APP_NAME}.app"
EXEC_NAME="MiVibeBoard"

# 解析参数
DO_DMG=1
UNIVERSAL=0
for arg in "$@"; do
    case "$arg" in
        --no-dmg)   DO_DMG=0 ;;
        --dmg)      DO_DMG=1 ;;
        --universal) UNIVERSAL=1 ;;
        --help|-h)
            cat <<EOF
用法: $0 [--dmg] [--no-dmg] [--universal]
  --dmg       生成 DMG 安装包（默认）
  --no-dmg    不打 DMG，仅产出 .app
  --universal 同时构建 arm64 + x86_64，生成通用二进制（推荐分发用）
EOF
            exit 0 ;;
    esac
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# BlackHole 是系统音频驱动，刻意不嵌入 App：由用户通过 install.sh 或 Homebrew 安装。

# 版本号：git tag → v1.0.0；否则 1.0.0
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    GIT_VER=$(git describe --tags --always --dirty 2>/dev/null || echo "1.0.0")
else
    GIT_VER="1.0.0"
fi
# 去掉前缀 v
VER="${GIT_VER#v}"
echo "Building ${APP_NAME} ${VER}"

# 编译。Swift 没有 "universal" target；通用包必须分别编译再 lipo。
if [ "$UNIVERSAL" = "1" ]; then
    echo "→ 通用二进制（arm64 + x86_64）"
    swiftc -O -target arm64-apple-macos13.0 -module-name "${EXEC_NAME}" \
      Sources/Model.swift Sources/VoiceGlobeMapper.swift Sources/Engine.swift Sources/UI.swift Sources/main.swift \
      -o "$APP/Contents/MacOS/${EXEC_NAME}.arm64"
    swiftc -O -target x86_64-apple-macos13.0 -module-name "${EXEC_NAME}" \
      Sources/Model.swift Sources/VoiceGlobeMapper.swift Sources/Engine.swift Sources/UI.swift Sources/main.swift \
      -o "$APP/Contents/MacOS/${EXEC_NAME}.x86_64"
    lipo -create "$APP/Contents/MacOS/${EXEC_NAME}.arm64" "$APP/Contents/MacOS/${EXEC_NAME}.x86_64" \
      -output "$APP/Contents/MacOS/${EXEC_NAME}"
    rm "$APP/Contents/MacOS/${EXEC_NAME}.arm64" "$APP/Contents/MacOS/${EXEC_NAME}.x86_64"
else
    ARCH=$(uname -m)
    echo "→ 单架构：${ARCH}"
    swiftc -O -target "${ARCH}-apple-macos13.0" -module-name "${EXEC_NAME}" \
      Sources/Model.swift Sources/VoiceGlobeMapper.swift Sources/Engine.swift Sources/UI.swift Sources/main.swift \
      -o "$APP/Contents/MacOS/${EXEC_NAME}"
fi

# The remote itself supplies the native Globe/Fn event through a device-specific
# HID mapping. Direct public distribution requires a Developer ID Application
# certificate; an App Store Apple Distribution certificate is intentionally not
# used here because it cannot be notarized for website/GitHub distribution.
xattr -cr "$APP" 2>/dev/null || true
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)
fi
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)
fi
if [[ "$SIGN_IDENTITY" == Developer\ ID\ Application:* ]]; then
    echo "→ 使用 Developer ID（可用于后续公证）: $SIGN_IDENTITY"
    codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
elif [ -n "$SIGN_IDENTITY" ]; then
    echo "→ 使用 Apple Development 本机构建签名: $SIGN_IDENTITY"
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
else
    echo "→ 未找到 Developer ID / Apple Development 证书，回退 ad-hoc 签名"
    codesign --force --deep --sign - "$APP"
fi

# 也生成 zip（兼容性备用）
cd build
ditto -c -k --sequesterRsrc --keepParent "${APP_NAME}.app" "${APP_NAME}-${VER}.zip"
cd ..

echo "✅ 已构建: $APP"
echo "   打开: open '$APP'   （首次右键 → 打开）"
echo "   分发 zip: build/${APP_NAME}-${VER}.zip"

# ----- DMG 打包 -----
if [ "$DO_DMG" = "1" ]; then
    DMG="build/${APP_NAME}-${VER}.dmg"
    echo "→ 生成 DMG 安装包: $DMG"

    # 临时目录起草稿
    STAGING="build/dmg-staging"
    rm -rf "$STAGING" "$DMG"
    mkdir -p "$STAGING"
    cp -R "$APP" "$STAGING/"
    # 加一个 /Applications 快捷方式，拖拽即装
    ln -s /Applications "$STAGING/Applications"
    # 简易 README
    cat > "$STAGING/README-安装说明.txt" <<'EOF'
小米 Vibecoding 键盘 - 安装说明
================================

1. 把 MiVibeBoard 拖到右侧的 Applications 文件夹
2. 进入「应用程序」，按住 Control 键单击 MiVibeBoard，选择「打开」
3. 系统可能会拦：点「仍要打开」（因为是社区签名 App）
4. 首次启动时按 App 提示授权：
   - 辅助功能 (Accessibility)
   - 输入监控 (Input Monitoring)
5. 如要使用「按住语音键 → 系统麦克风输入」：
   - 安装 BlackHole 2ch: brew install blackhole-2ch
   - 重启电脑
   - 系统设置 → 声音 → 输入 → 选 BlackHole 2ch
6. 长按遥控器【主页】+【菜单】5 秒进入配对模式，App 自动连接
7. 按遥控器按键 / 长按语音键开始用

卸载：直接拖到废纸篓即可。

License: MIT
EOF

    # 用 hdiutil 生成 DMG（UDZO 压缩）
    hdiutil create -volname "${APP_NAME} ${VER}" \
        -srcfolder "$STAGING" \
        -fs HFS+ \
        -format UDZO \
        -imagekey zlib-level=9 \
        "$DMG" 2>&1 | tail -3

    # A Developer ID-signed app inside the DMG is ready for notarization. The
    # DMG itself is stapled only after notarytool accepts the upload.

    rm -rf "$STAGING"
    echo "✅ DMG: $DMG"
    echo "   双击挂载: open '$DMG'"
fi
