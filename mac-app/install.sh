#!/bin/zsh
# install.sh - 一键安装小米语音遥控器
# 用法: ./install.sh
set -e
cd "$(dirname "$0")"

APP_NAME="小米超级键盘"

echo "── 小米超级键盘 · 安装向导 ──"
echo ""

# 1) Homebrew
if ! command -v brew >/dev/null 2>&1; then
  echo "❌ 缺少 Homebrew，请先安装：https://brew.sh"
  exit 1
fi

# 2) BlackHole 虚拟声卡（让遥控器语音作为系统麦克风）
if [ -d "/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver" ]; then
  echo "✓ BlackHole 2ch 已安装"
else
  echo "→ 安装 BlackHole 2ch（需要 sudo 密码）..."
  brew install --cask blackhole-2ch
  echo ""
  echo "→ 正在刷新 CoreAudio（不重启 Mac）..."
  sudo /usr/bin/killall coreaudiod
  sleep 2
fi

# 3) 编译工具
if ! command -v swiftc >/dev/null 2>&1; then
  echo "→ 缺少 Xcode 命令行工具，正在触发系统弹窗..."
  xcode-select --install || true
  echo "请在弹窗里点安装，完成后再次运行本脚本。"
  exit 1
fi
echo "✓ swiftc 可用"

# 4) 编译
echo "→ 编译 ${APP_NAME}.app..."
./build.sh

# 5) 部署
DEST="/Applications/${APP_NAME}.app"
echo "→ 部署到 ${DEST}..."
rm -rf "$DEST"
cp -R "build/${APP_NAME}.app" "$DEST"
xattr -cr "$DEST" 2>/dev/null || true

cat <<EOF

✅ 安装完成！

下一步：
  1. 系统蓝牙 → 配对连接「小米蓝牙语音遥控器」
  2. 打开 /Applications/${APP_NAME}.app
     菜单栏会出现 🎤 图标
  3. 首次系统请求时允许蓝牙、辅助功能、输入监控
  4. App 会自动将 "BlackHole 2ch" 设为系统输入
     即可让任意 App（如飞书/Zoom/Whisper/输入法）使用遥控器麦克风
  5. 按住遥控器语音键说话 → 系统级语音输入

EOF

# 6) 启动 App
read -q "REPLY?现在启动 App 吗？(y/N) "
echo ""
if [[ "$REPLY" =~ ^[Yy]$ ]]; then
  open "$DEST"
fi
