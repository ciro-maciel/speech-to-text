use std::path::PathBuf;
#[cfg(target_os = "linux")]
use std::process::Command;
use tauri_plugin_log::log;
use tauri_plugin_shell::ShellExt;
use tauri_plugin_shell::process::CommandEvent;
use tokio::fs;

use crate::whisper_server::{self, WhisperServer};

/// User settings that change how a clip is transcribed.
#[derive(Clone, Copy)]
pub struct TranscribeOptions {
    /// Use the resident whisper-server; off means one-shot whisper-cli.
    pub use_server: bool,
    /// Drop silence and noise with the Silero voice detector.
    pub voice_detection: bool,
}

pub struct WhisperTranscription {
    pub text: String,
    pub is_noise: bool,
}

pub async fn transcribe_audio(
    app: &tauri::AppHandle,
    server: &WhisperServer,
    model_path: &PathBuf,
    audio_data: Vec<u8>,
    language: &str,
    prompt: &str,
    opts: TranscribeOptions,
) -> Result<WhisperTranscription, String> {
    if audio_data.len() < 1000 {
        return Err("Audio file too small, likely silence".to_string());
    }

    // Resident server first; the one-shot CLI stays as the safety net so a
    // server problem costs speed, never the dictation.
    let raw = if opts.use_server {
        match server
            .transcribe(app, model_path, audio_data.clone(), language, prompt, opts.voice_detection)
            .await
        {
            Ok(text) => text,
            Err(e) => {
                log::warn!("[whisper] server failed ({e}) — falling back to whisper-cli");
                transcribe_with_cli(app, model_path, audio_data, language, prompt, opts.voice_detection).await?
            }
        }
    } else {
        transcribe_with_cli(app, model_path, audio_data, language, prompt, opts.voice_detection).await?
    };

    // Segments come back one per line; a dictation is pasted as running text.
    let text = raw.split_whitespace().collect::<Vec<_>>().join(" ");

    // Whisper sometimes emits placeholder annotations (e.g. "[música]",
    // "[silence]") when the input is silent or noise. Only treat the output
    // as noise if the *entire* transcription is one of these placeholders —
    // a substring match wrongly filters real speech that happens to mention
    // "música", "music", subtitles, etc.
    let trimmed = text.trim().trim_matches(|c: char| c == '.' || c.is_whitespace());
    let normalized = trimmed.to_lowercase();
    let placeholder_patterns = [
        "", "[música]", "[música de fundo]", "[fundo]",
        "[music]", "(music)", "[silence]", "[silêncio]",
        "[ruído]", "[noise]", "(silence)", "[blank_audio]",
        "[ Silence ]", "[silent]",
    ];
    let is_noise = placeholder_patterns.iter().any(|p| normalized == p.to_lowercase());

    Ok(WhisperTranscription { text, is_noise })
}

