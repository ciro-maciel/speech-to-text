use tauri::{Emitter, Manager};
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Shortcut, ShortcutState, Modifiers};
use tauri_plugin_log::log;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::LazyLock;
use std::time::{Duration, Instant};

use crate::window::{flash_overlay, overlay_state, show_overlay};

// One recording at a time. The mode (transcribe vs translate) is set when
// recording starts; the transcription pipeline reads it at stop.
static RECORDING_ACTIVE: AtomicBool = AtomicBool::new(false);
// True while the settings window captures a new key combo.
static CAPTURING_HOTKEY: AtomicBool = AtomicBool::new(false);
// "Pause shortcuts for 1 hour": epoch ms until which shortcuts are ignored.
static PAUSED_UNTIL_MS: AtomicU64 = AtomicU64::new(0);
static CURRENT_RECORDING_MODE: LazyLock<std::sync::Mutex<String>> =
    LazyLock::new(|| std::sync::Mutex::new("transcribe".to_string()));

static TRIGGER_MODE: LazyLock<std::sync::Mutex<String>> =
    LazyLock::new(|| std::sync::Mutex::new("toggle".to_string()));

static TRANSCRIBE_SHORTCUT: LazyLock<std::sync::Mutex<Option<Shortcut>>> =
    LazyLock::new(|| std::sync::Mutex::new(None));
static TRANSLATE_SHORTCUT: LazyLock<std::sync::Mutex<Option<Shortcut>>> =
    LazyLock::new(|| std::sync::Mutex::new(None));

// Hold mode, double tap: a quick tap leaves the recording running for a
// short window; a second press inside it locks the recording hands-free
// until the next press.
const TAP_MAX: Duration = Duration::from_millis(250);
const DOUBLE_TAP_WINDOW: Duration = Duration::from_millis(350);
static LOCKED: AtomicBool = AtomicBool::new(false);
static TAP_PENDING: AtomicBool = AtomicBool::new(false);
static TAP_GENERATION: AtomicU64 = AtomicU64::new(0);
static PRESSED_AT: LazyLock<std::sync::Mutex<Option<Instant>>> =
    LazyLock::new(|| std::sync::Mutex::new(None));

static ESC_REGISTERED: AtomicBool = AtomicBool::new(false);

/// Global "paste the last transcription" shortcut (⌥⌘V / Ctrl+Alt+V).
pub const PASTE_LAST_HOTKEY: &str = "CommandOrControl+Alt+V";

pub struct HotkeyManager;

impl HotkeyManager {
    pub fn parse_shortcut(hotkey_str: &str) -> Option<(Modifiers, Code)> {
        let parts: Vec<&str> = hotkey_str.split('+').collect();
        let mut modifiers = Modifiers::empty();
        let mut primary: Option<Code> = None;

        for part in parts {
            let p = part.trim().to_lowercase();
            match p.as_str() {
                "commandorcontrol" | "meta" | "command" | "leftcommand" => modifiers |= Modifiers::SUPER,
                "control" | "ctrl" | "leftcontrol" => modifiers |= Modifiers::CONTROL,
                "shift" | "leftshift" => modifiers |= Modifiers::SHIFT,
                "alt" | "option" | "leftalt" => modifiers |= Modifiers::ALT,
                "rightcommand" => modifiers |= Modifiers::SUPER,
                "rightcontrol" => modifiers |= Modifiers::CONTROL,
                "rightshift" => modifiers |= Modifiers::SHIFT,
                "rightoption" | "rightalt" => modifiers |= Modifiers::ALT,
                "space" => primary = Some(Code::Space),
                "enter" => primary = Some(Code::Enter),
                "escape" | "esc" => primary = Some(Code::Escape),
                "tab" => primary = Some(Code::Tab),
                "backspace" => primary = Some(Code::Backspace),
                "delete" => primary = Some(Code::Delete),
                "insert" => primary = Some(Code::Insert),
                "home" => primary = Some(Code::Home),
                "end" => primary = Some(Code::End),
                "pageup" => primary = Some(Code::PageUp),
                "pagedown" => primary = Some(Code::PageDown),
                "arrowup" | "up" => primary = Some(Code::ArrowUp),
                "arrowdown" | "down" => primary = Some(Code::ArrowDown),
                "arrowleft" | "left" => primary = Some(Code::ArrowLeft),
                "arrowright" | "right" => primary = Some(Code::ArrowRight),
                "f1" => primary = Some(Code::F1),
                "f2" => primary = Some(Code::F2),
                "f3" => primary = Some(Code::F3),
                "f4" => primary = Some(Code::F4),
                "f5" => primary = Some(Code::F5),
                "f6" => primary = Some(Code::F6),
                "f7" => primary = Some(Code::F7),
                "f8" => primary = Some(Code::F8),
                "f9" => primary = Some(Code::F9),
                "f10" => primary = Some(Code::F10),
                "f11" => primary = Some(Code::F11),
                "f12" => primary = Some(Code::F12),
                _ if p.len() == 1 => primary = Some(Self::char_to_code(p.chars().next().unwrap())),
                _ => {}
            }
        }

        primary.map(|p| (modifiers, p))
    }

