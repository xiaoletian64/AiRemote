# 小米 Vibecoding 键盘 (MiVibeBoard)

> 把小米蓝牙语音遥控器变成 Mac 的无线键盘 + 麦克风。
>
> 按住语音键说话 → 按键映射 → 系统麦克风。全部无线。

---

## 3 分钟上手

### 安装

**1. 装虚拟声卡（语音当麦克风用）**
```bash
brew install blackhole-2ch
# ⚠️ 装完重启电脑
```

**2. 启动 App**
```bash
open /Applications/MiVibeBoard.app
```
首次需要右键 → 打开（因为是 ad-hoc 签名）。

**3. 授权三个权限**
麦克风图标出现在菜单栏 → 点开设置：
- 蓝牙
- 辅助功能（合成按键必需）
- 输入监控（拦截按键必需，否则会双发）

**4. 配对遥控器**
系统设置 → 蓝牙 → 按住遥控器 Menu+Home 5秒 → 配对连接

**5. 选麦克风**
系统设置 → 声音 → 输入 → 选 "BlackHole 2ch"
任意 App（飞书/微信/Zoom/Whisper）会自动使用遥控器麦克风

### 使用

| 操作 | 效果 |
|------|------|
| 方向键 | 光标上下左右 |
| OK | 回车 |
| Back | Esc |
| Home | Win+D / 显示桌面 |
| **语音键按住说话** | → 系统麦克风输入 |
| 设置里改按键映射 | 录制目标键即可 |

---

## 开发

```bash
git clone <repo-url>
cd AiRemote/mac-app/
./build.sh         # 编译
./install.sh       # 一键安装（包括 BlackHole + 编译 + 部署）
```

## 结构

```
mac-app/
├── Sources/   Engine.swift (ATVV+HID+语音+DSP+按键吞拦截)
│             Model.swift  (按键映射表+配置持久化)
│             UI.swift     (SwiftUI 设置面板+状态)
│             main.swift   (AppDelegate+菜单栏)
├── Resources/ Info.plist + AppIcon.icns
├── build.sh     编译
└── install.sh   一键安装
```

## 工作原理

```
[小米蓝牙语音遥控器]
       ↓ BLE
[MiVibeBoard]
  ├─ ATVV Service → ADPCM 语音流解码 → BlackHole 虚拟声卡
  └─ HID Keyboard → 按键拦截 → 重新映射 → CGEvent 合成
```

协议详情见 `esp32-bridge/` 中的 ESP32 实现（同源码。

## 许可证

MIT

---

*Made with vibecoding ⚡*
