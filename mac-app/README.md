# MiVibeBoard for macOS

一个独立的 macOS 客户端：连接小米蓝牙语音遥控器，映射按键，并把 ATVV 语音流转发成系统可用的麦克风输入。

本应用不做语音识别、翻译或云端上传。选择 BlackHole 作为 macOS 输入设备后，系统听写、输入法或任意支持麦克风的应用自行处理语音。

## 使用

1. 安装 BlackHole：`brew install --cask blackhole-2ch`。
2. 在“系统设置 → 声音 → 输入”选择 **BlackHole 2ch**。
3. 打开“**小米语音遥控器**”；首次系统请求时允许蓝牙、辅助功能、输入监控。
4. 长按遥控器“主页 + 菜单”约 5 秒进入配对；应用会自动连接。
5. 在“按键映射”页按需录制快捷键或选择鼠标/系统动作。

## 默认 Coding 映射

| 遥控器 | 默认动作 |
| --- | --- |
| 方向键 | 光标方向 |
| OK | Return |
| Back | 单击 Delete；按住后渐进加速连续删除 |
| Home | `⌘P`（VS Code/Cursor 快速打开） |
| Menu | 短按 Esc；长按 `⌃C` 中断终端/AI 任务 |
| Power 短按 | 截全屏后锁屏 |
| Power 长按 1.5 秒 | 关机确认框 |
| 语音键 | 固定为原生 `Fn` / Globe，同时转发音频到 BlackHole |

Power 的长按永远会弹出确认框，不会直接关机。

## 构建与安装

```bash
cd mac-app
./build.sh --no-dmg
open build/MiVibeBoard.app
```

分发通用二进制：

```bash
./build.sh --universal
```

本机构建优先使用 Apple Development 签名。面向 GitHub/官网的正式分发包必须使用 **Developer ID Application** 签名、Hardened Runtime 和 Apple 公证；Apple Distribution 证书仅用于 Mac App Store 提交，不能替代 Developer ID。
