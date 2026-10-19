//! Resident whisper.cpp server.
//!
//! Spawning `whisper-cli` per dictation reloads the whole model every time:
//! ~0.6s when the weights are in the OS page cache, ~8s once macOS evicts the
//! 1.6 GB large-v3-turbo file after a while idle. That was the "sometimes it
//! takes forever". `whisper-server` loads the model once and keeps it on the
//! GPU, so each dictation pays only for inference (~0.6s for 10s of speech).

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use tauri::Manager;
use tauri_plugin_log::log;
use tauri_plugin_shell::process::{CommandChild, CommandEvent};
use tauri_plugin_shell::ShellExt;
use tokio::sync::Mutex;

/// A cold start reads the model from disk — generous for 1.6 GB on slow disks.
const STARTUP_TIMEOUT: Duration = Duration::from_secs(90);
const INFERENCE_TIMEOUT: Duration = Duration::from_secs(120);

/// Silero voice-activity model, bundled as a resource. Whisper hallucinates
/// on silence ("Legenda por…", "Acesse o nosso site.", bits of the prompt);
/// with VAD, a press with no speech comes back empty and nothing is pasted.
const VAD_MODEL: &str = "ggml-silero-v6.2.0.bin";

/// Tuned so one-word answers ("Sim.", "Não.", "Ok.") still pass while silence,
/// room noise and keyboard clicks come back empty. The defaults (0.5 / 250ms)
/// dropped a short "Sim.".
pub const VAD_THRESHOLD: &str = "0.35";
pub const VAD_MIN_SPEECH_MS: &str = "100";
pub const VAD_SPEECH_PAD_MS: &str = "200";

pub fn vad_model_path(app: &tauri::AppHandle) -> Option<PathBuf> {
    app.path()
        .resolve(VAD_MODEL, tauri::path::BaseDirectory::Resource)
        .ok()
        .filter(|p| p.exists())
}

struct Running {
    child: CommandChild,
    port: u16,
    model: PathBuf,
    vad: bool,
    alive: Arc<AtomicBool>,
}

pub struct WhisperServer {
    running: Mutex<Option<Running>>,
    // Mirror of the running child's pid, readable without the async lock so
    // the app can kill the server on exit even mid-startup.
    pid: AtomicU32,
    client: reqwest::Client,
}

#[derive(serde::Deserialize)]
struct InferenceResponse {
    text: Option<String>,
    error: Option<String>,
}

impl WhisperServer {
    pub fn new() -> Self {
        Self {
            running: Mutex::new(None),
            pid: AtomicU32::new(0),
            client: reqwest::Client::builder()
                .no_proxy()
                .build()
                .expect("Failed to build local HTTP client"),
        }
    }

    /// Load `model` and run a throwaway inference so the first real dictation
    /// doesn't pay for Metal pipeline compilation. Called at startup and when
    /// the user switches models.
    pub async fn preload(&self, app: &tauri::AppHandle, model: &Path) {
        if !model.exists() {
            return;
        }
        let started = Instant::now();
        let silence = silent_wav(16000);
        match self.transcribe(app, model, silence, "pt", "", false).await {
            Ok(_) => log::info!(
                "[whisper-server] preloaded {} in {}ms",
                model.display(),
                started.elapsed().as_millis()
            ),
            Err(e) => log::warn!("[whisper-server] preload failed: {e}"),
        }
    }

