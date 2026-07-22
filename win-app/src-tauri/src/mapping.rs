// mapping.rs — 按键映射 + 合成事件 + 特殊动作（移植自 Mac 版 Engine.swift）
use crate::config::{self, vk, ButtonMapping, Config, SPECIAL_BASE};
use enigo::{Axis, Button as MouseButton, Direction, Enigo, Key as EnigoKey, Keyboard, Mouse, Settings};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use std::thread;

/// Windows VK code → enigo Key 枚举。
/// 关键修复：不能用 enigo.raw()（它期望 scancode 而非 VK code）。
/// 用 enigo.key() + 命名 Key 枚举，enigo 内部正确处理 VK→scancode + 扩展键标志。
fn vk_to_enigo_key(vk_code: u16) -> Option<EnigoKey> {
    match vk_code {
        vk::UP => Some(EnigoKey::UpArrow),
        vk::DOWN => Some(EnigoKey::DownArrow),
        vk::LEFT => Some(EnigoKey::LeftArrow),
        vk::RIGHT => Some(EnigoKey::RightArrow),
        vk::RETURN => Some(EnigoKey::Return),
        vk::BACK => Some(EnigoKey::Backspace),
        vk::DELETE => Some(EnigoKey::Delete),
        vk::ESCAPE => Some(EnigoKey::Escape),
        vk::SPACE => Some(EnigoKey::Space),
        vk::TAB => Some(EnigoKey::Tab),
        vk::HOME => Some(EnigoKey::Home),
        vk::END => Some(EnigoKey::End),
        vk::PRIOR => Some(EnigoKey::PageUp),
        vk::NEXT => Some(EnigoKey::PageDown),
        // 字母/数字用 Unicode（enigo 会自动转 scancode）
        c if (0x30..=0x5A).contains(&c) => {
            char::from_u32(c as u32).map(EnigoKey::Unicode)
        }
        _ => None,
    }
}

/// 发送 VK 按键（按下或松开）
fn send_vk(enigo: &mut Enigo, vk_code: u16, direction: Direction) {
    if let Some(key) = vk_to_enigo_key(vk_code) {
        let _ = enigo.key(key, direction);
    }
}

/// 按键处理器：接收 HID usage，执行映射
pub struct KeyMapper {
    config: Arc<Mutex<Config>>,
    enigo: Arc<Mutex<Enigo>>,
    delete_repeating: Arc<Mutex<bool>>,
    delete_thread_handle: Option<thread::JoinHandle<()>>,
}

impl KeyMapper {
    pub fn new(config: Arc<Mutex<Config>>) -> Self {
        let enigo = Enigo::new(&Settings::default())
            .unwrap_or_else(|e| panic!("无法初始化输入模拟: {}", e));
        Self {
            config,
            enigo: Arc::new(Mutex::new(enigo)),
            delete_repeating: Arc::new(Mutex::new(false)),
            delete_thread_handle: None,
        }
    }

    /// 处理按键按下
    pub fn on_key_down(&mut self, usage: u16) {
        if usage == 0x3E {
            let mode = self.config.lock().unwrap().voice_mode;
            self.handle_voice_key_down(mode);
            return;
        }
        let cfg = self.config.lock().unwrap();
        let mapping = match cfg.find_mapping(usage) { Some(m) => m.clone(), None => return };
        drop(cfg);

        if mapping.special >= SPECIAL_BASE { self.execute_special(mapping.special, true); return; }
        if usage == 0xF1 && mapping.vk == vk::BACK { self.start_delete_repeat(); return; }
        if mapping.vk != config::VK_NONE {
            let mut enigo = self.enigo.lock().unwrap();
            send_vk(&mut enigo, mapping.vk, Direction::Press);
        }
    }

    /// 处理按键松开
    pub fn on_key_up(&mut self, usage: u16) {
        if usage == 0x3E {
            let mode = self.config.lock().unwrap().voice_mode;
            self.handle_voice_key_up(mode);
            return;
        }
        let cfg = self.config.lock().unwrap();
        let mapping = match cfg.find_mapping(usage) { Some(m) => m.clone(), None => return };
        drop(cfg);

        if usage == 0xF1 { *self.delete_repeating.lock().unwrap() = false; }
        if mapping.special >= SPECIAL_BASE { self.execute_special(mapping.special, false); return; }
        if mapping.vk != config::VK_NONE {
            let mut enigo = self.enigo.lock().unwrap();
            send_vk(&mut enigo, mapping.vk, Direction::Release);
        }
    }

    /// 启动变速删除（长按 Back）
    fn start_delete_repeat(&mut self) {
        // 先停掉之前的线程（防止累积多次删除）
        *self.delete_repeating.lock().unwrap() = false;
        if let Some(handle) = self.delete_thread_handle.take() { let _ = handle.join(); }
        *self.delete_repeating.lock().unwrap() = true;
        let repeating = self.delete_repeating.clone();
        let enigo = self.enigo.clone();

        self.delete_thread_handle = Some(thread::spawn(move || {
            thread::sleep(Duration::from_millis(400));
            let mut interval = 0.12f32;
            let min_interval = 0.022f32;
            let decay = 0.92f32;
            while *repeating.lock().unwrap() {
                { let mut e = enigo.lock().unwrap();
                  let _ = e.key(EnigoKey::Backspace, Direction::Press);
                  let _ = e.key(EnigoKey::Backspace, Direction::Release);
                }
                thread::sleep(Duration::from_millis((interval * 1000.0) as u64));
                interval = (interval * decay).max(min_interval);
            }
        }));
    }

