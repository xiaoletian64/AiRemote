// diagnostics.rs — 真机验收用的持久化诊断日志。
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

pub type Diagnostics = Arc<Mutex<Vec<String>>>;

const MAX_IN_MEMORY_LINES: usize = 1_000;
const MAX_LOG_BYTES: u64 = 2 * 1024 * 1024;

pub fn new() -> Diagnostics {
    Arc::new(Mutex::new(Vec::new()))
}

pub fn log_path() -> PathBuf {
    let base = std::env::var_os("APPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("MiSuperKeyboard").join("diagnostics.log")
}

pub fn record(log: &Diagnostics, message: impl AsRef<str>) {
    let timestamp = chrono::Local::now().format("%Y-%m-%dT%H:%M:%S%.3f");
    let line = format!("{}  {}", timestamp, message.as_ref());
    log::info!("{}", line);

    if let Ok(mut lines) = log.lock() {
        lines.push(line.clone());
        if lines.len() > MAX_IN_MEMORY_LINES {
            lines.remove(0);
        }
    }

    persist(&line);
}

fn persist(line: &str) {
    let path = log_path();
    let Some(parent) = path.parent() else {
        return;
    };
    if fs::create_dir_all(parent).is_err() {
        return;
    }

    if fs::metadata(&path)
        .map(|m| m.len() > MAX_LOG_BYTES)
        .unwrap_or(false)
    {
        let previous = path.with_file_name("diagnostics.previous.log");
        let _ = fs::remove_file(&previous);
        let _ = fs::rename(&path, previous);
    }

    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "{}", line);
    }
}
