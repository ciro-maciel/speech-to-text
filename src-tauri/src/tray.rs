//! Menu bar / system tray.
//!
//! The icon shows what the app is doing; only the icon, no text beside it.
//! The S never leaves: a badge in its corner says the state (13-favicon.md) —
//! a steady dot while listening, a ring that turns while processing, a dash
//! when paused — and the S turns to outline when the app needs you. While listening,
//! the elapsed time is in the tooltip. The menu holds what changes day to day — paste again, the
//! microphone, AI on or off — and leaves the rest to the settings window.
//! The menu is rebuilt whenever its content changes (`refresh`).

use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{LazyLock, Mutex};
use std::time::Instant;

use tauri::image::Image;
use tauri::menu::{CheckMenuItem, IsMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{Manager, Wry};
use tauri_plugin_log::log;

use crate::hotkey::HotkeyManager;

const TRAY_ID: &str = "main";

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Activity {
    Idle,
    Listening,
    Processing,
}

static ACTIVITY: Mutex<Activity> = Mutex::new(Activity::Idle);
static LISTEN_STARTED: Mutex<Option<Instant>> = Mutex::new(None);
static NEEDS_ATTENTION: AtomicBool = AtomicBool::new(false);
/// The glyph on screen, so the icon is only redrawn when it changes.
static DRAWN: Mutex<Option<(Glyph, bool)>> = Mutex::new(None);
/// The ring's position while processing (0–7).
static RING_FRAME: AtomicUsize = AtomicUsize::new(0);
/// Bumped on every activity change, so a ring loop stops when its turn ends.
static ACTIVITY_GENERATION: AtomicU64 = AtomicU64::new(0);
/// Microphones as reported by the renderer: (deviceId, label).
static MICROPHONES: LazyLock<Mutex<Vec<(String, String)>>> = LazyLock::new(|| Mutex::new(Vec::new()));

pub const LANGUAGES: [(&str, &str); 10] = [
    ("en", "Inglês"),
    ("pt", "Português"),
    ("es", "Espanhol"),
    ("fr", "Francês"),
    ("de", "Alemão"),
    ("it", "Italiano"),
    ("ja", "Japonês"),
    ("ko", "Coreano"),
    ("zh", "Chinês"),
    ("ru", "Russo"),
];

macro_rules! frames {
    ($($name:literal),+) => {
        [$((include_bytes!(concat!("../icons/tray/", $name, "-dark.png")) as &[u8],
            include_bytes!(concat!("../icons/tray/", $name, "-light.png")) as &[u8])),+]
    };
}

static PROCESSING: [(&[u8], &[u8]); 8] = frames!(
    "processing-0", "processing-1", "processing-2", "processing-3",
    "processing-4", "processing-5", "processing-6", "processing-7"
);
static STILL: [(&[u8], &[u8]); 4] = frames!("idle", "paused", "attention", "listening");

#[derive(Clone, Copy, PartialEq, Eq)]
enum Glyph {
    Idle,
    Listening,
    Processing(usize),
    Paused,
    Attention,
}

fn icon_bytes(glyph: Glyph, light: bool) -> &'static [u8] {
    let (dark, white) = match glyph {
        Glyph::Listening => STILL[3],
        Glyph::Processing(i) => PROCESSING[i % 8],
        Glyph::Paused => STILL[1],
        Glyph::Attention => STILL[2],
        Glyph::Idle => STILL[0],
    };
    if light { white } else { dark }
}

