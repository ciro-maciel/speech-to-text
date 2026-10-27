mod config;
mod history;
mod i18n;
mod hotkey;
mod models;
mod parakeet;
mod permissions;
#[cfg(windows)]
mod process;
mod refinement;
mod system_audio;
mod transcription;
mod translation;
mod tray;
mod updates;
mod whisper_server;
mod window;

use config::load_config;
use hotkey::HotkeyManager;
use models::ModelManager;
use transcription::{paste_text_via_clipboard, transcribe_audio, Engine, TranscribeOptions, PASTE_NEEDS_PERMISSION};
use window::{flash_overlay, overlay_state};

use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager, RunEvent, State, WindowEvent};
use tauri_plugin_log::log;

pub struct AppState {
    pub config: Mutex<config::AppConfig>,
    pub model_manager: std::sync::Arc<ModelManager>,
    pub whisper: std::sync::Arc<whisper_server::WhisperServer>,
    pub parakeet: std::sync::Arc<parakeet::ParakeetServer>,
    pub history: history::History,
}

/// Whisper's initial prompt biases the decoder toward the words it contains,
/// so the refinement glossary (names, jargon) goes in too — it fixes spelling
/// at the source instead of hoping the LLM catches it. whisper.cpp keeps the
/// tail when the prompt is too long, so the glossary goes last.
fn whisper_prompt(cfg: &config::AppConfig) -> String {
    let terms: Vec<&str> = cfg
        .refinement_glossary
        .split(|c| c == '\n' || c == ',' || c == ';')
        .map(str::trim)
        .filter(|t| !t.is_empty())
        .collect();
    if terms.is_empty() {
        cfg.prompt.clone()
    } else {
        format!("{} {}.", cfg.prompt.trim(), terms.join(", "))
    }
}

/// Load `model` in its engine and stop the other one, so only one model sits in memory.
fn preload_model(app: &AppHandle, model: &str) {
    let app = app.clone();
    let state = app.state::<AppState>();
    let (whisper, parakeet) = (state.whisper.clone(), state.parakeet.clone());
    let model = model.to_string();
    tauri::async_runtime::spawn(async move {
        if model == parakeet::MODEL {
            whisper.stop();
            parakeet.preload(&app).await;
        } else {
            parakeet.stop();
            whisper.preload(&app, &config::get_model_path(&app, &model)).await;
        }
    });
}

fn stop_models(state: &AppState) {
    state.whisper.stop();
    state.parakeet.stop();
}

fn re_register_hotkeys(app: &AppHandle) {
    let cfg = app.state::<AppState>().config.lock().unwrap().clone();
    HotkeyManager::register_all(
        app,
        &cfg.hotkey,
        &cfg.translate_hotkey,
        cfg.translate_enabled,
        &cfg.trigger_mode,
    );
}

/// Change one setting by its camelCase key, persist it, and apply its side
/// effects. Every settings control — window, tray, onboarding — goes through
/// here so they all stay in sync (`config-changed` tells the window).
pub fn apply_setting(app: &AppHandle, key: &str, value: serde_json::Value) -> Result<config::AppConfig, String> {
    // A shortcut that can't be registered would silently disable dictation.
    if key == "hotkey" || key == "translateHotkey" {
        let combo = value.as_str().unwrap_or_default();
        if !combo.is_empty() && HotkeyManager::parse_shortcut(combo).is_none() {
            return Err(if i18n::is_portuguese() {
                format!("atalho inválido: {combo}")
            } else {
                format!("invalid shortcut: {combo}")
            });
        }
    }
    let state = app.state::<AppState>();
    let updated = {
        let mut cfg = state.config.lock().unwrap();
        let mut json = serde_json::to_value(&*cfg).map_err(|e| e.to_string())?;
        let obj = json.as_object_mut().ok_or("config is not an object")?;
        if !obj.contains_key(key) {
            return Err(format!("unknown setting: {key}"));
        }
        obj.insert(key.to_string(), value.clone());
        let next: config::AppConfig =
            serde_json::from_value(json).map_err(|e| format!("invalid value for {key}: {e}"))?;
        *cfg = next.clone();
        next
    };
    config::store_set(app, key, value)?;

    match key {
        "hotkey" | "translateHotkey" | "translateEnabled" | "triggerMode" => re_register_hotkeys(app),
        "model" => {
            if updated.keep_model_loaded {
                preload_model(app, &updated.model);
            } else {
                stop_models(&state);
            }
        }
        "keepModelLoaded" => {
            if updated.keep_model_loaded {
                preload_model(app, &updated.model);
            } else {
                stop_models(&state);
            }
        }
        "historyDays" => state.history.set_retention(app, updated.history_days),
        _ => {}
    }

    tray::refresh(app);
    let _ = app.emit("config-changed", &updated);
    Ok(updated)
}

