// hid.rs — HID 设备读取（hidapi 读遥控器按键报告）
// Windows 上系统也可能独占键盘类 HID（ReadFile 拒绝访问），和 macOS 类似。
// 如果拒绝访问，设备被系统当键盘直传——App 不需要读 HID，系统直接处理按键。
// App 的角色是附加层：语音键模式、特殊动作等，在系统按键之上做额外映射。
use crate::diagnostics::{self, Diagnostics};
use hidapi::HidApi;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

/// 已知按键 usage 集合
const KNOWN_USAGES: &[u8] = &[
    0x52, 0x51, 0x50, 0x4F, 0x28, 0xF1, 0x4A, 0x35, 0x65, 0x66, 0x3E, 0x80, 0x81,
];

fn parse_usage_from_report(data: &[u8]) -> Option<u8> {
    if data.len() < 4 {
        return None;
    }
    if let Some(&key) = data[3..].iter().find(|key| KNOWN_USAGES.contains(key)) {
        return Some(key);
    }
    for pair in data.windows(2) {
        match u16::from_le_bytes([pair[0], pair[1]]) {
            0x00E9 => return Some(0x80),
            0x00EA => return Some(0x81),
            _ => {}
        }
    }
    None
}

fn is_release_report(data: &[u8]) -> bool {
    if data.len() < 4 {
        return false;
    }
    data[3..].iter().all(|byte| *byte == 0)
}

pub struct HidListener {
    running: Arc<Mutex<bool>>,
    thread_handle: Option<thread::JoinHandle<()>>,
}

pub type KeyCallback = Box<dyn Fn(u16, bool) + Send + 'static>;

impl HidListener {
    pub fn new() -> Self {
        Self {
            running: Arc::new(Mutex::new(false)),
            thread_handle: None,
        }
    }

    pub fn scan_known_devices() -> Result<Vec<String>, String> {
        let api = HidApi::new().map_err(|e| e.to_string())?;
        Ok(api
            .device_list()
            .filter(|d| d.vendor_id() == 0x2717)
            .map(|d| {
                format!(
                    "{} (VID=0x{:04X}, PID=0x{:04X}, usage_page=0x{:04X}, usage=0x{:04X})",
                    d.product_string().unwrap_or("未知"),
                    d.vendor_id(),
                    d.product_id(),
                    d.usage_page(),
                    d.usage()
                )
            })
            .collect())
    }

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

            while *running.lock().unwrap() {
                let mut devices_found = false;

                if let Ok(api) = HidApi::new() {
                    // 只匹配小米 VID 0x2717（不匹配 0x17EF，因为联想笔记本键盘也用这个 VID）
                    let devices: Vec<_> = api
                        .device_list()
                        .filter(|d| d.vendor_id() == 0x2717)
                        .collect();

                    for info in &devices {
                        if !*running.lock().unwrap() {
                            break;
                        }

                        match info.open_device(&api) {
                            Ok(device) => {
                                devices_found = true;
                                prev_usage = 0;
                                diagnostics::record(
                                    &diagnostics,
                                    format!(
                                        "HID 已连接: {} (PID=0x{:04X}, usage_page=0x{:04X})",
                                        info.product_string().unwrap_or("?"),
                                        info.product_id(),
                                        info.usage_page()
                                    ),
                                );

                                let mut buf = [0u8; 256];
                                while *running.lock().unwrap() {
                                    match device.read_timeout(&mut buf, 1000) {
                                        Ok(size) if size > 0 => {
                                            let data = &buf[..size];
                                            if is_release_report(data) {
                                                if prev_usage != 0 {
                                                    callback(prev_usage as u16, false);
                                                    prev_usage = 0;
                                                }
                                            } else if let Some(usage) =
                                                parse_usage_from_report(data)
                                            {
                                                if usage != prev_usage {
                                                    if prev_usage != 0 {
                                                        callback(prev_usage as u16, false);
                                                    }
                                                    callback(usage as u16, true);
                                                    prev_usage = usage;
                                                }
                                            }
                                        }
                                        Ok(_) => {}
                                        Err(e) => {
                                            let msg = e.to_string();
                                            // Windows 系统独占键盘：拒绝访问（Access Denied）
                                            // 这意味着系统直接处理该设备的按键，App 不需要读。
                                            // 退避等待，不要无限重连。
                                            if msg.contains("拒绝访问") || msg.contains("Access")
                                            {
                                                diagnostics::record(&diagnostics, format!(
                                                    "HID 系统独占: {} — 系统直接处理按键，App 跳过此设备", msg));
                                            } else {
                                                diagnostics::record(
                                                    &diagnostics,
                                                    format!("HID 读错误: {}", msg),
                                                );
                                            }
                                            // 退避 5 秒，防止无限循环刷日志/CPU
                                            thread::sleep(Duration::from_secs(5));
                                            break;
                                        }
                                    }
                                }
                                if prev_usage != 0 {
                                    callback(prev_usage as u16, false);
                                    prev_usage = 0;
                                }
                            }
                            Err(e) => {
                                let msg = e.to_string();
                                if msg.contains("拒绝访问") || msg.contains("Access") {
                                    // 系统独占——正常，不刷日志
                                } else {
                                    diagnostics::record(
                                        &diagnostics,
                                        format!("HID 无法打开: {}", msg),
                                    );
                                }
                            }
                        }
                    }
                }

                // 没找到可读设备时等 2 秒再重试（不要空转）
                if !devices_found {
                    thread::sleep(Duration::from_secs(2));
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