    fn char_to_code(c: char) -> Code {
        use Code::*;
        match c {
            'a' => KeyA, 'b' => KeyB, 'c' => KeyC, 'd' => KeyD, 'e' => KeyE,
            'f' => KeyF, 'g' => KeyG, 'h' => KeyH, 'i' => KeyI, 'j' => KeyJ,
            'k' => KeyK, 'l' => KeyL, 'm' => KeyM, 'n' => KeyN, 'o' => KeyO,
            'p' => KeyP, 'q' => KeyQ, 'r' => KeyR, 's' => KeyS, 't' => KeyT,
            'u' => KeyU, 'v' => KeyV, 'w' => KeyW, 'x' => KeyX, 'y' => KeyY,
            'z' => KeyZ,
            '0' => Digit0, '1' => Digit1, '2' => Digit2, '3' => Digit3, '4' => Digit4,
            '5' => Digit5, '6' => Digit6, '7' => Digit7, '8' => Digit8, '9' => Digit9,
            _ => KeyA,
        }
    }

    /// Register both shortcuts: the transcription one and (optionally) the translation one.
    pub fn register_all(
        app: &tauri::AppHandle,
        transcribe_hotkey: &str,
        translate_hotkey: &str,
        translate_enabled: bool,
        trigger_mode: &str,
    ) {
        Self::set_trigger_mode(trigger_mode);
        Self::register_shortcut(app, transcribe_hotkey, "transcribe");
        if translate_enabled && !translate_hotkey.is_empty() {
            Self::register_shortcut(app, translate_hotkey, "translate");
        } else {
            // Make sure the translate shortcut is unregistered when disabled
            Self::unregister_shortcut(app, "translate");
        }
    }

    /// Register the global "paste last transcription" shortcut once at startup.
    pub fn register_paste_last(app: &tauri::AppHandle) {
        let Some((mods, code)) = Self::parse_shortcut(PASTE_LAST_HOTKEY) else { return };
        let shortcut = Shortcut::new(Some(mods), code);
        let result = app.global_shortcut().on_shortcut(shortcut, |app, _sc, event| {
            if event.state == ShortcutState::Pressed && !Self::is_paused() {
                crate::paste_last(app);
            }
        });
        if let Err(e) = result {
            log::warn!("[hotkey:paste-last] failed to register: {e}");
        }
    }

    /// Register a single shortcut for a given mode ("transcribe" or "translate").
    fn register_shortcut(app: &tauri::AppHandle, hotkey_str: &str, action_mode: &str) {
        let ext = app.global_shortcut();

        // Unregister previous of the same kind
        Self::unregister_shortcut(app, action_mode);

        if hotkey_str.is_empty() {
            eprintln!("[hotkey:{action_mode}] empty shortcut, not registering");
            return;
        }

        let Some((mods, code)) = Self::parse_shortcut(hotkey_str) else {
            eprintln!("[hotkey:{action_mode}] failed to parse '{hotkey_str}'");
            return;
        };

        let shortcut = Shortcut::new(Some(mods), code);
        let action_mode_owned = action_mode.to_string();

        let result = ext.on_shortcut(shortcut.clone(), move |app, _sc, event| {
            if CAPTURING_HOTKEY.load(Ordering::Relaxed) || Self::is_paused() { return; }
            match event.state {
                ShortcutState::Pressed => Self::on_pressed(app, &action_mode_owned),
                ShortcutState::Released => Self::on_released(app, &action_mode_owned),
            }
        });

        match result {
            Err(e) => eprintln!("[hotkey:{action_mode}] failed to register '{hotkey_str}': {e}"),
            Ok(_) => {
                Self::store_shortcut(action_mode, Some(shortcut));
                eprintln!("[hotkey:{action_mode}] registered '{hotkey_str}'");
            }
        }
    }

    fn trigger_mode() -> String {
        TRIGGER_MODE.lock().map(|g| g.clone()).unwrap_or_else(|_| "toggle".to_string())
    }

    fn active_mode() -> String {
        CURRENT_RECORDING_MODE.lock().map(|g| g.clone()).unwrap_or_default()
    }