fn word_count(text: &str) -> usize {
    text.split_whitespace().count()
}

/// Open a URL or a folder with the OS default handler.
pub(crate) fn open_with_system(target: &str) {
    #[cfg(target_os = "macos")]
    let _ = std::process::Command::new("open").arg(target).spawn();
    #[cfg(target_os = "windows")]
    let _ = std::process::Command::new("explorer").arg(target).spawn();
    #[cfg(target_os = "linux")]
    let _ = std::process::Command::new("xdg-open").arg(target).spawn();
}

/// Paste the most recent transcription again (tray item and ⌥⌘V).
pub fn paste_last(app: &AppHandle) {
    let Some(text) = app.state::<AppState>().history.last_text() else { return };
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        match paste_text_via_clipboard(&app, &text).await {
            Ok(()) => {}
            Err(e) if e == PASTE_NEEDS_PERMISSION => {
                flash_overlay(&app, "nopaste", serde_json::json!({}), 4000);
                tray::refresh(&app);
            }
            Err(e) => log::warn!("[paste-last] {e}"),
        }
    });
}

pub fn show_update_dialog(app: &AppHandle, status: &updates::UpdateStatus) {
    use tauri_plugin_dialog::{DialogExt, MessageDialogButtons};
    let latest = status.latest.clone().unwrap_or_default();
    if status.ready {
        let app2 = app.clone();
        app.dialog()
            .message(if i18n::is_portuguese() {
                format!(
                    "A versão {latest} já foi baixada. Você está na {}. Reinicie para usar a nova.",
                    status.current
                )
            } else {
                format!(
                    "Version {latest} has been downloaded. You are on {}. Restart to use the new one.",
                    status.current
                )
            })
            .title(i18n::tr("Updates", "Atualizações"))
            .buttons(MessageDialogButtons::OkCancelCustom(
                i18n::tr("Restart Now", "Reiniciar agora").to_string(),
                i18n::tr("Later", "Depois").to_string(),
            ))
            .show(move |restart| {
                if restart {
                    if let Err(e) = updates::install_pending(&app2, true) {
                        log::error!("[updates] install failed: {e}");
                    }
                }
            });
        return;
    }
    if status.newer {
        // Found, but the download failed: the page has the installer.
        app.dialog()
            .message(if i18n::is_portuguese() {
                format!("A versão {latest} está disponível. Você está na {}.", status.current)
            } else {
                format!("Version {latest} is available. You are on {}.", status.current)
            })
            .title(i18n::tr("Updates", "Atualizações"))
            .buttons(MessageDialogButtons::OkCancelCustom(
                i18n::tr("Download", "Baixar").to_string(),
                i18n::tr("Not Now", "Agora não").to_string(),
            ))
            .show(|download| {
                if download {
                    open_with_system(updates::PAGE_URL);
                }
            });
        return;
    }
    let pt = i18n::is_portuguese();
    let text = match &status.error {
        Some(err) if pt => format!(
            "Você está na versão {}. Não foi possível verificar se há outra: {err}.",
            status.current
        ),
        Some(err) => format!(
            "You are on version {}. Could not check for a newer one: {err}.",
            status.current
        ),
        None if pt => format!("Você está na versão mais recente ({}).", status.current),
        None => format!("You are on the latest version ({}).", status.current),
    };
    app.dialog()
        .message(text)
        .title(i18n::tr("Updates", "Atualizações"))
        .buttons(MessageDialogButtons::Ok)
        .show(|_| {});
}

// ============================================================================
// IPC Commands
// ============================================================================

#[tauri::command]
async fn get_config(state: State<'_, AppState>) -> Result<config::AppConfig, String> {
    let config = state.config.lock().unwrap();
    Ok(config.clone())
}

#[tauri::command]
async fn set_setting(app: AppHandle, key: String, value: serde_json::Value) -> Result<config::AppConfig, String> {
    apply_setting(&app, &key, value)
}