    /// 语音键按下
    fn handle_voice_key_down(&self, mode: config::VoiceMode) {
        use config::VoiceMode;
        let mut e = self.enigo.lock().unwrap();
        match mode {
            VoiceMode::WinH => {
                let _ = e.key(EnigoKey::Meta, Direction::Press);
                let _ = e.key(EnigoKey::Unicode('h'), Direction::Press);
                let _ = e.key(EnigoKey::Unicode('h'), Direction::Release);
                let _ = e.key(EnigoKey::Meta, Direction::Release);
            }
            VoiceMode::LeftCtrl => { let _ = e.key(EnigoKey::Control, Direction::Press); }
            VoiceMode::LeftWin => { let _ = e.key(EnigoKey::Meta, Direction::Press); }
            VoiceMode::CtrlWin => { let _ = e.key(EnigoKey::Control, Direction::Press);
                                     let _ = e.key(EnigoKey::Meta, Direction::Press); }
            VoiceMode::WinShift => { let _ = e.key(EnigoKey::Meta, Direction::Press);
                                      let _ = e.key(EnigoKey::Shift, Direction::Press); }
            VoiceMode::CtrlShift => { let _ = e.key(EnigoKey::Control, Direction::Press);
                                       let _ = e.key(EnigoKey::Shift, Direction::Press); }
            VoiceMode::AltShift => {
                let _ = e.key(EnigoKey::Alt, Direction::Press);
                let _ = e.key(EnigoKey::Shift, Direction::Press);
                let _ = e.key(EnigoKey::Shift, Direction::Release);
                let _ = e.key(EnigoKey::Alt, Direction::Release);
            }
            VoiceMode::MicToggle => {}
        }
    }

    /// 语音键松开
    fn handle_voice_key_up(&self, mode: config::VoiceMode) {
        use config::VoiceMode;
        let mut e = self.enigo.lock().unwrap();
        match mode {
            VoiceMode::LeftCtrl => { let _ = e.key(EnigoKey::Control, Direction::Release); }
            VoiceMode::LeftWin => { let _ = e.key(EnigoKey::Meta, Direction::Release); }
            VoiceMode::CtrlWin => { let _ = e.key(EnigoKey::Meta, Direction::Release);
                                     let _ = e.key(EnigoKey::Control, Direction::Release); }
            VoiceMode::WinShift => { let _ = e.key(EnigoKey::Shift, Direction::Release);
                                      let _ = e.key(EnigoKey::Meta, Direction::Release); }
            VoiceMode::CtrlShift => { let _ = e.key(EnigoKey::Shift, Direction::Release);
                                       let _ = e.key(EnigoKey::Control, Direction::Release); }
            _ => {}
        }
    }

    /// 特殊动作
    fn execute_special(&self, code: u32, down: bool) {
        use crate::config::*;
        if !down { return; }
        match code {
            SPECIAL_OPEN_NOTEPAD => {
                let _ = std::process::Command::new("cmd").args(["/c", "notepad"]).spawn();
                thread::sleep(Duration::from_millis(500));
                let mut e = self.enigo.lock().unwrap();
                let _ = e.key(EnigoKey::Control, Direction::Press);
                let _ = e.key(EnigoKey::Unicode('n'), Direction::Press);
                let _ = e.key(EnigoKey::Unicode('n'), Direction::Release);
                let _ = e.key(EnigoKey::Control, Direction::Release);
            }
            SPECIAL_LOCK_SCREEN => {
                #[cfg(target_os = "windows")]
                { let _ = std::process::Command::new("rundll32.exe")
                    .args(["user32.dll,LockWorkStation"]).spawn(); }
            }
            SPECIAL_SHUTDOWN_CONFIRM => {
                #[cfg(target_os = "windows")]
                { let _ = std::process::Command::new("shutdown")
                    .args(["/s", "/t", "30"]).spawn(); }
            }
            SPECIAL_INTERRUPT => {
                let mut e = self.enigo.lock().unwrap();
                let _ = e.key(EnigoKey::Control, Direction::Press);
                let _ = e.key(EnigoKey::Unicode('c'), Direction::Press);
                let _ = e.key(EnigoKey::Unicode('c'), Direction::Release);
                let _ = e.key(EnigoKey::Control, Direction::Release);
            }
            SPECIAL_SHOW_DESKTOP => {
                let mut e = self.enigo.lock().unwrap();
                let _ = e.key(EnigoKey::Meta, Direction::Press);
                let _ = e.key(EnigoKey::Unicode('d'), Direction::Press);
                let _ = e.key(EnigoKey::Unicode('d'), Direction::Release);
                let _ = e.key(EnigoKey::Meta, Direction::Release);
            }
            SPECIAL_MOUSE_CLICK => {
                let mut e = self.enigo.lock().unwrap();
                let _ = e.button(MouseButton::Left, Direction::Click);
            }
            SPECIAL_MOUSE_RCLICK => {
                let mut e = self.enigo.lock().unwrap();
                let _ = e.button(MouseButton::Right, Direction::Click);
            }
            SPECIAL_SCROLL_UP => {
                let mut e = self.enigo.lock().unwrap();
                let _ = e.scroll(2, Axis::Vertical);
            }
            SPECIAL_SCROLL_DOWN => {
                let mut e = self.enigo.lock().unwrap();
                let _ = e.scroll(-2, Axis::Vertical);
            }
            _ => {}
        }
    }
}
