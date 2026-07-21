// hid.rs — HID 设备读取（hidapi 读遥控器按键报告）
// Windows 上 hidapi 直接读，无系统独占问题（不像 macOS）
use hidapi::HidApi;
use crate::diagnostics::{self, Diagnostics};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

/// 已知按键 usage 集合（和 config.rs KNOWN_BUTTONS 对齐）
const KNOWN_USAGES: &[u8] = &[
    0x52, 0x51, 0x50, 0x4F,  // 方向
    0x28,                     // OK
    0xF1,                     // Back
    0x4A,                     // Home
    0x35,                     // TV
    0x65,                     // Menu
    0x66,                     // Power
    0x3E,                     // 语音键 F5
    0x80, 0x81,               // 音量
];

/// 从 HID 报告字节解析按键 usage
/// 小米遥控器的键盘报告格式：[ReportID][mod][rsv][key0..key5]
/// 先扫描键盘 report 的全部六个 key slot，再兼容 Consumer Control 的音量 usage。
fn parse_usage_from_report(data: &[u8]) -> Option<u8> {
    if data.len() < 4 { return None; }
    // 跳过 ReportID / modifier / reserved，扫描所有按键 slot，而不只取 key0。
    if let Some(&key) = data[3..].iter().find(|key| KNOWN_USAGES.contains(key)) {
        return Some(key);
    }
    // 部分遥控器把音量键作为 Consumer Control usage（0x00E9 / 0x00EA）上报。
    for pair in data.windows(2) {
        match u16::from_le_bytes([pair[0], pair[1]]) {
            0x00E9 => return Some(0x80),
            0x00EA => return Some(0x81),
            _ => {}
        }
    }
    None
}

/// 判断报告是否为 release（全零或按键区全零）
fn is_release_report(data: &[u8]) -> bool {
    if data.len() < 4 { return false; }
    data[3..].iter().all(|byte| *byte == 0)
}

/// HID 监听器：在独立线程读遥控器报告，通过回调通知按键事件
pub struct HidListener {
    running: Arc<Mutex<bool>>,
    thread_handle: Option<thread::JoinHandle<()>>,
}

/// 按键事件回调
pub type KeyCallback = Box<dyn Fn(u16, bool) + Send + 'static>;  // (usage, is_down)

impl HidListener {
    pub fn new() -> Self {
        Self {
            running: Arc::new(Mutex::new(false)),
            thread_handle: None,
        }
    }

    /// 列出候选设备。此调用不打开设备，适用于真机验收前的连接诊断。
    pub fn scan_known_devices() -> Result<Vec<String>, String> {
        let api = HidApi::new().map_err(|e| e.to_string())?;
        Ok(api.device_list()
            .filter(|d| matches!(d.vendor_id(), 0x2717 | 0x17EF))
            .map(|d| format!(
                "{} (VID=0x{:04X}, PID=0x{:04X}, usage_page=0x{:04X}, usage=0x{:04X})",
                d.product_string().unwrap_or("未知 HID 设备"),
                d.vendor_id(), d.product_id(), d.usage_page(), d.usage()
            ))
            .collect())
    }

