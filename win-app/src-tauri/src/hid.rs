// hid.rs — HID 设备读取（hidapi 读遥控器按键报告）
// Windows 上 hidapi 直接读，无系统独占问题（不像 macOS）
use hidapi::HidApi;
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
/// 我们提取 key0 作为 usage
fn parse_usage_from_report(data: &[u8]) -> Option<u8> {
    if data.len() < 4 { return None; }
    // 跳过 ReportID（第 0 字节），mod（第 1 字节），rsv（第 2 字节）
    // key0 在第 3 字节
    let key = data[3];
    if key == 0 { return None; }  // 0 = 无按键（release）
    // 检查是否已知 usage
    if KNOWN_USAGES.contains(&key) {
        return Some(key);
    }
    None
}

/// 判断报告是否为 release（全零或按键区全零）
fn is_release_report(data: &[u8]) -> bool {
    if data.len() < 4 { return false; }
    data[3] == 0  // key0 = 0 表示松开
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

    /// 启动 HID 监听。callback 在按键按下/松开时调用。
    pub fn start<F>(&mut self, callback: F)
    where
        F: Fn(u16, bool) + Send + 'static,
    {
        *self.running.lock().unwrap() = true;
        let running = self.running.clone();
        let callback: KeyCallback = Box::new(callback);

        self.thread_handle = Some(thread::spawn(move || {
            log::info!("HID 监听线程启动");
            let mut prev_usage: u8 = 0;

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
                            thread::sleep(Duration::from_secs(2));
                            continue;
                        }

                        // 尝试打开每个遥控器设备读报告
                        for info in &devices {
                            if let Ok(device) = info.open_device(&api) {
                                log::info!("HID 已连接: {} (VID 0x{:04X} PID 0x{:04X})",
                                    info.product_string().unwrap_or("?"),
                                    info.vendor_id(), info.product_id());

                                let mut buf = [0u8; 256];
                                while *running.lock().unwrap() {
                                    // 读报告（超时 1 秒，避免永久阻塞）
                                    match device.read_timeout(1000) {
                                        Ok(size) if size > 0 => {
                                            let data = &buf[..size];
                                            if is_release_report(data) {
                                                if prev_usage != 0 {
                                                    callback(prev_usage as u16, false);
                                                    prev_usage = 0;
                                                }
                                            } else if let Some(usage) = parse_usage_from_report(data) {
                                                if usage != prev_usage {
                                                    if prev_usage != 0 {
                                                        callback(prev_usage as u16, false);
                                                    }
                                                    callback(usage as u16, true);
                                                    prev_usage = usage;
                                                }
                                            }
                                        }
                                        Ok(_) => {}  // 超时，正常
                                        Err(e) => {
                                            log::warn!("HID 读错误: {}", e);
                                            break;  // 设备断开，重新枚举
                                        }
                                    }
                                }
                                log::info!("HID 设备断开，重新枚举");
                            }
                        }
                    }
                    Err(e) => {
                        log::warn!("HidApi 初始化失败: {}", e);
                        thread::sleep(Duration::from_secs(2));
                    }
                }
            }
            log::info!("HID 监听线程结束");
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