async fn transcribe_with_cli(
    app: &tauri::AppHandle,
    model_path: &PathBuf,
    audio_data: Vec<u8>,
    language: &str,
    prompt: &str,
    voice_detection: bool,
) -> Result<String, String> {
    let audio_file = std::env::temp_dir().join("recording.wav");

    fs::write(&audio_file, &audio_data)
        .await
        .map_err(|e| format!("Failed to write audio file: {}", e))?;

    // Spawn the bundled whisper-cli sidecar. ShellExt::sidecar resolves
    // the target-triple-suffixed binary (whisper-cli-x86_64-pc-windows-msvc.exe
    // etc.) that tauri-action shipped in the bundle — using plain
    // std::process::Command + a hand-rolled path resolver doesn't work
    // because the path layout differs between dev/install on each OS.
    let sidecar = app
        .shell()
        .sidecar("whisper-cli")
        .map_err(|e| format!("whisper-cli sidecar not found: {e}"))?;

    let mut args: Vec<String> = [
        "-m",
        &model_path.to_string_lossy(),
        "-f",
        &audio_file.to_string_lossy(),
        "-l",
        language,
        "--prompt",
        prompt,
        "-nt",
        "--no-prints",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    if let Some(vad) = whisper_server::vad_model_path(app).filter(|_| voice_detection) {
        args.extend(
            [
                "--vad",
                "-vm",
                &vad.to_string_lossy(),
                "-vt",
                whisper_server::VAD_THRESHOLD,
                "-vspd",
                whisper_server::VAD_MIN_SPEECH_MS,
                "-vp",
                whisper_server::VAD_SPEECH_PAD_MS,
            ]
            .iter()
            .map(|s| s.to_string()),
        );
    }

    let (mut rx, _child) = sidecar
        .args(args)
        .spawn()
        .map_err(|e| format!("Failed to spawn whisper-cli: {e}"))?;

    let mut stdout = String::new();
    let mut stderr = String::new();
    let mut exit_code: Option<i32> = None;

    while let Some(event) = rx.recv().await {
        match event {
            CommandEvent::Stdout(bytes) => {
                stdout.push_str(&String::from_utf8_lossy(&bytes));
                stdout.push('\n');
            }
            CommandEvent::Stderr(bytes) => {
                stderr.push_str(&String::from_utf8_lossy(&bytes));
                stderr.push('\n');
            }
            CommandEvent::Terminated(payload) => {
                exit_code = payload.code;
            }
            _ => {}
        }
    }

    let _ = fs::remove_file(&audio_file).await;

    if exit_code != Some(0) {
        eprintln!(
            "[whisper] model={:?} audio={:?} exit={:?}\nstdout={}\nstderr={}",
            model_path, audio_file, exit_code, stdout, stderr
        );
        return Err(format!("whisper.cpp failed: {}", stderr.trim()));
    }

    Ok(stdout)
}

/// Returned by `paste_text_via_clipboard` when the OS blocks synthetic
/// keystrokes (macOS Accessibility off). The text is left on the clipboard.
pub const PASTE_NEEDS_PERMISSION: &str = "paste-needs-permission";

/// Paste `text` into the frontmost app via clipboard + paste keystroke.
///
/// Per platform:
/// - **macOS**: clipboard via the Tauri plugin, then ⌘V posted with
///   CGEventPost. Needs only Accessibility (osascript also needed Automation
///   and cost ~250ms per paste).
/// - **Windows**: Tauri clipboard plugin to set text, PowerShell SendKeys
///   for Ctrl+V (no extra dependency), background restore.
/// - **Linux**: detect X11 vs Wayland via `XDG_SESSION_TYPE`, then use
///   `xdotool` (X11) or `wtype`/`ydotool` (Wayland). Falls back gracefully
///   if the helper tool isn't installed — the text is still on the clipboard
///   so the user can press Ctrl+V manually.
///
/// Returns as soon as the paste keystroke is dispatched; clipboard restore
/// happens in a background task.
pub async fn paste_text_via_clipboard(app: &tauri::AppHandle, text: &str) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    { paste_macos(app, text).await }

    #[cfg(target_os = "windows")]
    { paste_windows(app, text).await }

    #[cfg(target_os = "linux")]
    { paste_linux(app, text).await }

    #[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
    {
        let _ = (app, text);
        Err("Auto-paste not supported on this platform".to_string())
    }
}

