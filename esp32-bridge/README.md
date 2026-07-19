# Remote Bridge · 小米蓝牙语音遥控器 → PC/Mac 桥接器

把小米蓝牙语音遥控器变成你 PC 的无线键盘 + 麦克风。

---

## 两条路线

### 🖥️ 路线 A：Mac App（MVP，即刻可用）

现存项目 [`mi-remote-mapper`](https://github.com/81199000/mi-remote-mapper) 已在 macOS 上完美跑通，我们把它编译打包好了。

#### 安装（首次）

```bash
# 1. 装 BlackHole 虚拟声卡（语音当麦克风用）
brew install blackhole-2ch
#    ⚠️ 装完重启电脑

# 2. 启动 App
open /Applications/MiRemote\ Mapper.app
#    首次需要右键 → 打开

# 3. 菜单栏出现 🎤 图标 → 点开设置
#    给三个权限：蓝牙 / 辅助功能 / 输入监控
```

#### 使用

| 操作 | 效果 |
|------|------|
| 方向 / OK / Back | → 键盘方向、回车、Esc |
| 语音键按住说话 | → 灌入 BlackHole 虚拟声卡（任何 App 可选为麦克风输入） |
| 设置里改按键映射 | → 遥控器上任意键可映射为任意键盘快捷键 |

---

### ⚡ 路线 B：ESP32-S3 硬件桥（V2，跨平台、低延迟）

当你想不带 Mac 环境在其他电脑上使用，或者想要更低的语音延迟时，用这个。

```
[小米遥控器] --BLE(ATVV+HID)--> [ESP32-S3] --USB--> [PC/任意电脑]
                              ↕ ADPCM 解码 + DSP 增强
```

#### 项目结构

```
remote_bridge/
├── CMakeLists.txt               # ESP-IDF v5.4, target esp32s3
├── sdkconfig.defaults           # Bluedroid GATTC + TinyUSB
├── partitions.csv
├── main/
│   ├── main.c                   # 入口
│   ├── app_events.h/.c          # 事件队列
│   └── app_fsm.h/.c             # 状态机
├── components/
│   ├── ble_central/             # BLE Central GATTC
│   │   ├── ble_central.c        # 扫描配对 + HID + ATVV 全通路
│   ├── usb_hid/                 # TinyUSB 复合 HID
│   │   ├── usb_hid.c            # Keyboard + Consumer + UAC
│   ├── adpcm/                   # IMA ADPCM 解码器
│   │   ├── adpcm.c              # 16kHz mono, 低 nibble 在前
│   ├── voice_dsp/               # 语音增强 DSP
│       ├── voice_dsp.c          # 高通+EQ+噪声门+AGC+软限幅
└── docs/
    └── PRD.md                   # 完整产品设计文档
```

#### 构建

```bash
cd remote_bridge
source ~/Developer/tools/esp-idf-v5.4/export.sh
idf.py set-target esp32s3
idf.py build flash monitor
```

#### 待实现

- [ ] USB UAC 音频上行（当前 HAL 待接线）
- [ ] BLE 配对状态机完善（LED + BOOT 键反馈）
- [ ] WebUI 配置页（按键映射）
- [ ] OTA 升级

---

## 协议细节（供后续开发者参考）

### ATVV (Android TV Voice v1.0)

| 元素 | 值 |
|---|---|
| Service UUID | `AB5E0001-5A21-4F05-BC7D-AF01F617B664` |
| TX Char | `AB5E0002`（ESP32 → 遥控器写命令） |
| RX Char | `AB5E0003`（遥控器 → ESP32 音频流 notify） |
| CTL Char | `AB5E0004`（遥控器 → ESP32 语音键状态 notify, 0x04=按下 / 0x00=松开） |
| GET_CAPS | `[0x0A, 0x00, 0x06, 0x00, 0x01]` 写到 TX |
| 音频编码 | IMA ADPCM, 16kHz mono, 低 nibble 在前 |

### HID 按键用法（Keyboard Page 0x07）

| 遥控器按键 | Usage ID |
|---|---|
| 方向上 ↑ | 0x52 |
| 方向下 ↓ | 0x51 |
| 方向左 ← | 0x50 |
| 方向右 → | 0x4F |
| 确认 OK | 0x28 |
| 返回 Back | 0xF1 |
| 主页 Home | 0x4A |
| 语音键 | 0x3E（F5，HID + ATVV CTL 双通道） |
| 菜单 Menu | 0x65 |
| TV | 0x35 |
| 电源 | 0x66 |
| 音量 + | 0x80 |
| 音量 - | 0x81 |

---

## 致谢

- [mi-remote-mapper](https://github.com/81199000/mi-remote-mapper) — macOS 端完整 ATVV 实现，本项目的协议蓝本
- [mi-ao](https://github.com/fanxeon/mi-ao) — 小米遥控器 2Pro 早期逆向
- [esp-usb-ble-hid](https://github.com/finger563/esp-usb-ble-hid) — ESP32 侧 BLE Central → USB HID 架构参考

## License

MIT
