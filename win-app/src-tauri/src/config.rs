// config.rs — 配置存储与按键映射表（移植自 Mac 版 Model.swift）
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// HID usage → Windows VK keycode 映射
/// Windows VK keycode 参考：https://learn.microsoft.com/en-us/windows/win32/inputdev/virtual-key-codes
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ButtonMapping {
    pub usage: u16,       // HID usage（0x52=上, 0x28=OK, 0xF1=Back 等）
    pub name: String,     // 按键名
    pub vk: u16,          // Windows VK keycode（0xFFFF = 保持原样/不映射）
    pub special: u32,     // 特殊动作码（0 = 无，>=0x10000 = 特殊动作）
    pub long_press_special: u32, // 长按特殊动作（0 = 无）
}

/// 特殊动作码（和 Mac 版对齐，Windows 实现不同）
pub const SPECIAL_BASE: u32 = 0x10000;
pub const SPECIAL_MOUSE_UP: u32 = 0x10001;
pub const SPECIAL_MOUSE_DOWN: u32 = 0x10002;
pub const SPECIAL_MOUSE_LEFT: u32 = 0x10003;
pub const SPECIAL_MOUSE_RIGHT: u32 = 0x10004;
pub const SPECIAL_MOUSE_CLICK: u32 = 0x10005;
pub const SPECIAL_MOUSE_RCLICK: u32 = 0x10006;
pub const SPECIAL_SCROLL_UP: u32 = 0x10007;
pub const SPECIAL_SCROLL_DOWN: u32 = 0x10008;
pub const SPECIAL_SHOW_DESKTOP: u32 = 0x1000D;
pub const SPECIAL_OPEN_NOTEPAD: u32 = 0x1000E;
pub const SPECIAL_LOCK_SCREEN: u32 = 0x10009;
pub const SPECIAL_SHUTDOWN_CONFIRM: u32 = 0x1000B;
pub const SPECIAL_INTERRUPT: u32 = 0x1000C;
pub const VK_NONE: u16 = 0xFFFF;

/// 已知按键列表（usage, name）
pub const KNOWN_BUTTONS: &[(u16, &str)] = &[
    (0x52, "方向 上"),
    (0x51, "方向 下"),
    (0x50, "方向 左"),
    (0x4F, "方向 右"),
    (0x28, "确认 OK"),
    (0xF1, "返回 Back"),
    (0x4A, "主页 Home"),
    (0x65, "菜单 Menu"),
    (0x35, "TV 键"),
    (0x66, "电源 Power"),
    (0x80, "音量 +"),
    (0x81, "音量 −"),
];

/// 特殊动作列表（name, code）
pub const SPECIALS: &[(&str, u32)] = &[
    ("鼠标 ↑", SPECIAL_MOUSE_UP),
    ("鼠标 ↓", SPECIAL_MOUSE_DOWN),
    ("鼠标 ←", SPECIAL_MOUSE_LEFT),
    ("鼠标 →", SPECIAL_MOUSE_RIGHT),
    ("鼠标左键", SPECIAL_MOUSE_CLICK),
    ("鼠标右键", SPECIAL_MOUSE_RCLICK),
    ("滚轮 ↑", SPECIAL_SCROLL_UP),
    ("滚轮 ↓", SPECIAL_SCROLL_DOWN),
    ("显示桌面（Win+D）", SPECIAL_SHOW_DESKTOP),
    ("打开记事本", SPECIAL_OPEN_NOTEPAD),
    ("锁定屏幕", SPECIAL_LOCK_SCREEN),
    ("关机（确认）", SPECIAL_SHUTDOWN_CONFIRM),
    ("中断当前终端（Ctrl+C）", SPECIAL_INTERRUPT),
];

/// Windows VK keycode 常量
pub mod vk {
    pub const UP: u16 = 0x26;
    pub const DOWN: u16 = 0x28;
    pub const LEFT: u16 = 0x25;
    pub const RIGHT: u16 = 0x27;
    pub const RETURN: u16 = 0x0D;
    pub const BACK: u16 = 0x08;   // Backspace
    pub const DELETE: u16 = 0x2E;
    pub const ESCAPE: u16 = 0x1B;
    pub const SPACE: u16 = 0x20;
    pub const TAB: u16 = 0x09;
    pub const HOME: u16 = 0x24;
    pub const END: u16 = 0x23;
    pub const PRIOR: u16 = 0x21;  // PgUp
    pub const NEXT: u16 = 0x22;   // PgDn
    // 修饰键
    pub const SHIFT: u16 = 0x10;
    pub const CONTROL: u16 = 0x11;
    pub const ALT: u16 = 0x12;
    pub const LWIN: u16 = 0x5B;
    pub const RWIN: u16 = 0x5C;
    // 字母 A-Z = 0x41-0x5A
    pub fn letter(c: char) -> u16 { (c as u16) | 0x20 }  // 小写转 VK
    // 数字 0-9 = 0x30-0x39
}

/// 语音键映射模式（Windows 适配版）
/// Windows 没有 Mac 的 Globe/Fn，提供多种 Windows 原生替代：
/// - WinH：Windows 自带语音听写（Win+H），最接近 Mac Fn 听写体验
/// - LeftCtrl：左 Ctrl 修饰键，配合其他键发 Ctrl 组合
/// - LeftWin：左 Win 键，触发 Windows 开始菜单/语音助手
/// - MicToggle：按一下切换"转发音频到虚拟麦克风"开关（语音转文字用）
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq)]
pub enum VoiceMode {
    WinH,       // Win+H Windows 语音听写
    LeftCtrl,   // 左 Ctrl 修饰键
    LeftWin,    // 左 Win 键
    CtrlWin,    // Ctrl+Win 组合修饰键
    WinShift,   // Win+Shift 组合修饰键
    CtrlShift,  // Ctrl+Shift 组合修饰键
    AltShift,   // Alt+Shift 组合修饰键（中英文切换）
    MicToggle,  // 切换虚拟麦克风转发
}

