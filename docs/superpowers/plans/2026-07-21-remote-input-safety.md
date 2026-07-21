# 遥控器输入安全与圆盘滚动 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 防止小米蓝牙遥控器 2 Pro 静置误触与遗留修饰键，并把经实机校准的圆盘转动映射为默认快速页面滚动。

**Architecture:** Mac 端将纯 HID 报告解析与设备筛选分离，使稳定圆盘帧才能进入滚轮合成；ESP32 端维持唯一的 USB 键盘状态，并在 BLE 边界强制释放。两端日志以可关联时间戳记录原始事件和判定结果。

**Tech Stack:** Swift 5/AppKit/IOKit/CoreGraphics；ESP-IDF 5.4、C、TinyUSB、FreeRTOS。

---

## 文件结构

- `mac-app/Sources/RemoteInputSafety.swift`：纯 Swift 的 HID 设备资格、单键脉冲与圆盘稳定帧解析；不依赖 UI，便于测试。
- `mac-app/Sources/Engine.swift`：接入解析结果、限制 HID 枚举、发送滚轮事件、写入诊断日志。
- `mac-app/Tests/RemoteInputSafetyTests.swift`：运行在 macOS 的纯逻辑回归测试。
- `esp32-bridge/components/usb_hid/include/usb_hid.h`：公开全键释放 API。
- `esp32-bridge/components/usb_hid/usb_hid.c`：全键释放、状态清理和主机空报告。
- `esp32-bridge/components/ble_central/ble_central.c`：断连/解析状态复位与释放调用。
- `esp32-bridge/main/app_events.c`：记录非阻塞队列满并避免静默丢失状态。

### Task 1: Mac 输入安全逻辑（TDD）

**Files:**
- Create: `mac-app/Tests/RemoteInputSafetyTests.swift`
- Create: `mac-app/Sources/RemoteInputSafety.swift`

- [ ] **Step 1: 写失败测试**

覆盖：内建键盘不符合遥控器资格；单键短脉冲被拒绝；三个不同按键 150ms 内被拒绝；连续稳定 `0x03` 圆盘帧输出同方向快速滚动；孤立或方向翻转帧不输出。

- [ ] **Step 2: 运行失败测试**

Run: `swiftc mac-app/Tests/RemoteInputSafetyTests.swift -o /tmp/remote-input-safety-tests && /tmp/remote-input-safety-tests`

Expected: FAIL，因为 `RemoteInputSafety` 尚不存在。

- [ ] **Step 3: 最小实现**

实现无 AppKit 副作用的设备过滤、按键门控和圆盘校准/解析器；输入为字节及单调时间，输出为 `ignore`、`key` 或有界 `scroll(lines:)`。

- [ ] **Step 4: 运行通过测试**

Run: `swiftc mac-app/Sources/RemoteInputSafety.swift mac-app/Tests/RemoteInputSafetyTests.swift -o /tmp/remote-input-safety-tests && /tmp/remote-input-safety-tests`

Expected: PASS。

### Task 2: Mac 应用接入与可追踪日志

**Files:**
- Modify: `mac-app/Sources/Engine.swift:245-310,1214-1435,1700-1740`
- Modify: `mac-app/build.sh:39-43`

- [ ] **Step 1: 写失败的集成编译检查**

新增测试/构建调用，要求 `Engine` 使用新安全逻辑，且构建脚本包含 `RemoteInputSafety.swift`。

- [ ] **Step 2: 运行并确认失败**

Run: `cd mac-app && ./build.sh --no-dmg`

Expected: FAIL，直至新源文件被纳入构建。

- [ ] **Step 3: 最小接入**

只注册真实遥控器；对常规键、圆盘和修饰键都写 ISO 时间戳日志；仅稳定圆盘帧调用 `postScroll`，并使用安全解析器提供的方向与有界步长。

- [ ] **Step 4: 构建并检查产物**

Run: `cd mac-app && ./build.sh --no-dmg && codesign --verify --deep --strict build/小米超级键盘.app`

Expected: 构建及签名验证通过。

### Task 3: ESP32 全键释放（TDD）

**Files:**
- Create: `esp32-bridge/components/usb_hid/tests/test_usb_hid_release.c`
- Modify: `esp32-bridge/components/usb_hid/include/usb_hid.h:15-20`
- Modify: `esp32-bridge/components/usb_hid/usb_hid.c:84-203`

- [ ] **Step 1: 写失败测试**

通过 TinyUSB 报告桩记录：按下左 GUI 与普通键后调用 `usb_hid_release_all()`，最后发送键盘空报告和 Consumer 空报告，内部状态归零。

- [ ] **Step 2: 运行失败测试**

Run: `cd esp32-bridge && idf.py build`

Expected: FAIL，因为释放 API 和测试入口尚不存在。

- [ ] **Step 3: 最小实现**

新增 `usb_hid_release_all()`，清空 `s_kb_state`/`s_consumer_state` 并发出空报告；所有输出先检查挂载状态，但状态总被清零。

- [ ] **Step 4: 构建通过**

Run: `cd esp32-bridge && idf.py build`

Expected: build 成功。

### Task 4: BLE 生命周期和队列保护

**Files:**
- Modify: `esp32-bridge/components/ble_central/ble_central.c:147-210,506-522`
- Modify: `esp32-bridge/main/app_events.c:19-38`

- [ ] **Step 1: 写失败测试**

断连路径必须调用 `usb_hid_release_all()`；事件队列满时日志可见且不会把 `prev_mod`/按键状态留在按下。

- [ ] **Step 2: 运行失败检查**

Run: `cd esp32-bridge && idf.py build`

Expected: 在断连释放 API 未接入前失败或测试断言失败。

- [ ] **Step 3: 最小实现**

将 HID 解析状态移到可清理作用域；断连时发布空报告后复位输入状态。队列投递失败记录 page、usage、down/up 并触发安全释放。

- [ ] **Step 4: 构建通过**

Run: `cd esp32-bridge && idf.py build`

Expected: build 成功。

### Task 5: 真实 2 Pro 回归

**Files:**
- Modify: `mac-app/Sources/Engine.swift`（仅发现日志缺项时）

- [ ] **Step 1: 构建并启动 Mac 应用**

Run: `cd mac-app && ./build.sh --no-dmg && open build/小米超级键盘.app`

- [ ] **Step 2: 采样与验证**

实际执行：静置 30 秒；方向键；圆盘顺逆各三圈；Back 短触与长按；左/右 Command + V；BLE 断连/重连。

- [ ] **Step 3: 检查日志**

Run: `tail -n 250 "$HOME/Library/Logs/小米超级键盘/superkeyboard.log"`

Expected: 无内建键盘注册、无未配对 modifier、圆盘稳定帧有滚动记录、静置无滚动。

- [ ] **Step 4: 定向提交**

Run: `git add mac-app/Sources mac-app/Tests mac-app/build.sh esp32-bridge docs && git commit -m "fix: harden remote input and enable ring scrolling"`

