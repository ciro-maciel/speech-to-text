//! Transcription history.
//!
//! Text only — audio is never kept. Entries always live in memory for the
//! session (so "paste last" works even with history off); they are written
//! to disk only when the user keeps history for 7 or 30 days.

use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use tauri_plugin_store::StoreExt;

const STORE_FILE: &str = "history.json";
const MAX_ENTRIES: usize = 200;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    /// Unix epoch, milliseconds.
    pub at: u64,
    /// What was pasted.
    pub text: String,
    /// Raw Whisper output, before refinement or translation.
    pub original: String,
    /// "local" | "refined" | "translated" | "nothing"
    pub kind: String,
    pub words: usize,
    pub audio_secs: f64,
    /// From the end of speech to the text being ready.
    pub latency_ms: u64,
    /// Whisper model used, for the per-model timing in settings.
    #[serde(default)]
    pub model: String,
}

pub struct History {
    entries: Mutex<Vec<Entry>>,
}

pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

impl History {
    pub fn new() -> Self {
        Self { entries: Mutex::new(Vec::new()) }
    }

    pub fn load(&self, app: &tauri::AppHandle, days: u32) {
        if days == 0 {
            return;
        }
        let Ok(store) = app.store(STORE_FILE) else { return };
        let loaded: Vec<Entry> = store
            .get("entries")
            .and_then(|v| serde_json::from_value(v).ok())
            .unwrap_or_default();
        *self.entries.lock().unwrap() = loaded;
        self.prune(days);
    }

    pub fn add(&self, app: &tauri::AppHandle, entry: Entry, days: u32) {
        {
            let mut entries = self.entries.lock().unwrap();
            entries.insert(0, entry);
            entries.truncate(MAX_ENTRIES);
        }
        self.prune(days);
        self.persist(app, days);
    }

    pub fn list(&self) -> Vec<Entry> {
        self.entries.lock().unwrap().clone()
    }

    /// Most recent entry that actually pasted something.
    pub fn last_text(&self) -> Option<String> {
        self.entries
            .lock()
            .unwrap()
            .iter()
            .find(|e| e.kind != "nothing" && !e.text.is_empty())
            .map(|e| e.text.clone())
    }

    pub fn recent_texts(&self, n: usize) -> Vec<String> {
        self.entries
            .lock()
            .unwrap()
            .iter()
            .filter(|e| e.kind != "nothing" && !e.text.is_empty())
            .take(n)
            .map(|e| e.text.clone())
            .collect()
    }

    pub fn clear(&self, app: &tauri::AppHandle) {
        self.entries.lock().unwrap().clear();
        if let Ok(store) = app.store(STORE_FILE) {
            store.delete("entries");
            let _ = store.save();
        }
    }

    /// Apply a new retention setting: 0 wipes the file, keeps the session.
    pub fn set_retention(&self, app: &tauri::AppHandle, days: u32) {
        self.prune(days);
        self.persist(app, days);
    }

    fn prune(&self, days: u32) {
        if days == 0 {
            return;
        }
        let cutoff = now_ms().saturating_sub(days as u64 * 24 * 60 * 60 * 1000);
        self.entries.lock().unwrap().retain(|e| e.at >= cutoff);
    }

    fn persist(&self, app: &tauri::AppHandle, days: u32) {
        let Ok(store) = app.store(STORE_FILE) else { return };
        if days == 0 {
            store.delete("entries");
        } else {
            let entries = self.list();
            store.set("entries", serde_json::json!(entries));
        }
        let _ = store.save();
    }
}