impl Default for VoiceMode {
    fn default() -> Self { VoiceMode::WinH }
}

impl VoiceMode {
    pub fn label(&self) -> &'static str {
        match self {
            VoiceMode::WinH => "Win+H 语音听写（推荐）",
            VoiceMode::LeftCtrl => "左 Ctrl（修饰键）",
            VoiceMode::LeftWin => "左 Win 键",
            VoiceMode::CtrlWin => "Ctrl+Win（双修饰键）",
            VoiceMode::WinShift => "Win+Shift（双修饰键）",
            VoiceMode::CtrlShift => "Ctrl+Shift（双修饰键）",
            VoiceMode::AltShift => "Alt+Shift（中英切换）",
            VoiceMode::MicToggle => "麦克风开关（转发音频）",
        }
    }
    pub fn detail(&self) -> &'static str {
        match self {
            VoiceMode::WinH => "触发 Windows 11/10 自带语音听写，最接近 Mac 的 Fn 听写",
            VoiceMode::LeftCtrl => "作为左 Ctrl 修饰键，配合其他键发 Ctrl 组合快捷键",
            VoiceMode::LeftWin => "作为左 Win 键，触发开始菜单/Windows 语音助手",
            VoiceMode::CtrlWin => "同时按住 Ctrl+Win，配合其他键发 Win+Ctrl 组合",
            VoiceMode::WinShift => "同时按住 Win+Shift，配合其他键发 Win+Shift 组合",
            VoiceMode::CtrlShift => "同时按住 Ctrl+Shift，配合其他键发 Ctrl+Shift 组合",
            VoiceMode::AltShift => "按一下切换输入语言（Windows 中英文切换快捷键）",
            VoiceMode::MicToggle => "按一下开始转发音频到虚拟麦克风，再按一下停止",
        }
    }
    pub fn all() -> &'static [VoiceMode] {
        &[
            VoiceMode::WinH,
            VoiceMode::LeftCtrl,
            VoiceMode::LeftWin,
            VoiceMode::CtrlWin,
            VoiceMode::WinShift,
            VoiceMode::CtrlShift,
            VoiceMode::AltShift,
            VoiceMode::MicToggle,
        ]
    }
}

/// 配置
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Config {
    pub buttons: Vec<ButtonMapping>,
    pub voice_enabled: bool,
    pub voice_mode: VoiceMode,
    pub selected_remote_id: Option<String>,
}

impl Default for Config {
    fn default() -> Self {
        let buttons = KNOWN_BUTTONS.iter().map(|(usage, name)| {
            let (vk, special, long_press) = default_mapping(*usage);
            ButtonMapping {
                usage: *usage,
                name: name.to_string(),
                vk,
                special,
                long_press_special: long_press,
            }
        }).collect();
        Config {
            buttons,
            voice_enabled: true,
            voice_mode: VoiceMode::WinH,
            selected_remote_id: None,
        }
    }
}

/// 默认映射（usage → (vk, special, long_press_special)）
fn default_mapping(usage: u16) -> (u16, u32, u32) {
    match usage {
        0x52 => (vk::UP, 0, 0),           // 上
        0x51 => (vk::DOWN, 0, 0),         // 下
        0x50 => (vk::LEFT, 0, 0),         // 左
        0x4F => (vk::RIGHT, 0, 0),        // 右
        0x28 => (vk::RETURN, 0, 0),       // OK → Enter
        0xF1 => (vk::BACK, 0, 0),         // Back → Backspace（长按变速删除）
        0x4A => (0, SPECIAL_OPEN_NOTEPAD, 0), // Home → 打开记事本
        0x65 => (vk::ESCAPE, 0, SPECIAL_INTERRUPT), // Menu → Esc / 长按 Ctrl+C
        0x66 => (0, SPECIAL_LOCK_SCREEN, SPECIAL_SHUTDOWN_CONFIRM), // Power → 锁屏/关机
        _ => (VK_NONE, 0, 0),             // 其他保持原样
    }
}

/// 配置文件路径
pub fn config_path() -> std::path::PathBuf {
    let dir = dirs::config_dir().unwrap_or_else(|| std::path::PathBuf::from("."));
    dir.join("MiSuperKeyboard").join("config.json")
}

impl Config {
    pub fn load() -> Self {
        let path = config_path();
        match std::fs::read_to_string(&path) {
            Ok(data) => serde_json::from_str(&data).unwrap_or_default(),
            Err(_) => Self::default(),
        }
    }

    pub fn save(&self) {
        let path = config_path();
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(json) = serde_json::to_string_pretty(self) {
            let _ = std::fs::write(path, json);
        }
    }

    /// 按 usage 查找映射
    pub fn find_mapping(&self, usage: u16) -> Option<&ButtonMapping> {
        self.buttons.iter().find(|b| b.usage == usage)
    }
}

// dirs crate 的简易替代（避免额外依赖）
mod dirs {
    use std::path::PathBuf;
    pub fn config_dir() -> Option<PathBuf> {
        #[cfg(target_os = "windows")]
        {
            std::env::var_os("APPDATA").map(PathBuf::from)
        }
        #[cfg(target_os = "macos")]
        {
            std::env::var_os("HOME").map(|h| PathBuf::from(h).join("Library/Application Support"))
        }
        #[cfg(not(any(target_os = "windows", target_os = "macos")))]
        {
            std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config"))
        }
    }
}