#[tauri::command]
async fn check_permissions() -> Result<permissions::PermissionStatus, String> {
    Ok(permissions::check_all_permissions())
}

/// The "Liberar permissões" button: prompt for what can be prompted, open
/// settings for the rest. The window polls `check_permissions` afterwards.
#[tauri::command]
async fn request_permissions(app: AppHandle) -> Result<permissions::PermissionStatus, String> {
    let status = permissions::request_all();
    tray::refresh(&app);
    Ok(status)
}

#[tauri::command]
async fn open_settings(pane: String) -> Result<(), String> {
    match pane.as_str() {
        "microphone" => permissions::request_microphone_access(),
        "accessibility" => permissions::request_accessibility_access(),
        _ => Ok(()),
    }
}

#[tauri::command]
async fn refresh_tray(app: AppHandle) -> Result<(), String> {
    tray::refresh(&app);
    Ok(())
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct Microphone {
    device_id: String,
    label: String,
}

#[tauri::command]
async fn set_microphones(app: AppHandle, microphones: Vec<Microphone>) -> Result<(), String> {
    tray::set_microphones(&app, microphones.into_iter().map(|m| (m.device_id, m.label)).collect());
    Ok(())
}

#[tauri::command]
async fn copy_to_clipboard(app: AppHandle, text: String) -> Result<bool, String> {
    use tauri_plugin_clipboard_manager::ClipboardExt;
    app.clipboard().write_text(&text).map_err(|e| e.to_string())?;
    Ok(true)
}

#[tauri::command]
async fn get_history(state: State<'_, AppState>) -> Result<Vec<history::Entry>, String> {
    Ok(state.history.list())
}

#[tauri::command]
async fn clear_history(app: AppHandle, state: State<'_, AppState>) -> Result<(), String> {
    state.history.clear(&app);
    tray::refresh(&app);
    Ok(())
}

#[tauri::command]
async fn paste_last_transcription(app: AppHandle) -> Result<(), String> {
    paste_last(&app);
    Ok(())
}

#[tauri::command]
async fn check_for_updates(app: AppHandle) -> Result<updates::UpdateStatus, String> {
    Ok(updates::check(&app).await)
}

#[tauri::command]
fn install_update(app: AppHandle) -> Result<(), String> {
    updates::install_pending(&app, true)
}

#[tauri::command]
async fn open_url(url: String) -> Result<(), String> {
    if !url.starts_with("https://") {
        return Err("only https links".to_string());
    }
    open_with_system(&url);
    Ok(())
}

/// "Testar": one short refinement round trip, timed.
#[tauri::command]
async fn test_openrouter(state: State<'_, AppState>) -> Result<u64, String> {
    let cfg = state.config.lock().unwrap().clone();
    let started = std::time::Instant::now();
    refinement::refine(
        "teste de conexão",
        &cfg.language,
        "",
        "light",
        &cfg.openrouter_model,
        &cfg.openrouter_api_key,
    )
    .await?;
    Ok(started.elapsed().as_millis() as u64)
}

#[tauri::command]
async fn get_app_info(app: AppHandle) -> Result<serde_json::Value, String> {
    Ok(serde_json::json!({
        "version": app.package_info().version.to_string(),
        "platform": std::env::consts::OS,
        "pasteLastHotkey": hotkey::PASTE_LAST_HOTKEY,
        "locale": i18n::locale(),
    }))
}

#[tauri::command]
async fn open_log_folder(app: AppHandle) -> Result<(), String> {
    let dir = app.path().app_log_dir().map_err(|e| e.to_string())?;
    open_with_system(&dir.to_string_lossy());
    Ok(())
}

/// Timings and errors from the log, without any dictated text: the log only
/// carries `[timing]` lines, server events and warnings.
#[tauri::command]
async fn get_diagnostics(app: AppHandle, state: State<'_, AppState>) -> Result<String, String> {
    let cfg = state.config.lock().unwrap().clone();
    let dir = app.path().app_log_dir().map_err(|e| e.to_string())?;
    let mut lines: Vec<String> = Vec::new();
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for entry in entries.flatten() {
            if let Ok(text) = std::fs::read_to_string(entry.path()) {
                lines.extend(
                    text.lines()
                        .filter(|l| {
                            l.contains("[timing]") || l.contains("[whisper") || l.contains("[parakeet") || l.contains("WARN") || l.contains("ERROR")
                        })
                        .map(str::to_string),
                );
            }
        }
    }
    let tail: Vec<String> = lines.iter().rev().take(150).rev().cloned().collect();
    let perms = permissions::check_all_permissions();
    Ok(format!(
        "Speech to Text {version} · {os} · {locale}\nmodel={model} refine={refine} vad={vad} model_loaded={loaded}\n\
         permissions: microphone={mic} paste={paste}\n\n{log}",
        version = app.package_info().version,
        os = std::env::consts::OS,
        locale = i18n::locale(),
        model = cfg.model,
        refine = cfg.refinement_enabled,
        vad = cfg.voice_detection,
        loaded = cfg.keep_model_loaded,
        mic = perms.microphone,
        paste = perms.accessibility,
        log = tail.join("\n"),
    ))
}

