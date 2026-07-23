// lib.rs — Tauri 应用入口，串联所有模块
mod adpcm;
mod audio;
mod ble;
mod config;
mod diagnostics;
mod dsp;
mod hid;
mod mapping;
#[cfg(windows)]
mod raw_input;
mod voice_keys;

use config::{Config, VoiceMode};
use diagnostics::Diagnostics;
use hid::HidListener;
use mapping::KeyMapper;
#[cfg(windows)]
use raw_input::RawInputListener;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use tauri::{Manager, State};

/// 应用状态
struct AppState {
    config: Arc<Mutex<Config>>,
    key_mapper: Arc<Mutex<KeyMapper>>,
    hid: Arc<Mutex<Option<HidListener>>>,
    connected: Arc<Mutex<bool>>,
    log: Diagnostics,
    #[cfg(windows)]
    raw_input: RawInputListener,
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
    VoiceMode::all()
        .iter()
        .map(|m| {
            let value = serde_json::to_string(m)
                .unwrap_or_default()
                .trim_matches('"')
                .to_string();
            (value, m.label().to_string(), m.detail().to_string())
        })
        .collect()
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

            // 系统托盘：App 在后台运行时不抢焦点，让 enigo 的 SendInput 能到前台窗口
            let tray = tauri::tray::TrayIconBuilder::with_id("main-tray")
                .tooltip("小米超级键盘")
                .icon(app.default_window_icon().unwrap().clone())
                .menu(&tauri::menu::Menu::with_items(
                    app,
                    &[
                        &tauri::menu::MenuItem::with_id(
                            app,
                            "show",
                            "显示主窗口",
                            true,
                            None::<&str>,
                        )?,
                        &tauri::menu::MenuItem::with_id(app, "quit", "退出", true, None::<&str>)?,
                    ],
                )?)
                .on_menu_event(|app, event| match event.id().as_ref() {
                    "show" => {
                        if let Some(window) = app.get_webview_window("main") {
                            let _ = window.show();
                            let _ = window.set_focus();
                        }
                    }
                    "quit" => {
                        app.exit(0);
                    }
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let tauri::tray::TrayIconEvent::Click {
                        button: tauri::tray::MouseButton::Left,
                        ..
                    } = event
                    {
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
            let log = diagnostics::new();
            diagnostics::record(
                &log,
                format!(
                    "应用启动：version={} os={} arch={} diagnostics={}",
                    env!("CARGO_PKG_VERSION"),
                    std::env::consts::OS,
                    std::env::consts::ARCH,
                    diagnostics::log_path().display()
                ),
            );

            // 启动 HID 监听
            let mut hid = HidListener::new();
            let km = key_mapper.clone();
            let conn = connected.clone();
            {
                let config_clone = config.clone();
                let log_clone = log.clone();
                hid.start(log.clone(), move |usage, is_down| {
                    *conn.lock().unwrap() = true;
                    let name = config_clone
                        .lock()
                        .unwrap()
                        .find_mapping(usage)
                        .map(|m| m.name.clone())
                        .unwrap_or_else(|| format!("0x{:02x}", usage));
                    let action = if is_down { "按下" } else { "松开" };
                    diagnostics::record(
                        &log_clone,
                        format!("按键事件：{} {} (usage=0x{:02X})", name, action, usage),
                    );
                    if is_down {
                        km.lock().unwrap().on_key_down(usage);
                    } else {
                        km.lock().unwrap().on_key_up(usage);
                    }
                });
            }

            // RC003 的键盘 HID 可能被 Windows 独占，hidapi 无法读取；Raw Input
            // 仍可收到系统分发的 F5/usage 0x3E 语音键，不影响普通键盘。
            #[cfg(windows)]
            let raw_input = {
                let km = key_mapper.clone();
                let log_clone = log.clone();
                RawInputListener::start(Arc::new(move |usage, is_down| {
                    diagnostics::record(
                        &log_clone,
                        format!(
                            "Raw Input 语音键：{} (usage=0x{:02X})",
                            if is_down { "按下" } else { "松开" },
                            usage
                        ),
                    );
                    if is_down {
                        km.lock().unwrap().on_key_down(usage);
                    } else {
                        km.lock().unwrap().on_key_up(usage);
                    }
                }))
            };

            // 启动 BLE 语音 + 音频输出
            // 音频：初始化 ring buffer + cpal 输出（VB-Cable 或默认设备）
            let audio_out = match audio::AudioOut::new() {
                Ok(ao) => {
                    diagnostics::record(
                        &log,
                        format!(
                            "✅ 音频输出已启动：{}（VB-Cable: {}）",
                            ao.device_name,
                            if ao.using_vbcable {
                                "已检测到"
                            } else {
                                "未检测到，语音只会输出到默认扬声器"
                            }
                        ),
                    );
                    diagnostics::record(
                        &log,
                        format!(
                            "音频格式：{}Hz / {} 声道（源音频：16000Hz / 1 声道，已自动转换）",
                            ao.sample_rate, ao.channels
                        ),
                    );
                    Some(ao)
                }
                Err(e) => {
                    diagnostics::record(
                        &log,
                        format!("⚠️ 音频输出初始化失败: {}（语音转发不可用）", e),
                    );
                    None
                }
            };

            // BLE 语音：在 tokio runtime 中异步运行
            if let Some(ref ao) = audio_out {
                let ring = ao.ring.clone();
                let log_for_ble = log.clone();
                let using_vbcable = ao.using_vbcable;

                // 用独立线程跑 tokio runtime（不阻塞 Tauri 主线程）
                std::thread::spawn(move || {
                    let rt = tokio::runtime::Runtime::new().expect("无法创建 tokio runtime");
                    rt.block_on(async {
                        let ble = ble::BleVoice::new();
                        // 同一个实例同时处理控制通知、音频帧和麦克风转发状态。
                        ble.mic_streaming.store(using_vbcable, Ordering::Relaxed);
                        ble.run(
                            ring,
                            Arc::new(move |msg| {
                                diagnostics::record(&log_for_ble, msg.to_string());
                            }),
                        )
                        .await;
                    });
                });
                diagnostics::record(
                    &log,
                    format!(
                        "BLE 语音已启动（VB-Cable: {}）",
                        if using_vbcable {
                            "已检测到，语音会转入虚拟麦克风"
                        } else {
                            "未检测到，麦克风转发已禁用"
                        }
                    ),
                );
            } else {
                diagnostics::record(&log, "BLE 语音未启动（音频输出不可用）".to_string());
            }

            let state = AppState {
                config,
                key_mapper,
                hid: Arc::new(Mutex::new(Some(hid))),
                connected,
                log,
                #[cfg(windows)]
                raw_input,
            };

            app.manage(state);
            diagnostics::record(
                &app.state::<AppState>().log,
                "小米超级键盘 Windows 版已启动",
            );
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
