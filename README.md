# AiRemote · 小米蓝牙语音遥控器 → 电脑桥接器

> 把小米蓝牙语音遥控器变成电脑的无线键盘 + 麦克风。
>
> 当前交付目标是纯软件 macOS 客户端；ESP32 目录仅保留历史原型，不属于本版本功能或发布范围。

---

## 🎯 双产品线

### 线 A：Mac App（MVP，纯软件）

**[`mac-app/`](mac-app/)** — 3 分钟安装，即刻使用

- 把遥控器语音直接接到 Mac 系统麦克风（BlackHole 虚拟声卡）
- 按键可任意映射成键盘快捷键（自然支持 Whisper + 飞书/Zoom）
- 无需硬件，不需要烧录
- 仅支持小米蓝牙语音遥控器（含 RC003 / 2 Pro 等）

### 历史原型：ESP32 硬件桥（未交付）

**[`esp32-bridge/`](esp32-bridge/)** — 任意电脑用，纯蓝牙 HID

- 不构建、不发布、不保证可用
- 仅保留作协议和架构参考

---

## 决策对比

| 维度 | Mac App | ESP32 Bridge |
|---|---|---|
| 按键映射自定义 | ✅ 录制目标键 | ⚠️ 待 WebUI |
| 跨平台 | ❌ macOS only | ✅ 任意电脑 |
| 安装门槛 | 低（脚本一条命令） | 中（烙铁+烧录） |
| 语音延迟 | 极低 (BlackHole 直通) | 低 (USB 高速) |
| 用户体验 | 需要软件常驻 | 即插即用 |
| 开机自启 | ✅ LaunchAgent | 无需 |

---

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
├── docs/
│   └── PROTOCOL.md             ATVV 协议详解（待补）
├── mac-app/                    线 A：Mac 软件
│   ├── Sources/                Engine + Model + UI + main
│   ├── Resources/              Info.plist + AppIcon.icns
│   ├── build.sh · install.sh   编译/安装
│   └── README.md
└── esp32-bridge/               线 B：硬件桥
    ├── main/                   主程序 + FSM
    ├── components/
    │   ├── ble_central/         BLE Central + ATVV
    │   ├── adpcm/               IMA ADPCM 解码器
    │   ├── voice_dsp/           语音增强 (HP+EQ+AGC+软限幅)
    │   └── usb_hid/             TinyUSB HID + UAC
    └── sdkconfig.defaults
```

---

## ✨ 致谢

- [mi-remote-mapper](https://github.com/81199000/mi-remote-mapper) — Mac 端 ATVV 完整实现，本项目 mac-app 的基础
- [open-voice-bridge](https://github.com/nijez/open-voice-bridge) — RC003 macOS 适配参考，工业级架构
- [mi-ao](https://github.com/fanxeon/mi-ao) — 早期小米遥控器逆向
- [m5stickc-aibao](https://github.com/lizhao86/m5stickc-aibao) — ESP32 双模 BT 实现参考
- [esp-usb-ble-hid](https://github.com/finger563/esp-usb-ble-hid) — ESP32 BLE Central → USB HID 架构参考

## License

MIT
