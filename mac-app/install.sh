#!/bin/zsh
# install.sh - 一键安装小米 Vibecoding 键盘
# 用法: ./install.sh
set -e
cd "$(dirname "$0")"

APP_NAME="MiVibeBoard"

echo "── 小米 Vibecoding 键盘 · 安装向导 ──"
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
  echo "⚠️  BlackHole 是内核驱动，安装后【必须重启电脑】才生效。"
  echo "请重启后再执行本脚本继续。"
  
  read -q "REPLY?现在要立即重启吗？(y/N) "
  echo ""
  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    sudo reboot
    exit 0
  fi
  echo "→ 你选择了稍后重启。请重启后回到此目录再次运行 ./install.sh"
  exit 0
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
  2. 右键 /Applications/${APP_NAME}.app → 打开（首次需要）
     菜单栏会出现 🎤 图标
  3. 点图标 → 设置 → 给三个权限：
        • 蓝牙
        • 辅助功能（合成按键必需）
        • 输入监控（拦截按键必需）
  4. 在系统设置 → 声音 → 输入 → 选 "BlackHole 2ch"
     即可让任意 App（如飞书/Zoom/Whisper/输入法）使用遥控器麦克风
  5. 按住遥控器语音键说话 → 系统级语音输入

EOF

# 6) 启动 App
read -q "REPLY?现在启动 App 吗？(y/N) "
echo ""
if [[ "$REPLY" =~ ^[Yy]$ ]]; then
  open "$DEST"
fi
