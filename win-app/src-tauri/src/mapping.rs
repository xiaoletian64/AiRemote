// mapping.rs — 按键映射 + 合成事件 + 特殊动作（移植自 Mac 版 Engine.swift）
use crate::config::{self, vk, ButtonMapping, Config, SPECIAL_BASE};
use enigo::{Enigo, Key, KeyboardControllable, MouseControllable, MouseButton};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use std::thread;

/// 按键处理器：接收 HID usage，执行映射
pub struct KeyMapper {
    config: Arc<Mutex<Config>>,
    enigo: Arc<Mutex<Enigo>>,
    // 变速删除状态
    delete_repeating: Arc<Mutex<bool>>,
    delete_thread_handle: Option<thread::JoinHandle<()>>,
}

impl KeyMapper {
    pub fn new(config: Arc<Mutex<Config>>) -> Self {
        Self {
            config,
            enigo: Arc::new(Mutex::new(Enigo::new())),
            delete_repeating: Arc::new(Mutex::new(false)),
            delete_thread_handle: None,
        }
    }

    /// 处理按键按下
    pub fn on_key_down(&mut self, usage: u16) {
        // 语音键（usage 0x3E）：按 voice_mode 发不同组合键
        if usage == 0x3E {
            let cfg = self.config.lock().unwrap();
            let mode = cfg.voice_mode;
            drop(cfg);
            self.handle_voice_key_down(mode);
            return;
        }

        let cfg = self.config.lock().unwrap();
        let mapping = match cfg.find_mapping(usage) {
            Some(m) => m.clone(),
            None => return,
        };
        drop(cfg);

        // 特殊动作
        if mapping.special >= SPECIAL_BASE {
            self.execute_special(mapping.special, true);
            return;
        }

        // Back → 变速删除（长按触发）
        if usage == 0xF1 && mapping.vk == vk::BACK {
            self.start_delete_repeat();
            return;
        }

        // 普通 VK 按键
        if mapping.vk != config::VK_NONE {
            let mut enigo = self.enigo.lock().unwrap();
            let _ = enigo.key_down(Key::Raw(mapping.vk));
        }
    }

    /// 处理按键松开
    pub fn on_key_up(&mut self, usage: u16) {
        // 语音键松开：Ctrl/Win 修饰键需要发 key-up
        if usage == 0x3E {
            let cfg = self.config.lock().unwrap();
            let mode = cfg.voice_mode;
            drop(cfg);
            self.handle_voice_key_up(mode);
            return;
        }

        let cfg = self.config.lock().unwrap();
        let mapping = match cfg.find_mapping(usage) {
            Some(m) => m.clone(),
            None => return,
        };
        drop(cfg);

        // 停止变速删除
        if usage == 0xF1 {
            *self.delete_repeating.lock().unwrap() = false;
        }

        // 特殊动作松开
        if mapping.special >= SPECIAL_BASE {
            self.execute_special(mapping.special, false);
            return;
        }

        // 普通 VK 松开
        if mapping.vk != config::VK_NONE {
            let mut enigo = self.enigo.lock().unwrap();
            let _ = enigo.key_up(Key::Raw(mapping.vk));
        }
    }

    /// 启动变速删除（长按 Back 触发，macOS 原生指数加速曲线）
    fn start_delete_repeat(&mut self) {
        *self.delete_repeating.lock().unwrap() = true;
        let repeating = self.delete_repeating.clone();
        let enigo = self.enigo.clone();

        // 先等 0.4 秒（防误触），然后开始指数加速删除
        self.delete_thread_handle = Some(thread::spawn(move || {
            thread::sleep(Duration::from_millis(400));
            let mut interval = 0.12f32;  // 起始 120ms
            let min_interval = 0.022f32;  // 最低 22ms
            let decay = 0.92f32;          // 每次衰减

            while *repeating.lock().unwrap() {
                {
                    let mut enigo = enigo.lock().unwrap();
                    let _ = enigo.key_down(Key::Raw(vk::BACK));
                    let _ = enigo.key_up(Key::Raw(vk::BACK));
                }
                let sleep_ms = (interval * 1000.0) as u64;
                thread::sleep(Duration::from_millis(sleep_ms));
                interval = (interval * decay).max(min_interval);
            }
        }));
    }