    /// 启动 HID 监听。callback 在按键按下/松开时调用；原始报告会写入诊断日志。
    pub fn start<F>(&mut self, diagnostics: Diagnostics, callback: F)
    where
        F: Fn(u16, bool) + Send + 'static,
    {
        *self.running.lock().unwrap() = true;
        let running = self.running.clone();
        let callback: KeyCallback = Box::new(callback);

        self.thread_handle = Some(thread::spawn(move || {
            diagnostics::record(&diagnostics, "HID 监听线程启动");
            let mut prev_usage: u8 = 0;
            let mut reported_no_devices = false;

            while *running.lock().unwrap() {
                match HidApi::new() {
                    Ok(api) => {
                        // 枚举所有设备，找小米(0x2717)/联想(0x17EF)遥控器
                        let devices: Vec<_> = api.device_list()
                            .filter(|d| {
                                let vid = d.vendor_id();
                                vid == 0x2717 || vid == 0x17EF
                            })
                            .collect();

                        if devices.is_empty() {
                            if !reported_no_devices {
                                diagnostics::record(&diagnostics, "HID 扫描：未发现 VID 0x2717/0x17EF 候选设备");
                                reported_no_devices = true;
                            }
                            thread::sleep(Duration::from_secs(2));
                            continue;
                        }

                        reported_no_devices = false;

                        diagnostics::record(&diagnostics, format!("HID 扫描：发现 {} 个候选接口", devices.len()));

                        // 尝试打开每个遥控器设备读报告
                        for info in &devices {
                            if let Ok(device) = info.open_device(&api) {
                                prev_usage = 0;
                                diagnostics::record(&diagnostics, format!("HID 已连接: {} (VID=0x{:04X}, PID=0x{:04X}, usage_page=0x{:04X}, usage=0x{:04X})",
                                    info.product_string().unwrap_or("?"),
                                    info.vendor_id(), info.product_id(), info.usage_page(), info.usage()));

                                let mut buf = [0u8; 256];
                                while *running.lock().unwrap() {
                                    // 读报告（超时 1 秒，避免永久阻塞）
                                    match device.read_timeout(1000) {
                                        Ok(size) if size > 0 => {
                                            let data = &buf[..size];
                                            let raw = data.iter().map(|b| format!("{:02X}", b)).collect::<Vec<_>>().join(" ");
                                            if is_release_report(data) {
                                                diagnostics::record(&diagnostics, format!("HID 报告 release: [{}]", raw));
                                                if prev_usage != 0 {
                                                    callback(prev_usage as u16, false);
                                                    prev_usage = 0;
                                                }
                                            } else if let Some(usage) = parse_usage_from_report(data) {
                                                diagnostics::record(&diagnostics, format!("HID 报告 usage=0x{:02X}: [{}]", usage, raw));
                                                if usage != prev_usage {
                                                    if prev_usage != 0 {
                                                        callback(prev_usage as u16, false);
                                                    }
                                                    callback(usage as u16, true);
                                                    prev_usage = usage;
                                                }
                                            } else {
                                                diagnostics::record(&diagnostics, format!("HID 报告未识别: [{}]", raw));
                                            }
                                        }
                                        Ok(_) => {}  // 超时，正常
                                        Err(e) => {
                                            diagnostics::record(&diagnostics, format!("HID 读错误: {}", e));
                                            break;  // 设备断开，重新枚举
                                        }
                                    }
                                }
                                if prev_usage != 0 {
                                    callback(prev_usage as u16, false);
                                    prev_usage = 0;
                                }
                                diagnostics::record(&diagnostics, "HID 设备断开，重新枚举");
                            } else {
                                diagnostics::record(&diagnostics, format!("HID 无法打开: {} (VID=0x{:04X}, PID=0x{:04X})",
                                    info.product_string().unwrap_or("?"), info.vendor_id(), info.product_id()));
                            }
                        }
                    }
                    Err(e) => {
                        diagnostics::record(&diagnostics, format!("HidApi 初始化失败: {}", e));
                        thread::sleep(Duration::from_secs(2));
                    }
                }
            }
            diagnostics::record(&diagnostics, "HID 监听线程结束");
        }));
    }

    pub fn stop(&mut self) {
        *self.running.lock().unwrap() = false;
        if let Some(handle) = self.thread_handle.take() {
            let _ = handle.join();
        }
    }
}

impl Drop for HidListener {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(test)]
mod tests {
    use super::{is_release_report, parse_usage_from_report};

    #[test]
    fn parses_a_known_keyboard_usage_in_any_key_slot() {
        assert_eq!(parse_usage_from_report(&[1, 0, 0, 0, 0x52, 0, 0]), Some(0x52));
    }

    #[test]
    fn translates_consumer_volume_reports() {
        assert_eq!(parse_usage_from_report(&[2, 0xE9, 0x00]), None);
        assert_eq!(parse_usage_from_report(&[2, 0, 0, 0xE9, 0x00]), Some(0x80));
        assert_eq!(parse_usage_from_report(&[2, 0, 0, 0xEA, 0x00]), Some(0x81));
    }

    #[test]
    fn release_requires_every_key_slot_to_be_zero() {
        assert!(is_release_report(&[1, 0, 0, 0, 0, 0]));
        assert!(!is_release_report(&[1, 0, 0, 0, 0x52, 0]));
    }
}