#[tauri::command]
async fn transcribe_audio_command(
    app: AppHandle,
    request: tauri::ipc::Request<'_>,
    state: State<'_, AppState>,
) -> Result<serde_json::Value, String> {
    // The WAV arrives as a raw IPC body (see bridge.js) — a JSON array of
    // numbers is ~4x bigger and has to be parsed byte by byte.
    let audio_data: Vec<u8> = match request.body() {
        tauri::ipc::InvokeBody::Raw(bytes) => bytes.clone(),
        tauri::ipc::InvokeBody::Json(v) => serde_json::from_value(v.clone()).map_err(|e| e.to_string())?,
    };
    let mode = request
        .headers()
        .get("mode")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("transcribe")
        .to_string();
    // End-to-end tests (debug builds only): replace the captured audio with
    // a WAV file, so the whole pipeline runs without a live microphone.
    #[cfg(debug_assertions)]
    let audio_data = match std::env::var("STT_E2E_WAV") {
        Ok(path) if !audio_data.is_empty() => std::fs::read(path).unwrap_or(audio_data),
        _ => audio_data,
    };
    let cfg = state.config.lock().unwrap().clone();
    // "test" is the onboarding voice check: transcribe only — no AI, no
    // paste, no history, no overlay.
    let is_test = mode == "test";
    let want_translate = mode == "translate";

    let finish_idle = |app: &AppHandle| tray::set_activity(app, tray::Activity::Idle);

    let model_path = config::get_model_path(&app, &cfg.model);
    if !models::is_installed(&app, &cfg.model) {
        let message = if i18n::is_portuguese() {
            format!("Modelo {} não encontrado", cfg.model)
        } else {
            format!("Model {} not found", cfg.model)
        };
        if !is_test {
            flash_overlay(&app, "error", serde_json::json!({ "message": message }), 2500);
        }
        finish_idle(&app);
        return Err(message);
    }

    let t_start = std::time::Instant::now();
    let audio_secs = audio_data.len().saturating_sub(44) as f64 / 32000.0;

    if audio_data.is_empty() {
        if !is_test {
            flash_overlay(&app, "nothing", serde_json::json!({}), 700);
        }
        finish_idle(&app);
        return Ok(serde_json::json!({ "text": "", "isNoise": true, "mode": mode }));
    }

    let opts = TranscribeOptions {
        use_server: cfg.keep_model_loaded,
        voice_detection: cfg.voice_detection,
    };
    let uses_parakeet = cfg.model == parakeet::MODEL;
    let engine = if uses_parakeet { Engine::Parakeet(&state.parakeet) } else { Engine::Whisper(&state.whisper) };
    let transcribe_result = transcribe_audio(
        &app,
        engine,
        &model_path,
        audio_data,
        &cfg.language,
        &whisper_prompt(&cfg),
        opts,
    )
    .await;
    // Not kept loaded: Parakeet has no one-shot mode, so its sidecar goes once the clip is done.
    if uses_parakeet && !cfg.keep_model_loaded {
        state.parakeet.stop();
    }
    let stt_ms = t_start.elapsed().as_millis();

    let original = match transcribe_result {
        Ok(r) => r,
        Err(e) => {
            // Too-short clips are a non-event, not an error.
            let empty = e.contains("too small");
            if !is_test {
                if empty {
                    flash_overlay(&app, "nothing", serde_json::json!({}), 700);
                } else {
                    flash_overlay(&app, "error", serde_json::json!({ "message": i18n::tr("Transcription failed", "A transcrição falhou") }), 2500);
                }
            }
            finish_idle(&app);
            let _ = app.emit("transcription", serde_json::json!({
                "text": "", "message": e.clone(), "error": !empty, "isNoise": empty, "mode": mode,
            }));
            return if empty { Ok(serde_json::json!({ "text": "", "isNoise": true, "mode": mode })) } else { Err(e) };
        }
    };

    if is_test {
        finish_idle(&app);
        return Ok(serde_json::json!({ "text": original.text, "isNoise": original.is_noise, "mode": mode }));
    }

    if original.is_noise {
        flash_overlay(&app, "nothing", serde_json::json!({}), 700);
        state.history.add(&app, history::Entry {
            at: history::now_ms(),
            text: String::new(),
            original: String::new(),
            kind: "nothing".to_string(),
            words: 0,
            audio_secs,
            latency_ms: stt_ms as u64,
            model: cfg.model.clone(),
        }, cfg.history_days);
        finish_idle(&app);
        tray::refresh(&app);
        let _ = app.emit("transcription", serde_json::json!({
            "text": "", "isNoise": true, "mode": mode,
        }));
        return Ok(serde_json::json!({ "text": "", "isNoise": true, "mode": mode }));
    }

    let t_llm = std::time::Instant::now();
    let mut llm_error: Option<String> = None;

    // ── Optional refinement step (runs before translate) ───────────────
    let refined_text = if cfg.refinement_enabled {
        overlay_state(&app, "refining", serde_json::json!({ "provider": "OpenRouter" }));
        match refinement::refine(
            &original.text,
            &cfg.language,
            &cfg.refinement_glossary,
            &cfg.refinement_level,
            &cfg.openrouter_model,
            &cfg.openrouter_api_key,
        )
        .await
        {
            Ok(refined) if !refined.is_empty() => refined,
            Ok(_) => original.text.clone(),
            Err(e) => {
                log::warn!("[refine] failed: {e}");
                llm_error = Some(i18n::tr("No reply from the AI · pasted unrefined", "IA sem resposta · colado sem refinar").to_string());
                original.text.clone()
            }
        }
    } else {
        original.text.clone()
    };

    // ── Optional translation step ──────────────────────────────────────
    let final_text = if want_translate {
        overlay_state(&app, "translating", serde_json::json!({ "target": cfg.target_language }));
        match translation::translate(
            &refined_text,
            &cfg.target_language,
            &cfg.openrouter_model,
            &cfg.openrouter_api_key,
        )
        .await
        {
            Ok(translated) if !translated.is_empty() => translated,
            Ok(_) => refined_text.clone(),
            Err(e) => {
                log::warn!("[translate] failed: {e}");
                llm_error = Some(i18n::tr("Translation failed · pasted the original", "Tradução falhou · colado o original").to_string());
                refined_text.clone()
            }
        }
    } else {
        refined_text.clone()
    };
    let llm_ms = t_llm.elapsed().as_millis();

    let kind = if want_translate && llm_error.is_none() {
        "translated"
    } else if cfg.refinement_enabled && llm_error.is_none() {
        "refined"
    } else {
        "local"
    };

    let _ = app.emit(
        "transcription",
        serde_json::json!({
            "text": final_text,
            "originalText": original.text,
            "translated": want_translate,
            "mode": mode,
            "message": llm_error.clone(),
            "error": llm_error.is_some(),
        }),
    );

    // Keep the overlay up through the paste so it changes at the moment the
    // text actually lands in the destination app.
    let words = word_count(&final_text);
    let paste_result = if cfg.auto_paste {
        paste_text_via_clipboard(&app, &final_text).await
    } else {
        use tauri_plugin_clipboard_manager::ClipboardExt;
        app.clipboard().write_text(final_text.clone()).map_err(|e| e.to_string())
    };
    match (&paste_result, &llm_error) {
        (Err(e), _) if e == PASTE_NEEDS_PERMISSION => {
            flash_overlay(&app, "nopaste", serde_json::json!({}), 4000);
        }
        (Err(e), _) => {
            log::warn!("[paste] {e}");
            flash_overlay(&app, "error", serde_json::json!({ "message": i18n::tr("Not pasted · text copied", "Não colou · texto copiado") }), 2500);
        }
        (Ok(()), Some(message)) => {
            flash_overlay(&app, "error", serde_json::json!({ "message": message }), 2500);
        }
        (Ok(()), None) => {
            flash_overlay(&app, "pasted", serde_json::json!({ "text": final_text, "words": words }), 900);
        }
    }

    state.history.add(&app, history::Entry {
        at: history::now_ms(),
        text: final_text.clone(),
        original: original.text.clone(),
        kind: kind.to_string(),
        words,
        audio_secs,
        latency_ms: t_start.elapsed().as_millis() as u64,
        model: cfg.model.clone(),
    }, cfg.history_days);
    finish_idle(&app);
    tray::refresh(&app);
    let _ = app.emit("history-changed", serde_json::json!({}));

    log::info!(
        "[timing] audio={audio_secs:.1}s stt={stt_ms}ms llm={llm_ms}ms total={}ms model={}",
        t_start.elapsed().as_millis(),
        cfg.model
    );

    Ok(serde_json::json!({
        "text": final_text,
        "originalText": original.text,
        "translated": want_translate,
        "isNoise": false,
        "mode": mode,
    }))
}