/// macOS inverts template images itself. Linux panels are dark by default;
/// Windows follows the system theme.
fn wants_light_icon(app: &tauri::AppHandle) -> bool {
    #[cfg(target_os = "macos")]
    { let _ = app; false }
    #[cfg(target_os = "linux")]
    { let _ = app; true }
    #[cfg(target_os = "windows")]
    {
        app.get_webview_window("main")
            .and_then(|w| w.theme().ok())
            .map(|t| t == tauri::Theme::Dark)
            .unwrap_or(true)
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
    { let _ = app; false }
}

fn current_glyph() -> Glyph {
    if HotkeyManager::paused_until().is_some() {
        return Glyph::Paused;
    }
    match *ACTIVITY.lock().unwrap() {
        Activity::Listening => Glyph::Listening,
        Activity::Processing => Glyph::Processing(RING_FRAME.load(Ordering::SeqCst)),
        Activity::Idle if NEEDS_ATTENTION.load(Ordering::SeqCst) => Glyph::Attention,
        Activity::Idle => Glyph::Idle,
    }
}

fn apply_icon(app: &tauri::AppHandle) {
    let Some(tray) = app.tray_by_id(TRAY_ID) else { return };
    let glyph = current_glyph();
    let light = wants_light_icon(app);
    {
        let mut drawn = DRAWN.lock().unwrap();
        if *drawn == Some((glyph, light)) {
            return;
        }
        *drawn = Some((glyph, light));
    }
    let Ok(image) = Image::from_bytes(icon_bytes(glyph, light)) else { return };
    // macOS: image and template flag in one step. Tauri's set_icon writes the
    // image as a plain one and set_icon_as_template fixes it after, and the
    // menu bar drew that frame in between: a black square on every change.
    #[cfg(target_os = "macos")]
    {
        let icon = tray_icon::Icon::from_rgba(image.rgba().to_vec(), image.width(), image.height());
        if let Ok(icon) = icon {
            let _ = tray.with_inner_tray_icon(move |inner| {
                let _ = inner.set_icon_with_as_template(Some(icon), true);
            });
        }
    }
    #[cfg(not(target_os = "macos"))]
    let _ = tray.set_icon(Some(image));
}

fn format_elapsed(secs: u64) -> String {
    format!("{}:{:02}", secs / 60, secs % 60)
}

/// Update the icon for a pipeline stage; while listening, tick a timer in the tooltip.
pub fn set_activity(app: &tauri::AppHandle, activity: Activity) {
    *ACTIVITY.lock().unwrap() = activity;
    let generation = ACTIVITY_GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
    RING_FRAME.store(0, Ordering::SeqCst);
    apply_icon(app);
    if activity == Activity::Processing {
        spin_ring(app, generation);
    }
    let Some(tray) = app.tray_by_id(TRAY_ID) else { return };

    if activity != Activity::Listening {
        *LISTEN_STARTED.lock().unwrap() = None;
        #[cfg(not(target_os = "windows"))]
        let _ = tray.set_title(None::<&str>);
        let _ = tray.set_tooltip(Some(tooltip_text(app)));
        return;
    }

    let started = Instant::now();
    *LISTEN_STARTED.lock().unwrap() = Some(started);
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        loop {
            // Stop when this listening session ended or a new one began.
            if *LISTEN_STARTED.lock().unwrap() != Some(started) {
                break;
            }
            let elapsed = format_elapsed(started.elapsed().as_secs());
            // Only the icon in the menu bar (13-favicon.md): the time stays in the tooltip.
            if let Some(tray) = app.tray_by_id(TRAY_ID) {
                let _ = tray.set_tooltip(Some(format!("Speech to Text · Ouvindo {elapsed}")));
            }
            tokio::time::sleep(std::time::Duration::from_millis(1000)).await;
        }
    });
}

/// Turn the ring one step every 150 ms until the activity changes.
fn spin_ring(app: &tauri::AppHandle, generation: u64) {
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        loop {
            tokio::time::sleep(std::time::Duration::from_millis(150)).await;
            if ACTIVITY_GENERATION.load(Ordering::SeqCst) != generation {
                break;
            }
            RING_FRAME.fetch_add(1, Ordering::SeqCst);
            apply_icon(&app);
        }
    });
}