    fn on_pressed(app: &tauri::AppHandle, mode: &str) {
        if !RECORDING_ACTIVE.load(Ordering::SeqCst) {
            *PRESSED_AT.lock().unwrap() = Some(Instant::now());
            Self::start_recording(app, mode);
            return;
        }
        // Only the SAME action stops the recording — pressing the other
        // hotkey while recording is a no-op (avoids confusion).
        if Self::active_mode() != mode {
            return;
        }
        if Self::trigger_mode() == "toggle" || LOCKED.load(Ordering::SeqCst) {
            Self::stop_recording(app);
        } else if TAP_PENDING.swap(false, Ordering::SeqCst) {
            // Second tap inside the window: keep recording, hands-free.
            TAP_GENERATION.fetch_add(1, Ordering::SeqCst);
            LOCKED.store(true, Ordering::SeqCst);
            overlay_state(app, "listening", serde_json::json!({ "mode": mode, "locked": true }));
        }
    }

    fn on_released(app: &tauri::AppHandle, mode: &str) {
        if !RECORDING_ACTIVE.load(Ordering::SeqCst)
            || Self::trigger_mode() != "hold"
            || Self::active_mode() != mode
            || LOCKED.load(Ordering::SeqCst)
        {
            return;
        }
        let quick = PRESSED_AT
            .lock()
            .unwrap()
            .map(|t| t.elapsed() < TAP_MAX)
            .unwrap_or(false);
        if !quick {
            Self::stop_recording(app);
            return;
        }
        // A tap: wait briefly for a second one before treating it as a stop.
        TAP_PENDING.store(true, Ordering::SeqCst);
        let generation = TAP_GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
        let app = app.clone();
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(DOUBLE_TAP_WINDOW).await;
            if TAP_GENERATION.load(Ordering::SeqCst) == generation
                && TAP_PENDING.swap(false, Ordering::SeqCst)
            {
                Self::stop_recording(&app);
            }
        });
    }

    fn start_recording(app: &tauri::AppHandle, mode: &str) {
        RECORDING_ACTIVE.store(true, Ordering::SeqCst);
        LOCKED.store(false, Ordering::SeqCst);
        TAP_PENDING.store(false, Ordering::SeqCst);
        if let Ok(mut m) = CURRENT_RECORDING_MODE.lock() {
            *m = mode.to_string();
        }
        let (esc, mute, target) = {
            let st = app.state::<crate::AppState>();
            let cfg = st.config.lock().unwrap();
            (cfg.esc_cancels, cfg.mute_while_dictating, cfg.target_language.clone())
        };
        // Window calls made inside the shortcut handler don't take effect on
        // macOS until the handler returns and the event loop turns; do them
        // on the loop's next turn.
        let app2 = app.clone();
        let mode2 = mode.to_string();
        let _ = app.run_on_main_thread(move || {
            // State first, then the window: the HUD is drawn before it is seen.
            overlay_state(&app2, "listening", serde_json::json!({ "mode": mode2, "target": target }));
            show_overlay(&app2);
        });
        let _ = app.emit("start-recording", serde_json::json!({ "mode": mode }));
        if esc {
            Self::sync_escape(app);
        }
        if mute {
            crate::system_audio::mute_output();
        }
        crate::tray::set_activity(app, crate::tray::Activity::Listening);
    }

    fn stop_recording(app: &tauri::AppHandle) {
        if !RECORDING_ACTIVE.swap(false, Ordering::SeqCst) {
            return;
        }
        LOCKED.store(false, Ordering::SeqCst);
        TAP_PENDING.store(false, Ordering::SeqCst);
        let mode = Self::active_mode();
        Self::sync_escape(app);
        crate::system_audio::restore_output();
        overlay_state(app, "transcribing", serde_json::json!({ "mode": mode }));
        crate::tray::set_activity(app, crate::tray::Activity::Processing);
        let _ = app.emit("stop-recording", serde_json::json!({ "mode": mode }));
    }

    /// Esc while listening: drop the audio, paste nothing.
    pub fn cancel_recording(app: &tauri::AppHandle) {
        if !RECORDING_ACTIVE.swap(false, Ordering::SeqCst) {
            return;
        }
        LOCKED.store(false, Ordering::SeqCst);
        TAP_PENDING.store(false, Ordering::SeqCst);
        TAP_GENERATION.fetch_add(1, Ordering::SeqCst);
        Self::sync_escape(app);
        crate::system_audio::restore_output();
        let _ = app.emit("cancel-recording", serde_json::json!({}));
        flash_overlay(app, "cancelled", serde_json::json!({}), 700);
        crate::tray::set_activity(app, crate::tray::Activity::Idle);
    }

    /// Make the temporary Esc shortcut match the current state: registered
    /// while listening (if enabled), unregistered otherwise.
    ///
    /// Runs off the shortcut handler: the plugin holds its lock while a
    /// handler runs, so (un)registering from inside one deadlocks the app.
    /// The mutex keeps quick start/stop sequences in order.
    fn sync_escape(app: &tauri::AppHandle) {
        static SYNC: LazyLock<tokio::sync::Mutex<()>> = LazyLock::new(|| tokio::sync::Mutex::new(()));
        let app = app.clone();
        tauri::async_runtime::spawn(async move {
            let _guard = SYNC.lock().await;
            let enabled = app.state::<crate::AppState>().config.lock().unwrap().esc_cancels;
            let want = enabled && RECORDING_ACTIVE.load(Ordering::SeqCst);
            let esc = Shortcut::new(None, Code::Escape);
            let shortcuts = app.global_shortcut();
            if want && !ESC_REGISTERED.load(Ordering::SeqCst) {
                let result = shortcuts.on_shortcut(esc, |app, _sc, event| {
                    if event.state == ShortcutState::Pressed {
                        Self::cancel_recording(app);
                    }
                });
                match result {
                    Ok(()) => ESC_REGISTERED.store(true, Ordering::SeqCst),
                    Err(e) => log::warn!("[hotkey:esc] failed to register: {e}"),
                }
            } else if !want && ESC_REGISTERED.load(Ordering::SeqCst) {
                let _ = shortcuts.unregister(esc);
                ESC_REGISTERED.store(false, Ordering::SeqCst);
            }
        });
    }

    fn unregister_shortcut(app: &tauri::AppHandle, action_mode: &str) {
        let ext = app.global_shortcut();
        if let Some(prev) = Self::take_shortcut(action_mode) {
            let _ = ext.unregister(prev);
        }
    }

    fn store_shortcut(action_mode: &str, sc: Option<Shortcut>) {
        let lock = match action_mode {
            "translate" => &TRANSLATE_SHORTCUT,
            _ => &TRANSCRIBE_SHORTCUT,
        };
        if let Ok(mut g) = lock.lock() { *g = sc; }
    }

    fn take_shortcut(action_mode: &str) -> Option<Shortcut> {
        let lock = match action_mode {
            "translate" => &TRANSLATE_SHORTCUT,
            _ => &TRANSCRIBE_SHORTCUT,
        };
        lock.lock().ok().and_then(|mut g| g.take())
    }

    /// While the settings window captures a new combo, ignore the shortcuts.
    pub fn set_paused(paused: bool) {
        CAPTURING_HOTKEY.store(paused, Ordering::Relaxed);
    }

    /// Ignore the dictation shortcuts until `until_ms` (epoch ms); 0 resumes.
    pub fn pause_until(until_ms: u64) {
        PAUSED_UNTIL_MS.store(until_ms, Ordering::SeqCst);
    }

    pub fn paused_until() -> Option<u64> {
        let until = PAUSED_UNTIL_MS.load(Ordering::SeqCst);
        (until > crate::history::now_ms()).then_some(until)
    }

    fn is_paused() -> bool {
        Self::paused_until().is_some()
    }

    /// End-to-end tests (debug builds only): synthetic key events don't
    /// reach global shortcuts reliably on macOS, so tests write commands to
    /// the file named by STT_E2E_TRIGGER and they run the same handlers a
    /// real key press runs. Commands: "press <mode>", "release <mode>",
    /// "escape", "paste-last".
    #[cfg(debug_assertions)]
    pub fn watch_e2e_trigger(app: &tauri::AppHandle) {
        let Ok(path) = std::env::var("STT_E2E_TRIGGER") else { return };
        let app = app.clone();
        std::thread::spawn(move || loop {
            std::thread::sleep(Duration::from_millis(30));
            let Ok(cmd) = std::fs::read_to_string(&path) else { continue };
            let cmd = cmd.trim().to_string();
            if cmd.is_empty() {
                continue;
            }
            let _ = std::fs::write(&path, "");
            let app2 = app.clone();
            let _ = app.run_on_main_thread(move || {
                let mut parts = cmd.split_whitespace();
                match (parts.next(), parts.next()) {
                    (Some("press"), Some(mode)) if !Self::is_paused() => Self::on_pressed(&app2, mode),
                    (Some("release"), Some(mode)) if !Self::is_paused() => Self::on_released(&app2, mode),
                    (Some("escape"), _) if ESC_REGISTERED.load(Ordering::SeqCst) => Self::cancel_recording(&app2),
                    (Some("paste-last"), _) if !Self::is_paused() => crate::paste_last(&app2),
                    _ => {}
                }
            });
        });
    }

    pub fn set_trigger_mode(mode: &str) {
        if let Ok(mut tm) = TRIGGER_MODE.lock() {
            *tm = mode.to_string();
        }
    }
}