    pub async fn transcribe(
        &self,
        app: &tauri::AppHandle,
        model: &Path,
        wav: Vec<u8>,
        language: &str,
        prompt: &str,
        voice_detection: bool,
    ) -> Result<String, String> {
        let (port, has_vad) = self.ensure(app, model).await?;
        let vad = has_vad && voice_detection;

        let file = reqwest::multipart::Part::bytes(wav)
            .file_name("audio.wav")
            .mime_str("audio/wav")
            .map_err(|e| e.to_string())?;
        let form = reqwest::multipart::Form::new()
            .part("file", file)
            .text("language", language.to_string())
            .text("prompt", prompt.to_string())
            .text("response_format", "json")
            .text("no_timestamps", "true")
            // Same decoder as whisper-cli's defaults; the server defaults to greedy.
            .text("beam_size", "5")
            .text("best_of", "5");
        let form = if vad {
            form.text("vad", "true")
                .text("vad_threshold", VAD_THRESHOLD)
                .text("vad_min_speech_duration_ms", VAD_MIN_SPEECH_MS)
                .text("vad_speech_pad_ms", VAD_SPEECH_PAD_MS)
        } else {
            form
        };

        let response = self
            .client
            .post(format!("http://127.0.0.1:{port}/inference"))
            .multipart(form)
            .timeout(INFERENCE_TIMEOUT)
            .send()
            .await
            .map_err(|e| format!("whisper-server request failed: {e}"))?;

        let status = response.status();
        let body: InferenceResponse = response
            .json()
            .await
            .map_err(|e| format!("whisper-server bad response ({status}): {e}"))?;

        if let Some(err) = body.error {
            return Err(format!("whisper-server: {err}"));
        }
        body.text.ok_or_else(|| "whisper-server returned no text".to_string())
    }

    /// Kill the server. Safe to call from the exit handler (no await).
    pub fn stop(&self) {
        if let Ok(mut guard) = self.running.try_lock() {
            if let Some(r) = guard.take() {
                let _ = r.child.kill();
                self.pid.store(0, Ordering::SeqCst);
                return;
            }
        }
        kill_pid(self.pid.swap(0, Ordering::SeqCst));
    }

    /// Port of a live server holding `model`, (re)starting it if needed.
    /// The lock serializes callers, so a dictation during startup waits for
    /// the load already in progress instead of spawning a second server.
    async fn ensure(&self, app: &tauri::AppHandle, model: &Path) -> Result<(u16, bool), String> {
        let mut guard = self.running.lock().await;
        if let Some(r) = guard.as_ref() {
            if r.model == model && r.alive.load(Ordering::SeqCst) {
                return Ok((r.port, r.vad));
            }
        }
        if let Some(old) = guard.take() {
            let _ = old.child.kill();
        }
        kill_stale_server();

        let running = spawn(app, model, &self.pid).await?;
        let ready = (running.port, running.vad);
        *guard = Some(running);
        Ok(ready)
    }
}