/// Human hotkey: "⌘2" on macOS, "Ctrl+2" elsewhere.
pub fn display_hotkey(accelerator: &str) -> String {
    if accelerator.is_empty() {
        return "sem atalho".to_string();
    }
    let mac = cfg!(target_os = "macos");
    // Apple's modifier order is ⌃ ⌥ ⇧ ⌘; the key itself goes last.
    let rank = |p: &str| match p.trim().to_lowercase().as_str() {
        "control" | "ctrl" | "leftcontrol" | "rightcontrol" => 0,
        "alt" | "option" | "leftalt" | "rightalt" | "rightoption" => 1,
        "shift" | "leftshift" | "rightshift" => 2,
        "commandorcontrol" | "cmdorctrl" | "command" | "leftcommand" | "rightcommand" | "meta" | "super" => 3,
        _ => 4,
    };
    let mut ordered: Vec<&str> = accelerator.split('+').collect();
    ordered.sort_by_key(|p| rank(p));
    let parts: Vec<String> = ordered
        .into_iter()
        .map(|p| {
            let lower = p.trim().to_lowercase();
            let named = match lower.as_str() {
                "commandorcontrol" | "cmdorctrl" => if mac { "⌘" } else { "Ctrl" },
                "command" | "leftcommand" | "meta" | "super" => if mac { "⌘" } else { "Win" },
                "rightcommand" => if mac { "R⌘" } else { "Win" },
                "control" | "ctrl" | "leftcontrol" | "rightcontrol" => if mac { "⌃" } else { "Ctrl" },
                "shift" | "leftshift" | "rightshift" => if mac { "⇧" } else { "Shift" },
                "alt" | "option" | "leftalt" | "rightalt" | "rightoption" => if mac { "⌥" } else { "Alt" },
                "space" => "Espaço",
                _ => "",
            };
            if named.is_empty() { p.trim().to_uppercase() } else { named.to_string() }
        })
        .collect();
    parts.join(if mac { "" } else { "+" })
}

fn local_hhmm(epoch_ms: u64) -> String {
    use chrono::{Local, TimeZone};
    Local
        .timestamp_millis_opt(epoch_ms as i64)
        .single()
        .map(|t| t.format("%H:%M").to_string())
        .unwrap_or_default()
}

fn status_text(app: &tauri::AppHandle) -> String {
    if let Some(until) = HotkeyManager::paused_until() {
        return format!("Pausado até {}", local_hhmm(until));
    }
    let (hotkey, mode) = {
        let st = app.state::<crate::AppState>();
        let cfg = st.config.lock().unwrap();
        (cfg.hotkey.clone(), cfg.trigger_mode.clone())
    };
    let verb = if mode == "hold" { "segure" } else { "toque" };
    #[allow(unused_mut)]
    let mut text = format!("Pronto · {verb} {} para ditar", display_hotkey(&hotkey));
    #[cfg(target_os = "linux")]
    {
        let perms = crate::permissions::check_all_permissions();
        if let Some(session) = perms.session {
            text.push_str(if session == "wayland" { " · Wayland" } else { " · X11" });
        }
    }
    text
}

fn tooltip_text(app: &tauri::AppHandle) -> String {
    format!("Speech to Text · {}", status_text(app))
}

/// What needs the user, if anything, as a menu label.
fn attention_label(perms: &crate::permissions::PermissionStatus) -> Option<String> {
    if perms.microphone == "denied" {
        return Some("Microfone bloqueado · Liberar…".to_string());
    }
    if perms.accessibility_required && !perms.accessibility {
        return Some("Colagem desligada · Liberar…".to_string());
    }
    perms
        .missing_paste_tool
        .as_ref()
        .map(|tool| format!("{tool} não encontrado · Ver comando…"))
}

fn truncate(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_string();
    }
    let cut: String = text.chars().take(max - 1).collect();
    format!("{}…", cut.trim_end())
}

