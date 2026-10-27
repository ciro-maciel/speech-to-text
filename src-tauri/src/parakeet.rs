//! Resident Parakeet sidecar (`parakeet/`, Swift + FluidAudio), macOS 14+ on Apple Silicon.
//!
//! NVIDIA Parakeet on the Neural Engine: on 17 minutes of Brazilian Portuguese (FLEURS)
//! it made fewer errors than large-v3-turbo (3.6% against 3.7% on short sentences, 3.5%
//! against 21.6% on two-minute clips, where whisper.cpp dropped whole sentences) while
//! holding ~80 MB instead of ~2 GB. It returns nothing on silence and noise, so it needs
//! no voice detector, and it takes no prompt.
//!
//! The protocol is one JSON object per line on the child's stdin and stdout; see
//! `parakeet/Sources/parakeet-server/main.swift`.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use tauri_plugin_log::log;
use tauri_plugin_shell::process::{CommandChild, CommandEvent};
use tauri_plugin_shell::ShellExt;
use tokio::sync::{mpsc, Mutex};

use crate::whisper_server;

/// The model's name in settings, the model list and the history.
pub const MODEL: &str = "parakeet";
/// FluidAudio names the folder after the Hugging Face repo.
const FOLDER: &str = "parakeet-ultra";
const READY_MARKER: &str = "ready";
const SIDECAR: &str = "parakeet-server";
/// Download size, for the progress line; FluidAudio reports only a fraction.
pub const DOWNLOAD_BYTES: u64 = 643_000_000;

/// Loading compiles the CoreML models on first use after a download (~15 s), then ~1 s.
const STARTUP_TIMEOUT: Duration = Duration::from_secs(120);
const INFERENCE_TIMEOUT: Duration = Duration::from_secs(120);

pub fn model_dir(app: &tauri::AppHandle) -> PathBuf {
    crate::config::get_models_dir(app).join(FOLDER)
}

pub fn is_installed(app: &tauri::AppHandle) -> bool {
    model_dir(app).join(READY_MARKER).exists()
}

/// FluidAudio needs macOS 14 and the sidecar is built for arm64 only.
pub fn is_supported() -> bool {
    static SUPPORTED: OnceLock<bool> = OnceLock::new();
    *SUPPORTED.get_or_init(|| {
        if !cfg!(all(target_os = "macos", target_arch = "aarch64")) {
            return false;
        }
        std::process::Command::new("sw_vers")
            .arg("-productVersion")
            .output()
            .ok()
            .and_then(|o| String::from_utf8_lossy(&o.stdout).split('.').next()?.trim().parse::<u32>().ok())
            .is_some_and(|major| major >= 14)
    })
}

struct Running {
    child: CommandChild,
    lines: mpsc::UnboundedReceiver<String>,
    alive: Arc<AtomicBool>,
}

pub struct ParakeetServer {
    running: Mutex<Option<Running>>,
    // Readable without the async lock, so the exit handler can kill the child mid-startup.
    pid: AtomicU32,
    next_id: AtomicU64,
}

impl ParakeetServer {
    pub fn new() -> Self {
        Self { running: Mutex::new(None), pid: AtomicU32::new(0), next_id: AtomicU64::new(1) }
    }

    /// Load the model and run one throwaway inference, so the first dictation is warm.
    pub async fn preload(&self, app: &tauri::AppHandle) {
        if !is_installed(app) {
            return;
        }
        let started = Instant::now();
        match self.transcribe(app, whisper_server::silent_wav(16000), "pt").await {
            Ok(_) => log::info!("[parakeet] preloaded in {}ms", started.elapsed().as_millis()),
            Err(e) => log::warn!("[parakeet] preload failed: {e}"),
        }
    }

    pub async fn transcribe(&self, app: &tauri::AppHandle, wav: Vec<u8>, language: &str) -> Result<String, String> {
        let mut guard = self.running.lock().await;
        if !guard.as_ref().is_some_and(|r| r.alive.load(Ordering::SeqCst)) {
            if let Some(old) = guard.take() {
                let _ = old.child.kill();
            }
            whisper_server::kill_stale(SIDECAR);
            *guard = Some(spawn(app, &self.pid).await?);
        }
        let running = guard.as_mut().expect("spawned above");

        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let file = std::env::temp_dir().join(format!("speech-to-text-parakeet-{id}.wav"));
        tokio::fs::write(&file, &wav).await.map_err(|e| format!("Failed to write audio file: {e}"))?;
        let request = serde_json::json!({ "id": id, "wav": file, "language": language });
        let result = exchange(running, id, format!("{request}\n")).await;
        let _ = tokio::fs::remove_file(&file).await;
        if result.is_err() && !running.alive.load(Ordering::SeqCst) {
            *guard = None;
        }
        result
    }

    /// Kill the sidecar. Safe to call from the exit handler (no await).
    pub fn stop(&self) {
        if let Ok(mut guard) = self.running.try_lock() {
            if let Some(r) = guard.take() {
                let _ = r.child.kill();
                self.pid.store(0, Ordering::SeqCst);
                return;
            }
        }
        whisper_server::kill_pid(self.pid.swap(0, Ordering::SeqCst));
    }
}

