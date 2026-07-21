# AiRemote · 小米蓝牙语音遥控器 → 电脑桥接器

> 把小米蓝牙语音遥控器变成电脑的无线键盘 + 麦克风。
>
> 当前交付目标是纯软件 macOS 客户端。

---

## 🎯 当前产品：Mac App

**[`mac-app/`](mac-app/)** — 3 分钟安装，即刻使用

- 把遥控器语音直接接到 Mac 系统麦克风（BlackHole 虚拟声卡）
- 按键可任意映射成键盘快捷键（自然支持 Whisper + 飞书/Zoom）
- 无需硬件，不需要烧录
- 仅支持小米蓝牙语音遥控器（含 RC003 / 2 Pro 等）

## 决策对比

## 协议

小米蓝牙语音遥控器（RC003 / 2 Pro）使用 Android TV Voice-over-BLE (ATVV) 协议：

```
Service  AB5E0001-5A21-4F05-BC7D-AF01F617B664
  TX (Mac→遥控器) AB5E0002  → GET_CAPS = [0x0A,0x00,0x06,0x00,0x01]
  RX (遥控器→Mac) AB5E0003  → ADPCM 帧流（16kHz mono, 低 nibble 在前）
  CTL            AB5E0004  → 0x04=语音键按下 0x00=松开
```

按键走标准 Bluetooth HID（VendorID 0x2717）。

---

## 目录结构

```
AiRemote/
├── README.md                   本文档
└── mac-app/                    Mac 软件
│   ├── Sources/                Engine + Model + UI + main
│   ├── Resources/              Info.plist + AppIcon.icns
│   ├── build.sh · install.sh   编译/安装
│   └── README.md
```

---

## ✨ 致谢

- [mi-remote-mapper](https://github.com/81199000/mi-remote-mapper) — Mac 端 ATVV 完整实现，本项目 mac-app 的基础
- [open-voice-bridge](https://github.com/nijez/open-voice-bridge) — RC003 macOS 适配参考，工业级架构
- [mi-ao](https://github.com/fanxeon/mi-ao) — 早期小米遥控器逆向

## License

MIT
