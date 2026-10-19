use serde::{Deserialize, Serialize};
use tauri_plugin_store::StoreExt;
use std::path::PathBuf;
use std::fs;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppConfig {
    pub hotkey: String,
    pub trigger_mode: String,
    pub language: String,
    pub prompt: String,
    pub auto_paste: bool,
    pub model: String,
    pub audio_device: Option<String>,
    pub selected_microphone: Option<String>,
    pub auto_launch: bool,
    // Translation feature — second hotkey, OpenRouter-backed
    pub translate_hotkey: String,
    pub translate_enabled: bool,
    pub target_language: String,
    pub openrouter_model: String,
    pub openrouter_api_key: String,
    // Refinement feature — polishes raw STT output via OpenRouter before paste/translate
    pub refinement_enabled: bool,
    pub refinement_glossary: String,
    // Overlay anchor: top-left | top | top-right | left | center | right | bottom-left | bottom | bottom-right
    pub overlay_position: String,
    // "light" fixes words and punctuation; "rewrite" also reorganizes phrasing.
    pub refinement_level: String,
    pub esc_cancels: bool,
    pub sounds: bool,
    pub mute_while_dictating: bool,
    // Days of transcription history kept on disk; 0 keeps it in memory only.
    pub history_days: u32,
    pub overlay_show_text: bool,
    pub overlay_show_timer: bool,
    pub keep_model_loaded: bool,
    pub voice_detection: bool,
    pub onboarded: bool,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            hotkey: "CommandOrControl+Shift+Space".to_string(),
            trigger_mode: "toggle".to_string(),
            language: "pt".to_string(),
            prompt: "A frase pode conter termos técnicos em inglês, programação e desenvolvimento de software. Pontuação e formatação corretas.".to_string(),
            auto_paste: true,
            model: "tiny".to_string(),
            audio_device: Some("default".to_string()),
            selected_microphone: None,
            auto_launch: false,
            translate_hotkey: "CommandOrControl+Shift+T".to_string(),
            translate_enabled: true,
            target_language: "en".to_string(),
            openrouter_model: std::env::var("OPENROUTER_MODEL")
                .unwrap_or_else(|_| "google/gemini-flash-1.5-8b".to_string()),
            openrouter_api_key: std::env::var("OPENROUTER_API_KEY").unwrap_or_default(),
            refinement_enabled: false,
            refinement_glossary: String::new(),
            overlay_position: "top-right".to_string(),
            refinement_level: "light".to_string(),
            esc_cancels: true,
            sounds: false,
            mute_while_dictating: false,
            history_days: 7,
            overlay_show_text: true,
            overlay_show_timer: true,
            keep_model_loaded: true,
            voice_detection: true,
            onboarded: false,
        }
    }
}

