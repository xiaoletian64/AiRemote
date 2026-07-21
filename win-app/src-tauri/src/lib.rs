// lib.rs — Tauri 应用入口，串联所有模块
mod config;
mod hid;
mod mapping;
mod adpcm;
mod dsp;
mod diagnostics;

use config::{Config, VoiceMode};
use mapping::KeyMapper;
use hid::HidListener;
use diagnostics::Diagnostics;
use std::sync::{Arc, Mutex};
use tauri::State;

/// 应用状态
struct AppState {
    config: Arc<Mutex<Config>>,
    key_mapper: Arc<Mutex<KeyMapper>>,
    hid: Arc<Mutex<Option<HidListener>>>,
    connected: Arc<Mutex<bool>>,
    log: Diagnostics,
}

/// 日志辅助
fn log_msg(state: &AppState, msg: String) {
    diagnostics::record(&state.log, msg);
}

// ===== Tauri 命令（前端调用）=====

/// 获取配置
#[tauri::command]
fn get_config(state: State<AppState>) -> Config {
    state.config.lock().unwrap().clone()
}

/// 保存配置
#[tauri::command]
fn save_config(state: State<AppState>, config: Config) {
    *state.config.lock().unwrap() = config.clone();
    config.save();
    log_msg(&state, "配置已保存".to_string());
}

/// 获取连接状态
#[tauri::command]
fn get_status(state: State<AppState>) -> bool {
    *state.connected.lock().unwrap()
}

/// 获取日志
#[tauri::command]
fn get_log(state: State<AppState>) -> Vec<String> {
    state.log.lock().unwrap().clone()
}

#[tauri::command]
fn get_diagnostic_log_path() -> String {
    diagnostics::log_path().display().to_string()
}

/// 设置语音键模式
#[tauri::command]
fn set_voice_mode(state: State<AppState>, mode: VoiceMode) {
    let mut cfg = state.config.lock().unwrap();
    cfg.voice_mode = mode;
    cfg.save();
    drop(cfg);
    log_msg(&state, format!("语音键模式: {}", mode.label()));
}

/// 获取语音键模式列表
#[tauri::command]
fn get_voice_modes() -> Vec<(String, String, String)> {
    VoiceMode::all().iter().map(|m| {
        let value = serde_json::to_string(m).unwrap_or_default().trim_matches('"').to_string();
        (value, m.label().to_string(), m.detail().to_string())
    }).collect()
}

/// 重新扫描设备
#[tauri::command]
fn rescan(state: State<AppState>) -> Vec<String> {
    log_msg(&state, "用户请求重新扫描 HID 设备".to_string());
    match HidListener::scan_known_devices() {
        Ok(devices) if devices.is_empty() => {
            log_msg(&state, "重新扫描结果：没有候选遥控器接口".to_string());
            devices
        }
        Ok(devices) => {
            for device in &devices {
                log_msg(&state, format!("重新扫描结果：{}", device));
            }
            devices
        }
        Err(error) => {
            log_msg(&state, format!("重新扫描失败：{}", error));
            Vec::new()
        }
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            if cfg!(debug_assertions) {
                app.handle().plugin(
                    tauri_plugin_log::Builder::default()
                        .level(log::LevelFilter::Info)
                        .build(),
                )?;
            }

            // 初始化配置
            let config = Arc::new(Mutex::new(Config::load()));
            let key_mapper = Arc::new(Mutex::new(KeyMapper::new(config.clone())));
            let connected = Arc::new(Mutex::new(false));
            let log = diagnostics::new();
            diagnostics::record(&log, format!(
                "应用启动：version={} os={} arch={} diagnostics={}",
                env!("CARGO_PKG_VERSION"), std::env::consts::OS, std::env::consts::ARCH,
                diagnostics::log_path().display()
            ));

            // 启动 HID 监听
            let mut hid = HidListener::new();
            let km = key_mapper.clone();
            let conn = connected.clone();
            {
                let config_clone = config.clone();
                let log_clone = log.clone();
                hid.start(log.clone(), move |usage, is_down| {
                    *conn.lock().unwrap() = true;
                    let name = config_clone.lock().unwrap()
                        .find_mapping(usage)
                        .map(|m| m.name.clone())
                        .unwrap_or_else(|| format!("0x{:02x}", usage));
                    let action = if is_down { "按下" } else { "松开" };
                    diagnostics::record(&log_clone, format!("按键事件：{} {} (usage=0x{:02X})", name, action, usage));
                    if is_down {
                        km.lock().unwrap().on_key_down(usage);
                    } else {
                        km.lock().unwrap().on_key_up(usage);
                    }
                });
            }

            let state = AppState {
                config,
                key_mapper,
                hid: Arc::new(Mutex::new(Some(hid))),
                connected,
                log,
            };

            app.manage(state);
            diagnostics::record(&app.state::<AppState>().log, "小米超级键盘 Windows 版已启动");
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_config,
            save_config,
            get_status,
            get_log,
            get_diagnostic_log_path,
            set_voice_mode,
            get_voice_modes,
            rescan,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