async fn spawn(app: &tauri::AppHandle, model: &Path, pid: &AtomicU32) -> Result<Running, String> {
    let port = free_port()?;
    let started = Instant::now();

    let mut args = vec![
        "-m".to_string(),
        model.to_string_lossy().to_string(),
        "--host".to_string(),
        "127.0.0.1".to_string(),
        "--port".to_string(),
        port.to_string(),
    ];
    let vad_model = vad_model_path(app);
    if let Some(vad) = &vad_model {
        args.push("--vad-model".to_string());
        args.push(vad.to_string_lossy().to_string());
    } else {
        log::warn!("[whisper-server] VAD model not found — silence may be transcribed");
    }

    let (mut rx, child) = app
        .shell()
        .sidecar("whisper-server")
        .map_err(|e| format!("whisper-server sidecar not found: {e}"))?
        .args(args)
        .spawn()
        .map_err(|e| format!("Failed to spawn whisper-server: {e}"))?;
    pid.store(child.pid(), Ordering::SeqCst);
    write_pid_file(child.pid());
    watch_parent(child.pid());

    // Drain the output (the server logs every request) and notice if it dies,
    // so the next dictation restarts it instead of hitting a dead port.
    let alive = Arc::new(AtomicBool::new(true));
    let flag = alive.clone();
    tauri::async_runtime::spawn(async move {
        while let Some(event) = rx.recv().await {
            if let CommandEvent::Terminated(payload) = event {
                log::warn!("[whisper-server] exited: code={:?}", payload.code);
                break;
            }
        }
        flag.store(false, Ordering::SeqCst);
    });

    // The HTTP listener only opens after the model is loaded.
    loop {
        if !alive.load(Ordering::SeqCst) {
            return Err("whisper-server exited during startup".to_string());
        }
        if tokio::net::TcpStream::connect(("127.0.0.1", port)).await.is_ok() {
            break;
        }
        if started.elapsed() > STARTUP_TIMEOUT {
            let _ = child.kill();
            return Err("whisper-server startup timed out".to_string());
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }

    log::info!(
        "[whisper-server] {} ready on :{port} in {}ms",
        model.display(),
        started.elapsed().as_millis()
    );
    Ok(Running { child, port, model: model.to_path_buf(), vad: vad_model.is_some(), alive })
}

fn free_port() -> Result<u16, String> {
    std::net::TcpListener::bind(("127.0.0.1", 0))
        .and_then(|l| l.local_addr())
        .map(|a| a.port())
        .map_err(|e| format!("No free port for whisper-server: {e}"))
}

/// 16 kHz mono 16-bit WAV of `samples` zeros.
fn silent_wav(samples: u32) -> Vec<u8> {
    let data_len = samples * 2;
    let mut wav = Vec::with_capacity(44 + data_len as usize);
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data_len).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes()); // PCM
    wav.extend_from_slice(&1u16.to_le_bytes()); // mono
    wav.extend_from_slice(&16000u32.to_le_bytes());
    wav.extend_from_slice(&32000u32.to_le_bytes());
    wav.extend_from_slice(&2u16.to_le_bytes());
    wav.extend_from_slice(&16u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_len.to_le_bytes());
    wav.resize(44 + data_len as usize, 0);
    wav
}

// ── Orphan cleanup ──────────────────────────────────────────────────────
// If the app dies without running its exit handler (crash, updater restart),
// the server would linger holding ~2 GB. We record its pid and kill it on the
// next start, after checking the pid still belongs to a whisper-server.

fn pid_file() -> PathBuf {
    std::env::temp_dir().join("speech-to-text-whisper-server.pid")
}

fn write_pid_file(pid: u32) {
    let _ = std::fs::write(pid_file(), pid.to_string());
}

fn kill_stale_server() {
    let Some(pid) = std::fs::read_to_string(pid_file())
        .ok()
        .and_then(|s| s.trim().parse::<u32>().ok())
    else {
        return;
    };
    let _ = std::fs::remove_file(pid_file());

    #[cfg(unix)]
    {
        let comm = std::process::Command::new("ps")
            .args(["-p", &pid.to_string(), "-o", "comm="])
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
            .unwrap_or_default();
        if comm.contains("whisper-server") {
            kill_pid(pid);
        }
    }
    #[cfg(windows)]
    {
        let image = crate::process::command("tasklist")
            .args(["/FI", &format!("PID eq {pid}"), "/FO", "CSV", "/NH"])
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
            .unwrap_or_default();
        if image.contains("whisper-server") {
            kill_pid(pid);
        }
    }
}

/// The exit handler doesn't run on a force quit or a signal, so a tiny
/// watchdog kills the server as soon as the app process is gone.
fn watch_parent(server_pid: u32) {
    #[cfg(unix)]
    {
        let script = format!(
            "while kill -0 {app} 2>/dev/null && kill -0 {server} 2>/dev/null; do sleep 2; done; kill {server} 2>/dev/null",
            app = std::process::id(),
            server = server_pid,
        );
        let _ = std::process::Command::new("sh")
            .args(["-c", &script])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .map(|mut watchdog| std::thread::spawn(move || watchdog.wait()));
    }
    #[cfg(not(unix))]
    let _ = server_pid;
}

fn kill_pid(pid: u32) {
    if pid == 0 {
        return;
    }
    #[cfg(unix)]
    let _ = std::process::Command::new("kill").arg(pid.to_string()).status();
    #[cfg(windows)]
    let _ = crate::process::command("taskkill")
        .args(["/PID", &pid.to_string(), "/F"])
        .status();
}
