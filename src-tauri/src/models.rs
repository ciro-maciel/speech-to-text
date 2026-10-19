use tauri::Emitter;
use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicBool, Ordering};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tokio::io::AsyncWriteExt;

use crate::config::get_model_path;

pub const AVAILABLE_MODELS: [&str; 5] = ["tiny", "base", "small", "medium", "large-v3-turbo"];
const BASE_URL: &str = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelInfo {
    pub name: String,
    pub exists: bool,
    pub size: u64,
    pub path: String,
}

#[derive(Clone)]
pub struct ModelManager {
    pub downloading: Arc<Mutex<HashMap<String, Arc<AtomicBool>>>>,
}

impl ModelManager {
    pub fn new() -> Self {
        Self {
            downloading: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub async fn get_models(&self, app: &tauri::AppHandle) -> Vec<ModelInfo> {
        let mut models = Vec::new();
        for name in AVAILABLE_MODELS {
            let path = get_model_path(app, name);
            let mut exists = false;
            let mut size = 0u64;

            if path.exists() {
                if let Ok(meta) = std::fs::metadata(&path) {
                    size = meta.len();
                    exists = true;
                }
            }

            models.push(ModelInfo {
                name: name.to_string(),
                exists,
                size,
                path: path.to_string_lossy().to_string(),
            });
        }
        models
    }

    pub fn get_model_path_str(&self, app: &tauri::AppHandle, model_name: &str) -> String {
        get_model_path(app, model_name).to_string_lossy().to_string()
    }

    pub async fn download_model(
        &self,
        app: tauri::AppHandle,
        model_name: String,
    ) -> Result<String, String> {
        if !AVAILABLE_MODELS.contains(&model_name.as_str()) {
            return Err(format!("Invalid model name: {}", model_name));
        }

        let dest_path = get_model_path(&app, &model_name);
        let url = format!("{}-{}.bin", BASE_URL, model_name);

        let cancel_flag = Arc::new(AtomicBool::new(false));
        {
            let mut downloads = self.downloading.lock().unwrap();
            downloads.insert(model_name.clone(), cancel_flag.clone());
        }

        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(600))
            .build()
            .map_err(|e| e.to_string())?;

        let mut response = client.get(&url).send().await.map_err(|e| e.to_string())?;

        // Follow redirects (reqwest does this by default, but handle status)
        if !response.status().is_success() {
            // Shown after "Download failed:" in the window, in either language.
            return Err(format!("HTTP {}", response.status()));
        }

        let total_length = response.content_length().unwrap_or(0);
        let mut downloaded_length: u64 = 0;

        if let Some(parent) = dest_path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }

        let mut file = tokio::fs::File::create(&dest_path)
            .await
            .map_err(|e| e.to_string())?;

        while let Some(chunk) = response.chunk().await.map_err(|e| e.to_string())? {
            if cancel_flag.load(Ordering::Relaxed) {
                let _ = tokio::fs::remove_file(&dest_path).await;
                {
                    let mut downloads = self.downloading.lock().unwrap();
                    downloads.remove(&model_name);
                }
                return Err("Download cancelled".to_string());
            }

            downloaded_length += chunk.len() as u64;
            file.write_all(&chunk).await.map_err(|e| e.to_string())?;

            if total_length > 0 {
                let percent = (downloaded_length as f64 / total_length as f64) * 100.0;
                let _ = app.emit("model-download-progress", serde_json::json!({
                    "model": model_name,
                    "progress": percent,
                    "downloaded": downloaded_length,
                    "total": total_length,
                }));
            }
        }

        file.flush().await.map_err(|e| e.to_string())?;

        {
            let mut downloads = self.downloading.lock().unwrap();
            downloads.remove(&model_name);
        }

        Ok(dest_path.to_string_lossy().to_string())
    }

    pub fn cancel_download(&self, model_name: String) -> bool {
        if let Some(cancel_flag) = self.downloading.lock().unwrap().get(&model_name) {
            cancel_flag.store(true, Ordering::Relaxed);
            true
        } else {
            false
        }
    }
}