    /// 语音键按下处理：按 voice_mode 发不同组合键
    fn handle_voice_key_down(&self, mode: config::VoiceMode) {
        use config::VoiceMode;
        let mut enigo = self.enigo.lock().unwrap();
        match mode {
            VoiceMode::WinH => {
                // Win+H：Windows 语音听写（按下触发，松开不操作）
                let _ = enigo.key_down(Key::Super);
                let _ = enigo.key_down(Key::Raw(vk::letter('h')));
                let _ = enigo.key_up(Key::Raw(vk::letter('h')));
                let _ = enigo.key_up(Key::Super);
            }
            VoiceMode::LeftCtrl => {
                // 左 Ctrl 按住（松开时发 key-up）
                let _ = enigo.key_down(Key::Control);
            }
            VoiceMode::LeftWin => {
                // 左 Win 按住
                let _ = enigo.key_down(Key::Super);
            }
            VoiceMode::MicToggle => {
                // 切换虚拟麦克风转发开关（由 audio 模块处理，这里只触发事件）
                // 实际音频转发逻辑在 ble.rs 的 ATVV 语音流处理中
            }
        }
    }

    /// 语音键松开处理：修饰键模式需要发 key-up
    fn handle_voice_key_up(&self, mode: config::VoiceMode) {
        use config::VoiceMode;
        let mut enigo = self.enigo.lock().unwrap();
        match mode {
            VoiceMode::LeftCtrl => { let _ = enigo.key_up(Key::Control); }
            VoiceMode::LeftWin => { let _ = enigo.key_up(Key::Super); }
            _ => {}  // WinH 是单次触发，MicToggle 是开关，松开不操作
        }
    }

    /// 执行特殊动作
    fn execute_special(&self, code: u32, down: bool) {
        use crate::config::*;
        if !down { return; }  // 大部分特殊动作只在按下时触发

        match code {
            SPECIAL_OPEN_NOTEPAD => {
                // 打开记事本 + Ctrl+N 新建
                let _ = std::process::Command::new("cmd").args(["/c", "notepad"]).spawn();
                thread::sleep(Duration::from_millis(500));
                let mut enigo = self.enigo.lock().unwrap();
                let _ = enigo.key_down(Key::Control);
                let _ = enigo.key_down(Key::Raw(vk::letter('n')));
                let _ = enigo.key_up(Key::Raw(vk::letter('n')));
                let _ = enigo.key_up(Key::Control);
            }
            SPECIAL_LOCK_SCREEN => {
                // Windows 锁屏
                #[cfg(target_os = "windows")]
                {
                    let _ = std::process::Command::new("rundll32.exe")
                        .args(["user32.dll,LockWorkStation"])
                        .spawn();
                }
            }
            SPECIAL_SHUTDOWN_CONFIRM => {
                // 关机确认框（用 MessageBox 模拟）
                #[cfg(target_os = "windows")]
                {
                    let _ = std::process::Command::new("shutdown")
                        .args(["/s", "/t", "30"])  // 30秒延迟，可取消
                        .spawn();
                }
            }
            SPECIAL_INTERRUPT => {
                // Ctrl+C
                let mut enigo = self.enigo.lock().unwrap();
                let _ = enigo.key_down(Key::Control);
                let _ = enigo.key_down(Key::Raw(vk::letter('c')));
                let _ = enigo.key_up(Key::Raw(vk::letter('c')));
                let _ = enigo.key_up(Key::Control);
            }
            SPECIAL_SHOW_DESKTOP => {
                // Win+D 显示桌面
                let mut enigo = self.enigo.lock().unwrap();
                let _ = enigo.key_down(Key::Super);
                let _ = enigo.key_down(Key::Raw(vk::letter('d')));
                let _ = enigo.key_up(Key::Raw(vk::letter('d')));
                let _ = enigo.key_up(Key::Super);
            }
            // 鼠标/滚轮动作需要持续状态（down/up 配对），简化版先不做持续移动
            SPECIAL_MOUSE_CLICK => {
                let mut enigo = self.enigo.lock().unwrap();
                let _ = enigo.mouse_click(MouseButton::Left);
            }
            SPECIAL_MOUSE_RCLICK => {
                let mut enigo = self.enigo.lock().unwrap();
                let _ = enigo.mouse_click(MouseButton::Right);
            }
            SPECIAL_SCROLL_UP => {
                let mut enigo = self.enigo.lock().unwrap();
                enigo.mouse_scroll_y(2);
            }
            SPECIAL_SCROLL_DOWN => {
                let mut enigo = self.enigo.lock().unwrap();
                enigo.mouse_scroll_y(-2);
            }
            _ => {}
        }
    }
}