async fn exchange(running: &mut Running, id: u64, request: String) -> Result<String, String> {
    running
        .child
        .write(request.as_bytes())
        .map_err(|e| format!("parakeet-server write failed: {e}"))?;
    let deadline = Instant::now() + INFERENCE_TIMEOUT;
    loop {
        let line = tokio::time::timeout_at(tokio::time::Instant::from_std(deadline), running.lines.recv())
            .await
            .map_err(|_| "parakeet-server timed out".to_string())?
            .ok_or_else(|| "parakeet-server exited".to_string())?;
        let Ok(reply) = serde_json::from_str::<serde_json::Value>(&line) else { continue };
        if reply["id"].as_u64() != Some(id) {
            continue;
        }
        if let Some(err) = reply["error"].as_str() {
            return Err(format!("parakeet-server: {err}"));
        }
        return reply["text"]
            .as_str()
            .map(str::to_string)
            .ok_or_else(|| "parakeet-server returned no text".to_string());
    }
}

async fn spawn(app: &tauri::AppHandle, pid: &AtomicU32) -> Result<Running, String> {
    let started = Instant::now();
    let (mut rx, child) = app
        .shell()
        .sidecar(SIDECAR)
        .map_err(|e| format!("parakeet-server sidecar not found: {e}"))?
        .args(["--model-dir".to_string(), model_dir(app).to_string_lossy().to_string()])
        .spawn()
        .map_err(|e| format!("Failed to spawn parakeet-server: {e}"))?;
    pid.store(child.pid(), Ordering::SeqCst);
    whisper_server::write_pid_file(SIDECAR, child.pid());
    whisper_server::watch_parent(child.pid());

    // Forward stdout lines and notice if the child dies, so the next dictation restarts it.
    let alive = Arc::new(AtomicBool::new(true));
    let flag = alive.clone();
    let (tx, mut lines) = mpsc::unbounded_channel();
    tauri::async_runtime::spawn(async move {
        while let Some(event) = rx.recv().await {
            match event {
                CommandEvent::Stdout(bytes) => {
                    let _ = tx.send(String::from_utf8_lossy(&bytes).trim().to_string());
                }
                CommandEvent::Stderr(bytes) => {
                    log::warn!("[parakeet] {}", String::from_utf8_lossy(&bytes).trim());
                }
                CommandEvent::Terminated(payload) => {
                    log::warn!("[parakeet] exited: code={:?}", payload.code);
                    break;
                }
                _ => {}
            }
        }
        flag.store(false, Ordering::SeqCst);
    });

    let deadline = Instant::now() + STARTUP_TIMEOUT;
    loop {
        let line = match tokio::time::timeout_at(tokio::time::Instant::from_std(deadline), lines.recv()).await {
            Ok(Some(line)) => line,
            Ok(None) => return Err("parakeet-server exited during startup".to_string()),
            Err(_) => {
                let _ = child.kill();
                return Err("parakeet-server startup timed out".to_string());
            }
        };
        let ready = serde_json::from_str::<serde_json::Value>(&line)
            .is_ok_and(|v| v["event"].as_str() == Some("ready"));
        if ready {
            break;
        }
    }

    log::info!("[parakeet] ready in {}ms", started.elapsed().as_millis());
    Ok(Running { child, lines, alive })
}

/// Download (and compile) the model through the sidecar, reporting a 0–1 fraction.
/// Returns early with "Download cancelled" when `cancel` is set.
pub async fn download(
    app: &tauri::AppHandle,
    cancel: Arc<AtomicBool>,
    mut progress: impl FnMut(f64),
) -> Result<PathBuf, String> {
    let dir = model_dir(app);
    let (mut rx, child) = app
        .shell()
        .sidecar(SIDECAR)
        .map_err(|e| format!("parakeet-server sidecar not found: {e}"))?
        .args(["--download".to_string(), "--model-dir".to_string(), dir.to_string_lossy().to_string()])
        .spawn()
        .map_err(|e| format!("Failed to spawn parakeet-server: {e}"))?;

    let mut stderr = String::new();
    let mut code = None;
    while let Some(event) = rx.recv().await {
        if cancel.load(Ordering::Relaxed) {
            let _ = child.kill();
            let _ = tokio::fs::remove_dir_all(&dir).await;
            return Err("Download cancelled".to_string());
        }
        match event {
            CommandEvent::Stdout(bytes) => {
                if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&bytes) {
                    if let Some(f) = v["fraction"].as_f64() {
                        progress(f);
                    }
                }
            }
            CommandEvent::Stderr(bytes) => stderr.push_str(&String::from_utf8_lossy(&bytes)),
            CommandEvent::Terminated(payload) => code = payload.code,
            _ => {}
        }
    }
    if code != Some(0) || !is_installed(app) {
        let detail = stderr.lines().rev().find(|l| l.contains("parakeet-server:")).unwrap_or("").trim();
        return Err(if detail.is_empty() { format!("exit {code:?}") } else { detail.to_string() });
    }
    Ok(dir)
}

/// Size of the downloaded model folder.
pub fn installed_size(app: &tauri::AppHandle) -> u64 {
    fn walk(path: &std::path::Path) -> u64 {
        std::fs::read_dir(path)
            .map(|entries| {
                entries
                    .flatten()
                    .map(|e| match e.metadata() {
                        Ok(m) if m.is_dir() => walk(&e.path()),
                        Ok(m) => m.len(),
                        Err(_) => 0,
                    })
                    .sum()
            })
            .unwrap_or(0)
    }
    walk(&model_dir(app))
}
