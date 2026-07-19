# AiRemote · 小米蓝牙语音遥控器 → 电脑桥接器

> 把小米蓝牙语音遥控器变成电脑的无线键盘 + 麦克风。
>
> 两条产品线：纯软件（Mac）/ 硬件桥（ESP32，跨平台）。

---

## 🎯 双产品线

### 线 A：Mac App（MVP，纯软件）

**[`mac-app/`](mac-app/)** — 3 分钟安装，即刻使用

- 把遥控器语音直接接到 Mac 系统麦克风（BlackHole 虚拟声卡）
- 按键可任意映射成键盘快捷键（自然支持 Whisper + 飞书/Zoom）
- 无需硬件，不需要烧录

### 线 B：ESP32 硬件桥（V2，跨平台、低延迟）

**[`esp32-bridge/`](esp32-bridge/)** — 任意电脑用，纯蓝牙 HID

- ESP32-S3 USB 复合设备：HID Keyboard + UAC Audio
- 直接被任何 PC 识别为「键盘 + 麦克风」
- 内置 ADPCM 解码 + 语音增强 DSP

---

## 决策对比

| 有 | Mac App | ESP32 Bridge |
|---|---|---|
| 按键映射自定义 | ✅ 录制目标键 | ⚠️ 待 WebUI |
| 跨平台 | ❌ macOS only | ✅ 任意电脑 |
| 安装门槛 | 低（脚本一条命令） | 中（烙铁+烧录） |
| 语音延迟 | 极低 (BlackHole 直通) | 低 (USB 高速) |
| 用户体验 | 需要软件常驻 | 即插即用 |
| 开机自启 | ✅ LaunchAgent | 无需 |

---

## 协议

两款共用同一套 BLE ATVV 协议，详见 [`docs/PROTOCOL.md`](docs/PROTOCOL.md)：

```
Service  AB5E0001-5A21-4F05-BC7D-AF01F617B664
  TX (ES→遥控) AB5E0002  → GET_CAPS = [0x0A,0x00,0x06,0x00,0x01]
  RX (遥控→ES) AB5E0003  → ADPCM 帧流（16kHz mono, 低 nibble 在前）
  CTL          AB5E0004  → 0x04=语音键按下 0x00=松开
```

---

## 目录结构

```
AiRemote/
├── README.md                   本文档
├── docs/
│   ├── PRD.md                  完整产品需求
│   └── PROTOCOL.md             ATVV 协议详解
├── mac-app/                    线 A：Mac 软件
└── esp32-bridge/               线 B：硬件桥
    ├── main/                   主程序 + FSM
    ├── components/
    │   ├── ble_central/        BLE Central + ATVV
    │   ├── adpcm/              IMA ADPCM 解码器
    │   ├── voice_dsp/          语音增强 (HP+EQ+AGC+软限幅)
    │   ├── usb_hid/            TinyUSB 复合 HID + UAC
    │   └── hfp_mic/            (待) 经典蓝牙 HFP 麦克风
    └── sdkconfig.defaults
```

---

## ✨ 致谢

- [mi-remote-mapper](https://github.com/81199000/mi-remote-mapper) — Mac 端 ATVV 完整实现，本项目 mac-app 的基础
- [mi-ao](https://github.com/fanxeon/mi-ao) — 早期小米遥控器逆向
- [m5stickc-aibao](https://github.com/lizhao86/m5stickc-aibao) — ESP32 双模 BT (HID + HFP) 实现参考
- [esp-usb-ble-hid](https://github.com/finger563/esp-usb-ble-hid) — ESP32 BLE Central → USB HID 架构参考

## License

MIT