// ───────────────────────────── macOS ─────────────────────────────
#[cfg(target_os = "macos")]
async fn paste_macos(app: &tauri::AppHandle, text: &str) -> Result<(), String> {
    use tauri_plugin_clipboard_manager::ClipboardExt;

    let saved = app.clipboard().read_text().ok();
    app.clipboard()
        .write_text(text.to_string())
        .map_err(|e| format!("clipboard write failed: {e}"))?;

    if !crate::permissions::is_paste_trusted() {
        return Err(PASTE_NEEDS_PERMISSION.to_string());
    }

    // Let the pasteboard settle before the destination reads it.
    tokio::time::sleep(std::time::Duration::from_millis(30)).await;
    post_command_v()?;

    if let Some(prior) = saved {
        if !prior.is_empty() && prior != text {
            let app2 = app.clone();
            tokio::spawn(async move {
                tokio::time::sleep(std::time::Duration::from_millis(400)).await;
                let _ = app2.clipboard().write_text(prior);
            });
        }
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn post_command_v() -> Result<(), String> {
    use core_graphics::event::{CGEvent, CGEventFlags, CGEventTapLocation, CGKeyCode};
    use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};

    // Virtual key code for "V" on ANSI/ISO layouts (ABNT2 included).
    const KEY_V: CGKeyCode = 9;
    let source = CGEventSource::new(CGEventSourceStateID::HIDSystemState)
        .map_err(|_| "CGEventSource unavailable".to_string())?;
    for key_down in [true, false] {
        let event = CGEvent::new_keyboard_event(source.clone(), KEY_V, key_down)
            .map_err(|_| "CGEvent creation failed".to_string())?;
        event.set_flags(CGEventFlags::CGEventFlagCommand);
        event.post(CGEventTapLocation::HID);
    }
    Ok(())
}

// ───────────────────────────── Windows ─────────────────────────────
#[cfg(target_os = "windows")]
async fn paste_windows(app: &tauri::AppHandle, text: &str) -> Result<(), String> {
    use tauri_plugin_clipboard_manager::ClipboardExt;

    // Capture the old clipboard (best effort — may be empty / non-text).
    let saved = app.clipboard().read_text().ok();

    app.clipboard()
        .write_text(text.to_string())
        .map_err(|e| format!("clipboard write failed: {e}"))?;

    // Small delay so the clipboard write settles before we fire Ctrl+V.
    tokio::time::sleep(std::time::Duration::from_millis(80)).await;

    send_ctrl_v()?;

    // Restore prior clipboard in background.
    if let Some(prior) = saved {
        if !prior.is_empty() {
            let app2 = app.clone();
            tokio::spawn(async move {
                tokio::time::sleep(std::time::Duration::from_millis(300)).await;
                let _ = app2.clipboard().write_text(prior);
            });
        }
    }
    Ok(())
}

/// Ctrl+V to the foreground window through SendInput: instant, no child
/// process. (PowerShell SendKeys cost 0.3–0.8 s per paste and flashed a window.)
#[cfg(target_os = "windows")]
fn send_ctrl_v() -> Result<(), String> {
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
        SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP, VIRTUAL_KEY, VK_CONTROL,
    };
    const VK_V: VIRTUAL_KEY = 0x56;
    let key = |vk: VIRTUAL_KEY, up: bool| INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT { wVk: vk, wScan: 0, dwFlags: if up { KEYEVENTF_KEYUP } else { 0 }, time: 0, dwExtraInfo: 0 },
        },
    };
    let inputs = [key(VK_CONTROL, false), key(VK_V, false), key(VK_V, true), key(VK_CONTROL, true)];
    let sent = unsafe { SendInput(inputs.len() as u32, inputs.as_ptr(), std::mem::size_of::<INPUT>() as i32) };
    if sent as usize != inputs.len() {
        return Err("Ctrl+V could not be sent (SendInput was blocked)".to_string());
    }
    Ok(())
}

// ───────────────────────────── Linux ─────────────────────────────
#[cfg(target_os = "linux")]
async fn paste_linux(app: &tauri::AppHandle, text: &str) -> Result<(), String> {
    use tauri_plugin_clipboard_manager::ClipboardExt;

    let saved = app.clipboard().read_text().ok();

    app.clipboard()
        .write_text(text.to_string())
        .map_err(|e| format!("clipboard write failed: {e}"))?;

    tokio::time::sleep(std::time::Duration::from_millis(80)).await;

    // Detect display server. XDG_SESSION_TYPE is the canonical hint;
    // fall back to checking WAYLAND_DISPLAY env var.
    let is_wayland = std::env::var("XDG_SESSION_TYPE")
        .map(|s| s.eq_ignore_ascii_case("wayland"))
        .unwrap_or_else(|_| std::env::var("WAYLAND_DISPLAY").is_ok());

    let result = if is_wayland {
        // Wayland: try wtype first (no daemon, works on wlroots/Hyprland/Sway),
        // then ydotool (needs ydotoold daemon + permissions).
        run_first_available(&[
            ("wtype", &["-M", "ctrl", "v", "-m", "ctrl"]),
            ("ydotool", &["key", "29:1", "47:1", "47:0", "29:0"]), // 29=Ctrl, 47=V
        ])
    } else {
        // X11: xdotool is the de-facto standard, ships in most distros.
        run_first_available(&[
            ("xdotool", &["key", "--clearmodifiers", "ctrl+v"]),
        ])
    };

    if let Err(missing) = result {
        eprintln!(
            "[paste:linux] no paste helper found ({missing}). \
             Text is on the clipboard — press Ctrl+V manually."
        );
    }

    if let Some(prior) = saved {
        if !prior.is_empty() {
            let app2 = app.clone();
            tokio::spawn(async move {
                tokio::time::sleep(std::time::Duration::from_millis(300)).await;
                let _ = app2.clipboard().write_text(prior);
            });
        }
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn run_first_available(candidates: &[(&str, &[&str])]) -> Result<(), String> {
    for (bin, args) in candidates {
        if which::which(bin).is_ok() {
            match Command::new(bin).args(*args).status() {
                Ok(s) if s.success() => return Ok(()),
                Ok(s) => eprintln!("[paste:linux] {bin} exited {s}"),
                Err(e) => eprintln!("[paste:linux] {bin} failed: {e}"),
            }
        }
    }
    Err(candidates.iter().map(|(b, _)| *b).collect::<Vec<_>>().join(" / "))
}
