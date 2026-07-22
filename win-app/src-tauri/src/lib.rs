// lib.rs — Tauri 应用入口，串联所有模块
mod config;
mod hid;
mod mapping;
mod adpcm;
mod dsp;

use config::{Config, VoiceMode};
use mapping::KeyMapper;
use hid::HidListener;
use std::sync::{Arc, Mutex};
use tauri::State;

/// 应用状态
struct AppState {
    config: Arc<Mutex<Config>>,
    key_mapper: Arc<Mutex<KeyMapper>>,
    hid: Arc<Mutex<Option<HidListener>>>,
    connected: Arc<Mutex<bool>>,
    log: Arc<Mutex<Vec<String>>>,
}

/// 日志辅助
fn log_msg(state: &AppState, msg: String) {
    let timestamp = chrono::Local::now().format("%Y-%m-%dT%H:%M:%S%.3f");
    let line = format!("{}  {}", timestamp, msg);
    log::info!("{}", line);
    let mut log = state.log.lock().unwrap();
    log.push(line);
    if log.len() > 200 { log.remove(0); }
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
fn rescan(state: State<AppState>) {
    log_msg(&state, "重新扫描设备…".to_string());
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

            // 系统托盘：App 在后台运行时不抢焦点，让 enigo 的 SendInput 能到前台窗口
            let tray = tauri::tray::TrayIconBuilder::with_id("main-tray")
                .tooltip("小米超级键盘")
                .icon(app.default_window_icon().unwrap().clone())
                .menu(&tauri::menu::Menu::with_items(
                    app,
                    &[
                        &tauri::menu::MenuItem::with_id(app, "show", "显示主窗口", true, None::<&str>)?,
                        &tauri::menu::MenuItem::with_id(app, "quit", "退出", true, None::<&str>)?,
                    ],
                )?)
                .on_menu_event(|app, event| {
                    match event.id().as_ref() {
                        "show" => {
                            if let Some(window) = app.get_webview_window("main") {
                                let _ = window.show();
                                let _ = window.set_focus();
                            }
                        }
                        "quit" => { app.exit(0); }
                        _ => {}
                    }
                })
                .on_tray_icon_event(|tray, event| {
                    if let tauri::tray::TrayIconEvent::Click { button: tauri::tray::MouseButton::Left, .. } = event {
                        let app = tray.app_handle();
                        if let Some(window) = app.get_webview_window("main") {
                            if window.is_visible().unwrap_or(false) {
                                let _ = window.hide();
                            } else {
                                let _ = window.show();
                                let _ = window.set_focus();
                            }
                        }
                    }
                })
                .build(app)?;
            let _ = tray; // 保持托盘存活

            // 初始化配置
            let config = Arc::new(Mutex::new(Config::load()));
            let key_mapper = Arc::new(Mutex::new(KeyMapper::new(config.clone())));
            let connected = Arc::new(Mutex::new(false));
            let log = Arc::new(Mutex::new(Vec::new()));

            // 启动 HID 监听
            let mut hid = HidListener::new();
            let km = key_mapper.clone();
            let conn = connected.clone();
            {
                let config_clone = config.clone();
                let log_clone = log.clone();
                hid.start(move |usage, is_down| {
                    *conn.lock().unwrap() = true;
                    let name = config_clone.lock().unwrap()
                        .find_mapping(usage)
                        .map(|m| m.name.clone())
                        .unwrap_or_else(|| format!("0x{:02x}", usage));
                    let action = if is_down { "按下" } else { "松开" };
                    log_clone.lock().unwrap().push(format!(
                        "{}  {} {}",
                        chrono::Local::now().format("%Y-%m-%dT%H:%M:%S%.3f"),
                        name, action
                    ));
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
            log::info!("小米超级键盘 Windows 版已启动");
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_config,
            save_config,
            get_status,
            get_log,
            set_voice_mode,
            get_voice_modes,
            rescan,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
