#!/bin/zsh
# build.sh - 编译 MiVibeBoard.app 并打包 DMG
# 用法: ./build.sh [--dmg] [--universal]
set -e
cd "$(dirname "$0")"

APP_NAME="小米超级键盘"
APP="build/${APP_NAME}.app"
EXEC_NAME="MiKeyboard"

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
# BlackHole 驱动不内置（预编译包 License 不允许第三方重分发）。
# App 在首次使用时从 Existential Audio 官方下载并用 sha256 校验后安装。

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
      Sources/Model.swift Sources/VoiceGlobeMapper.swift Sources/RemoteInputSafety.swift Sources/Engine.swift Sources/UI.swift Sources/main.swift \
      -o "$APP/Contents/MacOS/${EXEC_NAME}.arm64"
    swiftc -O -target x86_64-apple-macos13.0 -module-name "${EXEC_NAME}" \
      Sources/Model.swift Sources/VoiceGlobeMapper.swift Sources/RemoteInputSafety.swift Sources/Engine.swift Sources/UI.swift Sources/main.swift \
      -o "$APP/Contents/MacOS/${EXEC_NAME}.x86_64"
    lipo -create "$APP/Contents/MacOS/${EXEC_NAME}.arm64" "$APP/Contents/MacOS/${EXEC_NAME}.x86_64" \
      -output "$APP/Contents/MacOS/${EXEC_NAME}"
    rm "$APP/Contents/MacOS/${EXEC_NAME}.arm64" "$APP/Contents/MacOS/${EXEC_NAME}.x86_64"
else
    ARCH=$(uname -m)
    echo "→ 单架构：${ARCH}"
    swiftc -O -target "${ARCH}-apple-macos13.0" -module-name "${EXEC_NAME}" \
      Sources/Model.swift Sources/VoiceGlobeMapper.swift Sources/RemoteInputSafety.swift Sources/Engine.swift Sources/UI.swift Sources/main.swift \
      -o "$APP/Contents/MacOS/${EXEC_NAME}"
fi

# The remote itself supplies the native Globe/Fn event through a device-specific
# HID mapping. Direct public distribution requires a Developer ID Application
# certificate. Until one is installed, use the existing Apple Distribution
# identity consistently for local builds so macOS keeps one TCC identity; this
# fallback is not a substitute for Developer ID notarization.
xattr -cr "$APP" 2>/dev/null || true
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)
fi
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Distribution:.*\)"/\1/p' | head -1)
fi
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)
fi
# 兜底：任一可用本地代码签名证书（如 MenuBarToolkit Dev 等自签证书）。
# 用它签名后 App 身份稳定（cdhash 固定），TCC 授权一次永久有效；ad-hoc 则每次重建都变。
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(.*\)"$/\1/p' | head -1)
fi
ENTITLEMENTS="Resources/entitlements.plist"
if [[ "$SIGN_IDENTITY" == Developer\ ID\ Application:* ]]; then
    echo "→ 使用 Developer ID（可用于后续公证）: $SIGN_IDENTITY"
    codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP"
elif [ -n "$SIGN_IDENTITY" ]; then
    echo "→ 使用稳定本机签名（身份固定，授权一次永久有效）: $SIGN_IDENTITY"
    codesign --force --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP"
else
    echo "→ 未找到任何签名证书，回退 ad-hoc 签名（每次重建身份会变，授权可能失效）"
    codesign --force --entitlements "$ENTITLEMENTS" --sign - "$APP"
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
小米超级键盘 - 安装说明
======================

把小米/联想蓝牙语音遥控器变成 Mac 的无线键盘 + 麦克风。

【安装】
1. 把「小米超级键盘」拖到右侧的 Applications 文件夹
2. 进入「应用程序」，【右键】→「打开」（首次直接双击会被 macOS 拦）
3. 弹窗点「打开」

【授权 - 必做，否则按键/锁屏不生效】
打开 App 后，主界面顶部会出现橙色「一键授权」按钮，点它，
然后在「系统设置 → 隐私与安全性」里把「小米超级键盘」勾上：
  - 辅助功能 (Accessibility)        ← 按键映射、锁屏必需
  - 输入监控 (Input Monitoring)     ← 读取遥控器按键必需
  - 蓝牙 (Bluetooth)                ← 连接遥控器必需
勾完【退出 App 再重新打开】一次，让权限生效。

【语音转麦克风（可选）】
如要把遥控器语音当 Mac 麦克风（用于听写/输入法/会议）：
打开 App → 设置 → 「语音输入」→ 点「一键安装语音驱动」按钮
→ App 自动从官方下载 BlackHole 驱动并校验 → 系统弹出密码框，输入管理员密码
→ 安装完成后【重启 Mac】即可。
（无需手动开终端或装 Homebrew）

【配对遥控器】
长按遥控器【主页】+【菜单】5 秒，指示灯快闪即进入配对模式，
App 会自动发现并连接。多台遥控器时在主界面「遥控器」区点选当前要用的。

【语音键两种模式】
在「按键控制」页可切换语音键映射：
  - 地球/Fn：系统听写原语，微信输入法等可识别
  - 左 Control：作为修饰键，配合其它键发 Ctrl 组合

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