pub fn load_config(app: &tauri::AppHandle) -> AppConfig {
    let store = app.store("settings.json").expect("Failed to open store");

    let mut cfg = AppConfig::default();

    if let Some(v) = store.get("hotkey") {
        if let Some(s) = v.as_str() { cfg.hotkey = s.to_string(); }
    }
    if let Some(v) = store.get("triggerMode") {
        if let Some(s) = v.as_str() {
            // Normalize legacy "hybrid" (deprecated) → "toggle"
            cfg.trigger_mode = if s == "hold" || s == "toggle" {
                s.to_string()
            } else {
                "toggle".to_string()
            };
        }
    }
    if let Some(v) = store.get("language") {
        if let Some(s) = v.as_str() { cfg.language = s.to_string(); }
    }
    if let Some(v) = store.get("prompt") {
        if let Some(s) = v.as_str() { cfg.prompt = s.to_string(); }
    }
    if let Some(v) = store.get("autoPaste") {
        if let Some(b) = v.as_bool() { cfg.auto_paste = b; }
    }
    if let Some(v) = store.get("model") {
        if let Some(s) = v.as_str() { cfg.model = s.to_string(); }
    }
    if let Some(v) = store.get("audioDevice") {
        if let Some(s) = v.as_str() { cfg.audio_device = Some(s.to_string()); }
    }
    if let Some(v) = store.get("selectedMicrophone") {
        if let Some(s) = v.as_str() { cfg.selected_microphone = Some(s.to_string()); }
    }
    if let Some(v) = store.get("autoLaunch") {
        if let Some(b) = v.as_bool() { cfg.auto_launch = b; }
    }

    // Translation settings
    if let Some(v) = store.get("translateHotkey") {
        if let Some(s) = v.as_str() { cfg.translate_hotkey = s.to_string(); }
    }
    if let Some(v) = store.get("translateEnabled") {
        if let Some(b) = v.as_bool() { cfg.translate_enabled = b; }
    }
    if let Some(v) = store.get("targetLanguage") {
        if let Some(s) = v.as_str() { cfg.target_language = s.to_string(); }
    }
    if let Some(v) = store.get("openrouterModel") {
        if let Some(s) = v.as_str() { if !s.is_empty() { cfg.openrouter_model = s.to_string(); } }
    }
    if let Some(v) = store.get("openrouterApiKey") {
        if let Some(s) = v.as_str() { if !s.is_empty() { cfg.openrouter_api_key = s.to_string(); } }
    }

    // Refinement settings
    if let Some(v) = store.get("refinementEnabled") {
        if let Some(b) = v.as_bool() { cfg.refinement_enabled = b; }
    }
    if let Some(v) = store.get("refinementGlossary") {
        if let Some(s) = v.as_str() { cfg.refinement_glossary = s.to_string(); }
    }
    if let Some(v) = store.get("overlayPosition") {
        if let Some(s) = v.as_str() { if !s.is_empty() { cfg.overlay_position = s.to_string(); } }
    }

    let get_bool = |key: &str| store.get(key).and_then(|v| v.as_bool());
    if let Some(v) = store.get("refinementLevel").and_then(|v| v.as_str().map(str::to_string)) {
        if v == "light" || v == "rewrite" { cfg.refinement_level = v; }
    }
    if let Some(b) = get_bool("escCancels") { cfg.esc_cancels = b; }
    if let Some(b) = get_bool("sounds") { cfg.sounds = b; }
    if let Some(b) = get_bool("muteWhileDictating") { cfg.mute_while_dictating = b; }
    if let Some(n) = store.get("historyDays").and_then(|v| v.as_u64()) { cfg.history_days = n as u32; }
    if let Some(b) = get_bool("overlayShowText") { cfg.overlay_show_text = b; }
    if let Some(b) = get_bool("overlayShowTimer") { cfg.overlay_show_timer = b; }
    if let Some(b) = get_bool("keepModelLoaded") { cfg.keep_model_loaded = b; }
    if let Some(b) = get_bool("voiceDetection") { cfg.voice_detection = b; }
    // Anyone who already configured a hotkey before onboarding existed has
    // been using the app — don't walk them through first-run again.
    cfg.onboarded = get_bool("onboarded").unwrap_or_else(|| store.get("hotkey").is_some());

    cfg
}

pub fn store_set(app: &tauri::AppHandle, key: &str, value: serde_json::Value) -> Result<(), String> {
    let store = app.store("settings.json").map_err(|e| e.to_string())?;
    store.set(key, value);
    store.save().map_err(|e| e.to_string())?;
    Ok(())
}

/// Builds before 1.35 used another bundle identifier, so their settings and
/// history sit in a sibling folder of the app data folder whose name also ends
/// in ".speech-to-text". On the first start under the current identifier, those
/// two files are copied over once; the old folder is left as it was.
pub fn adopt_earlier_settings(app: &tauri::AppHandle) {
    use tauri::Manager;
    let Ok(current) = app.path().app_data_dir() else { return };
    if current.join("settings.json").exists() {
        return;
    }
    let (Some(parent), Some(own)) = (current.parent(), current.file_name()) else { return };
    let Ok(siblings) = fs::read_dir(parent) else { return };
    for sibling in siblings.flatten() {
        let name = sibling.file_name();
        let name = name.to_string_lossy();
        if !name.ends_with(".speech-to-text") || *name == *own.to_string_lossy() {
            continue;
        }
        let old = sibling.path();
        if !old.join("settings.json").exists() {
            continue;
        }
        let _ = fs::create_dir_all(&current);
        for file in ["settings.json", "history.json"] {
            if old.join(file).exists() {
                let _ = fs::copy(old.join(file), current.join(file));
            }
        }
        return;
    }
}

pub fn get_models_dir(_app: &tauri::AppHandle) -> PathBuf {
    let data_dir = dirs::data_dir()
        .unwrap_or_else(|| dirs::home_dir().unwrap_or_default())
        .join("speech-to-text")
        .join("models");

    if !data_dir.exists() {
        let _ = fs::create_dir_all(&data_dir);
    }
    data_dir
}

pub fn get_model_path(app: &tauri::AppHandle, model_name: &str) -> PathBuf {
    let models_dir = get_models_dir(app);
    models_dir.join(format!("ggml-{model_name}.bin"))
}