#[tauri::command]
async fn get_models(app: AppHandle, state: State<'_, AppState>) -> Result<Vec<models::ModelInfo>, String> {
    Ok(state.model_manager.get_models(&app).await)
}

#[tauri::command]
async fn download_model(
    app: AppHandle,
    model_name: String,
    state: State<'_, AppState>,
) -> Result<String, String> {
    let path = state.model_manager.download_model(app.clone(), model_name).await?;
    tray::refresh(&app);
    Ok(path)
}

#[tauri::command]
async fn cancel_download_model(
    model_name: String,
    state: State<'_, AppState>,
) -> Result<bool, String> {
    Ok(state.model_manager.cancel_download(model_name))
}

#[tauri::command]
async fn get_auto_launch(app: AppHandle) -> Result<bool, String> {
    use tauri_plugin_autostart::ManagerExt;
    Ok(app.autolaunch().is_enabled().unwrap_or(false))
}

#[tauri::command]
async fn set_auto_launch(app: AppHandle, enabled: bool) -> Result<bool, String> {
    use tauri_plugin_autostart::ManagerExt;
    let autostart_manager = app.autolaunch();
    if enabled {
        autostart_manager.enable().map_err(|e| e.to_string())?;
    } else {
        autostart_manager.disable().map_err(|e| e.to_string())?;
    }
    config::store_set(&app, "autoLaunch", serde_json::json!(enabled))?;
    Ok(true)
}

