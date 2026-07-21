# 小米超级键盘 · Windows 真机验收

这份流程用于在借用的 Windows 10/11 电脑上完成一次可复盘的验收。请不要在未完成第 1 步前测试按键，以免遗漏连接诊断信息。

## 安装前准备

1. 从 GitHub Actions 的 **小米超级键盘-Windows** artifact 下载 NSIS `.exe` 或 MSI 安装包。
2. 在 Windows **设置 → 蓝牙和设备**中，先移除遥控器已有的旧配对记录，再重新配对。
3. 打开应用。它会把诊断日志写入：`%APPDATA%\MiSuperKeyboard\diagnostics.log`。日志最多保留约 2 MiB，轮换前一份到 `diagnostics.previous.log`。

## 验收顺序

1. 在应用首页点击“重新扫描设备”。
   - 通过：弹窗显示至少一个候选 HID 接口；诊断日志包含 VID、PID、usage page、usage。
   - 失败：不要继续测试，保留日志。通常是未配对、设备未连接，或该型号的 Vendor ID 不在当前支持范围（0x2717 / 0x17EF）。
2. 依次短按：上、下、左、右、OK、Back、Home、Menu、TV、Power、音量加、音量减。
   - 通过：每次按下和松开均有 `HID 报告` 与 `按键事件` 日志；方向/OK 产生对应键盘操作，音量键调节系统音量。
   - 如果无响应：日志中的原始十六进制报告就是修复解析器所需的唯一证据，请完整保留。
3. 按住 Back 至少 0.5 秒后松开。
   - 通过：开始连续 Backspace，松开后立即停止。
4. 在“按键”页保留默认 **Win+H**，短按语音键。
   - 通过：Windows 语音听写界面弹出。若 Windows 首次要求下载语音包或授予在线语音识别权限，请按系统提示完成。
5. 依次测试 Home、Menu、Power。
   - Home：打开记事本；Menu：发送 Esc；Power：锁定 Windows。
   - 关机动作不应在验收期间测试。

## 当前已知边界

- Windows 版已实现 HID 按键监听、系统按键合成和语音键快捷键（默认 Win+H）。
- ATVV 蓝牙语音音频解码并输出到 VB-Cable **尚未实现**；不要把“麦克风转发”列入本次验收通过条件。
- 真机若发现不兼容，请提供 `diagnostics.log` 和 `diagnostics.previous.log`（如存在），无需截图或手工抄写日志。