fn build_menu(app: &tauri::AppHandle) -> tauri::Result<Menu<Wry>> {
    let cfg = app.state::<crate::AppState>().config.lock().unwrap().clone();
    let history = &app.state::<crate::AppState>().history;
    let perms = crate::permissions::check_all_permissions();
    let attention = attention_label(&perms);
    NEEDS_ATTENTION.store(attention.is_some(), Ordering::SeqCst);

    let mut items: Vec<Box<dyn IsMenuItem<Wry>>> = Vec::new();
    let sep = || PredefinedMenuItem::separator(app);

    items.push(Box::new(MenuItem::with_id(app, "status", status_text(app), false, None::<&str>)?));
    items.push(Box::new(sep()?));

    // On Linux the icon click only opens the menu, so opening the window
    // has to be a menu item.
    #[cfg(target_os = "linux")]
    items.push(Box::new(MenuItem::with_id(app, "open", "Abrir o Speech to Text", true, None::<&str>)?));

    let has_last = history.last_text().is_some();
    items.push(Box::new(MenuItem::with_id(
        app,
        "paste_last",
        "Colar a última transcrição",
        has_last,
        Some(crate::hotkey::PASTE_LAST_HOTKEY),
    )?));

    let recent = history.recent_texts(5);
    let recent_menu = Submenu::with_id(app, "recent", "Últimas transcrições", true)?;
    if recent.is_empty() {
        recent_menu.append(&MenuItem::with_id(app, "recent_none", "Nenhuma ainda", false, None::<&str>)?)?;
    } else {
        for (i, text) in recent.iter().enumerate() {
            recent_menu.append(&MenuItem::with_id(app, format!("recent:{i}"), truncate(text, 60), true, None::<&str>)?)?;
        }
    }
    items.push(Box::new(recent_menu));
    items.push(Box::new(sep()?));

    items.push(Box::new(CheckMenuItem::with_id(
        app, "refine", "Refinar com IA", true, cfg.refinement_enabled, None::<&str>,
    )?));

    let target_label = LANGUAGES
        .iter()
        .find(|(code, _)| *code == cfg.target_language)
        .map(|(_, name)| *name)
        .unwrap_or("Inglês");
    let lang_menu = Submenu::with_id(app, "lang", format!("Traduzir para: {target_label}"), cfg.translate_enabled)?;
    for (code, name) in LANGUAGES {
        lang_menu.append(&CheckMenuItem::with_id(
            app, format!("lang:{code}"), name, true, cfg.target_language == code, None::<&str>,
        )?)?;
    }
    items.push(Box::new(lang_menu));

    let mics = MICROPHONES.lock().unwrap().clone();
    let selected_mic = cfg.selected_microphone.clone().unwrap_or_default();
    let mic_name = mics
        .iter()
        .find(|(id, _)| *id == selected_mic)
        .map(|(_, label)| label.clone())
        .unwrap_or_else(|| "Padrão do sistema".to_string());
    let mic_menu = Submenu::with_id(app, "mic", format!("Microfone: {}", truncate(&mic_name, 32)), true)?;
    mic_menu.append(&CheckMenuItem::with_id(
        app, "mic:", "Padrão do sistema", true, selected_mic.is_empty(), None::<&str>,
    )?)?;
    for (id, label) in &mics {
        mic_menu.append(&CheckMenuItem::with_id(
            app, format!("mic:{id}"), truncate(label, 48), true, *id == selected_mic, None::<&str>,
        )?)?;
    }
    items.push(Box::new(mic_menu));

    let model_menu = Submenu::with_id(app, "model", format!("Modelo: {}", cfg.model), true)?;
    for name in crate::models::AVAILABLE_MODELS {
        if crate::config::get_model_path(app, name).exists() {
            model_menu.append(&CheckMenuItem::with_id(
                app, format!("model:{name}"), name, true, cfg.model == name, None::<&str>,
            )?)?;
        }
    }
    items.push(Box::new(model_menu));
    items.push(Box::new(sep()?));

    match HotkeyManager::paused_until() {
        Some(until) => items.push(Box::new(MenuItem::with_id(
            app, "resume", format!("Retomar atalhos (pausado até {})", local_hhmm(until)), true, None::<&str>,
        )?)),
        None => items.push(Box::new(MenuItem::with_id(app, "pause", "Pausar atalhos por 1 hora", true, None::<&str>)?)),
    }
    if let Some(label) = attention {
        items.push(Box::new(MenuItem::with_id(app, "permissions", label, true, None::<&str>)?));
    }
    if let Some(version) = crate::updates::pending() {
        items.push(Box::new(MenuItem::with_id(
            app, "update_restart", format!("Reiniciar e atualizar para {version}"), true, None::<&str>,
        )?));
    }
    items.push(Box::new(sep()?));

    items.push(Box::new(MenuItem::with_id(app, "settings", "Configurações…", true, Some("CmdOrCtrl+,"))?));
    items.push(Box::new(MenuItem::with_id(app, "check_updates", "Verificar atualizações", true, None::<&str>)?));
    items.push(Box::new(sep()?));
    items.push(Box::new(MenuItem::with_id(app, "quit", "Sair", true, Some("CmdOrCtrl+Q"))?));

    let refs: Vec<&dyn IsMenuItem<Wry>> = items.iter().map(|i| i.as_ref()).collect();
    Menu::with_items(app, &refs)
}