#[tauri::command]
async fn set_recording_hotkey(_app: AppHandle, is_recording: bool) -> Result<(), String> {
    // While the user is capturing a new hotkey combo, pause the global shortcut
    // so it doesn't trigger audio recording.
    HotkeyManager::set_paused(is_recording);
    Ok(())
}

#[tauri::command]
async fn emit_audio_level(app: AppHandle, level: f64) -> Result<(), String> {
    let _ = app.emit("audio-level", level);
    Ok(())
}

#[tauri::command]
async fn log_message(app: AppHandle, msg: String) -> Result<(), String> {
    println!("[Renderer Log] {}", msg);
    let _ = app.emit("log", msg);
    Ok(())
}

// ============================================================================
// Tauri App Setup
// ============================================================================

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    use tauri_plugin_log::{Target, log::LevelFilter};

    // Load OPENROUTER_API_KEY etc. from a .env file alongside the source tree.
    // In dev (cargo run) the cwd is `application/src-tauri`; the user's .env
    // sits one level up at `application/.env`. We try both in order.
    let _ = dotenvy::from_path("../.env");
    let _ = dotenvy::from_filename(".env");

    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            window::open_settings(app, Some("inicio"));
        }))
        .plugin(
            tauri_plugin_log::Builder::new()
                .targets([
                    Target::new(tauri_plugin_log::TargetKind::Stdout),
                    Target::new(tauri_plugin_log::TargetKind::LogDir { file_name: None }),
                    Target::new(tauri_plugin_log::TargetKind::Webview),
                ])
                .level(LevelFilter::Info)
                .build(),
        )
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            Some(vec![]),
        ))
        .plugin(tauri_plugin_store::Builder::default().build())
        .plugin(tauri_plugin_updater::Builder::default().build())
        .manage(AppState {
            config: Mutex::new(config::AppConfig::default()),
            model_manager: std::sync::Arc::new(ModelManager::new()),
            whisper: std::sync::Arc::new(whisper_server::WhisperServer::new()),
            parakeet: std::sync::Arc::new(parakeet::ParakeetServer::new()),
            history: history::History::new(),
        })
        .on_window_event(|window, event| {
            if matches!(event, WindowEvent::CloseRequested { .. }) && window.label() == "main" {
                // macOS: WKWebView suspends getUserMedia / AudioContext when
                // a window is hidden OR off-screen, which kills our warm
                // microphone. So we shrink to a 1x1 stub at the corner to keep
                // the WebView visible-enough that audio capture stays alive.
                //
                // Windows (WebView2) and Linux (WebKitGTK) don't have this
                // suspension behavior — a normal hide() works and is cleaner.
                #[cfg(target_os = "macos")]
                {
                    use tauri::{LogicalSize, PhysicalPosition, Position, Size};
                    let _ = window.set_decorations(false);
                    let _ = window.set_min_size(None::<Size>);
                    let _ = window.set_size(Size::Logical(LogicalSize { width: 1.0, height: 1.0 }));
                    let _ = window.set_position(Position::Physical(PhysicalPosition { x: 0, y: 0 }));
                }
                #[cfg(not(target_os = "macos"))]
                {
                    let _ = window.hide();
                }
                if let WindowEvent::CloseRequested { api, .. } = event {
                    api.prevent_close();
                }
            }
        })
        .setup(|app| {
            // Run as a menu bar / tray-only accessory: no Dock icon, no
            // app switcher entry. The window can still be shown via the
            // tray menu → Configurações.
            #[cfg(target_os = "macos")]
            {
                let _ = app.set_activation_policy(tauri::ActivationPolicy::Accessory);
            }

            // On Windows/Linux the tauri.conf.json stub-size (1x1 at corner)
            // would be visible and ugly. Hide the main window normally instead
            // — WebView2/WebKitGTK keep the renderer running while hidden, so
            // mic warm-up still works (unlike WKWebView on macOS).
            #[cfg(not(target_os = "macos"))]
            {
                if let Some(window) = app.get_webview_window("main") {
                    use tauri::{LogicalSize, Size};
                    let (width, height) = window::WINDOW_SIZE;
                    let _ = window.set_size(Size::Logical(LogicalSize { width, height }));
                    let _ = window.set_decorations(true);
                    let _ = window.center();
                    let _ = window.hide();
                }
            }

            log::info!("[i18n] interface {}", i18n::locale());
            config::adopt_earlier_settings(app.handle());
            let config = load_config(app.handle());

            let state = app.state::<AppState>();
            *state.config.lock().unwrap() = config.clone();
            state.history.load(app.handle(), config.history_days);

            // Load the model now, while nobody is waiting, so the first
            // dictation doesn't pay the cold read from disk.
            if config.keep_model_loaded {
                preload_model(app.handle(), &config.model);
            }

            HotkeyManager::register_all(
                app.handle(),
                &config.hotkey,
                &config.translate_hotkey,
                config.translate_enabled,
                &config.trigger_mode,
            );
            HotkeyManager::register_paste_last(app.handle());
            updates::start_background(app.handle());
            #[cfg(debug_assertions)]
            HotkeyManager::watch_e2e_trigger(app.handle());

            tray::setup_tray(app.handle()).expect("Failed to setup tray");

            // First run: open the window on the onboarding steps.
            if !config.onboarded {
                window::open_settings(app.handle(), None);
            }

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_config,
            set_setting,
            check_permissions,
            request_permissions,
            open_settings,
            refresh_tray,
            set_microphones,
            copy_to_clipboard,
            get_history,
            clear_history,
            paste_last_transcription,
            check_for_updates,
            install_update,
            open_url,
            test_openrouter,
            get_app_info,
            open_log_folder,
            get_diagnostics,
            transcribe_audio_command,
            get_models,
            download_model,
            cancel_download_model,
            get_auto_launch,
            set_auto_launch,
            set_recording_hotkey,
            emit_audio_level,
            log_message,
        ])
        .build(tauri::generate_context!())
        .expect("error building tauri application")
        .run(|app, event| {
            if let RunEvent::Exit = event {
                // A version downloaded but never restarted into is installed
                // on the way out; the next launch opens it.
                if updates::pending().is_some() {
                    if let Err(e) = updates::install_pending(app, false) {
                        log::error!("[updates] install on quit failed: {e}");
                    }
                }
                stop_models(&app.state::<AppState>());
                system_audio::restore_output();
            }
        });
}
