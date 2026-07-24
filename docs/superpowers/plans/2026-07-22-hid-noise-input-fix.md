# HID 噪声误输入修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 macOS 遥控器输入链路中隔离圆盘与圆环噪声报告，杜绝其被错误派发为按键。

**Architecture:** `Engine.handleHIDReport(_:)` 是原始 HID 报告进入按键解析前的唯一分流点。将报告类型分流前置，使圆盘保留其独立的滚动解码路径、圆环直接丢弃，而普通按键继续复用既有 `XiaomiRemoteHIDParser`。

**Tech Stack:** Swift、Foundation、IOKit HID、现有 `RemoteInputSafetyTests` 可执行回归测试。

---

### Task 1: 为报告分类建立失败回归用例

**Files:**
- Modify: `mac-app/Sources/RemoteInputSafety.swift`
- Test: `mac-app/Tests/RemoteInputSafetyTests.swift`

- [ ] **Step 1: 写入失败测试**

提取无副作用的 `RemoteHIDReportKind` 分类器，测试 `[0x03, 0, 0x28, 0, 0, 0, 1]` 识别为 `.scrollRing`，并断言普通 `0x01` 键盘报告仍是 `.button`。

- [ ] **Step 2: 运行并确认失败**

运行：`swiftc mac-app/Sources/RemoteInputSafety.swift mac-app/Tests/RemoteInputSafetyTests.swift -o /tmp/remote-input-safety-tests && /tmp/remote-input-safety-tests`

预期：因 `RemoteHIDReportKind` 尚不存在而编译失败。

- [ ] **Step 3: 最小实现分类器**

在 `RemoteInputSafety.swift` 新增内部枚举与静态 `classify(_:)`：仅精确匹配 `0x03 + 7 字节` 为圆盘，其余为普通按键候选。`0x01 + 10` 可能是合法键盘格式，未有现场证据前不提前吞掉。

- [ ] **Step 4: 再运行测试确认通过**

运行相同命令，预期输出 `PASS`。

### Task 2: 在解析前按报告类别隔离噪声

**Files:**
- Modify: `mac-app/Sources/Engine.swift:1525-1625`
- Test: `mac-app/Tests/RemoteInputSafetyTests.swift`

- [ ] **Step 1: 改动前确认完整测试仍通过**

运行：`swiftc mac-app/Sources/RemoteInputSafety.swift mac-app/Tests/RemoteInputSafetyTests.swift -o /tmp/remote-input-safety-tests && /tmp/remote-input-safety-tests`

- [ ] **Step 2: 最小实现报告预分流**

在 `handleHIDReport(_:)` 中，调用 `RemoteHIDReportKind.classify(bytes)`：

```swift
switch RemoteHIDReportKind.classify(bytes) {
case .scrollRing:
    // 保留已有 ringEnabled、RingScrollDecoder 和学习日志代码；return
case .button:
    break
}
```

删除后续重复的 `0x03` 分支，使普通按键解析不再接触圆盘噪声数据；保留 `0x01` 的既有处理。

- [ ] **Step 3: 编译 macOS 应用并运行回归测试**

运行项目已有 macOS 构建命令；若无脚本，至少执行 `swiftc` 输入安全测试并执行 `swiftc -typecheck` 覆盖 `Engine.swift` 与其应用内依赖。

- [ ] **Step 4: 检查变更范围**

运行：`git diff --check && git diff -- mac-app/Sources/RemoteInputSafety.swift mac-app/Tests/RemoteInputSafetyTests.swift mac-app/Sources/Engine.swift`

预期：只包含报告分类、预分流和对应回归测试。