/// Rebuild the menu and icon after anything they show has changed.
pub fn refresh(app: &tauri::AppHandle) {
    let app2 = app.clone();
    // Menus must be built on the main thread on macOS.
    let _ = app.run_on_main_thread(move || {
        let Some(tray) = app2.tray_by_id(TRAY_ID) else { return };
        match build_menu(&app2) {
            Ok(menu) => { let _ = tray.set_menu(Some(menu)); }
            Err(e) => log::warn!("[tray] menu rebuild failed: {e}"),
        }
        apply_icon(&app2);
        let _ = tray.set_tooltip(Some(tooltip_text(&app2)));
    });
}

pub fn set_microphones(app: &tauri::AppHandle, mics: Vec<(String, String)>) {
    *MICROPHONES.lock().unwrap() = mics;
    refresh(app);
}

fn set(app: &tauri::AppHandle, key: &str, value: serde_json::Value) {
    if let Err(e) = crate::apply_setting(app, key, value) {
        log::warn!("[tray] {key}: {e}");
    }
}

fn on_menu_event(app: &tauri::AppHandle, id: &str) {
    match id {
        "paste_last" => crate::paste_last(app),
        "refine" => {
            let on = !app.state::<crate::AppState>().config.lock().unwrap().refinement_enabled;
            set(app, "refinementEnabled", serde_json::json!(on));
        }
        "pause" => {
            let until = crate::history::now_ms() + 60 * 60 * 1000;
            HotkeyManager::pause_until(until);
            refresh(app);
            let app = app.clone();
            tauri::async_runtime::spawn(async move {
                tokio::time::sleep(std::time::Duration::from_secs(60 * 60)).await;
                if HotkeyManager::paused_until().is_none() {
                    refresh(&app);
                }
            });
        }
        "resume" => {
            HotkeyManager::pause_until(0);
            refresh(app);
        }
        "permissions" => {
            crate::permissions::request_all();
            crate::window::open_settings(app, Some("permissoes"));
        }
        "open" => crate::window::open_settings(app, Some("inicio")),
        "settings" => crate::window::open_settings(app, None),
        "check_updates" => {
            let app = app.clone();
            tauri::async_runtime::spawn(async move {
                let status = crate::updates::check(&app).await;
                crate::show_update_dialog(&app, &status);
            });
        }
        "update_restart" => {
            if let Err(e) = crate::updates::install_pending(app, true) {
                log::error!("[updates] install failed: {e}");
            }
        }
        "quit" => app.exit(0),
        _ => {
            if let Some(i) = id.strip_prefix("recent:").and_then(|n| n.parse::<usize>().ok()) {
                if let Some(text) = app.state::<crate::AppState>().history.recent_texts(5).get(i) {
                    use tauri_plugin_clipboard_manager::ClipboardExt;
                    let _ = app.clipboard().write_text(text.clone());
                }
            } else if let Some(code) = id.strip_prefix("lang:") {
                set(app, "targetLanguage", serde_json::json!(code));
            } else if let Some(device) = id.strip_prefix("mic:") {
                set(app, "selectedMicrophone", serde_json::json!(device));
            } else if let Some(model) = id.strip_prefix("model:") {
                set(app, "model", serde_json::json!(model));
            }
        }
    }
}

pub fn setup_tray(app: &tauri::AppHandle) -> Result<(), Box<dyn std::error::Error>> {
    let icon = Image::from_bytes(icon_bytes(Glyph::Idle, wants_light_icon(app)))?;
    let menu = build_menu(app)?;

    // Windows convention: left click opens the app, right click the menu.
    let left_click_menu = !cfg!(target_os = "windows");

    #[allow(unused_mut)]
    let mut builder = TrayIconBuilder::with_id(TRAY_ID)
        .icon(icon)
        .menu(&menu)
        .tooltip(tooltip_text(app))
        .show_menu_on_left_click(left_click_menu)
        .on_menu_event(|app, event| on_menu_event(app, event.id.as_ref()))
        .on_tray_icon_event(|tray, event| {
            if cfg!(target_os = "windows") {
                if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
                    crate::window::open_settings(tray.app_handle(), Some("inicio"));
                }
            }
        });

    #[cfg(target_os = "macos")]
    {
        builder = builder.icon_as_template(true);
    }
    builder.build(app)?;
    Ok(())
}
