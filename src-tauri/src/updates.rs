//! Updates: the app keeps itself current.
//!
//! The release workflow publishes a signed manifest at
//! blob.ciromaciel.click/tools/speech-to-text/latest.json. The app checks it
//! a minute after starting and then every 6 hours, downloads a newer version
//! in the background and offers it in the tray ("Reiniciar e atualizar"). If
//! nobody clicks, the update is installed when the app quits. Only a package
//! signed with the release key (TAURI_SIGNING_PRIVATE_KEY) is ever installed.
//!
//! On Linux the .deb updates itself too: the plugin installs it with dpkg
//! through pkexec, which asks for the password in a system window.

use std::sync::Mutex;
use std::time::Duration;

use serde::Serialize;
use tauri::Manager;
use tauri_plugin_log::log;
use tauri_plugin_updater::{Update, UpdaterExt};

pub const PAGE_URL: &str = "https://ciromaciel.click/tools/speech-to-text";
const FIRST_CHECK: Duration = Duration::from_secs(60);
const EVERY: Duration = Duration::from_secs(6 * 60 * 60);

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateStatus {
    pub current: String,
    pub latest: Option<String>,
    pub url: Option<String>,
    pub newer: bool,
    /// Downloaded and waiting for a restart.
    pub ready: bool,
    /// Set when the manifest couldn't be read.
    pub error: Option<String>,
}

/// A newer version, downloaded and waiting for a restart.
struct Pending {
    update: Update,
    bytes: Vec<u8>,
}

static PENDING: Mutex<Option<Pending>> = Mutex::new(None);

/// The version downloaded and waiting in the tray, if any.
pub fn pending() -> Option<String> {
    PENDING.lock().unwrap().as_ref().map(|p| p.update.version.clone())
}

/// Check the manifest and download a newer version.
pub async fn check(app: &tauri::AppHandle) -> UpdateStatus {
    let current = app.package_info().version.to_string();
    let status = |latest: Option<String>, ready: bool, error: Option<String>| UpdateStatus {
        newer: latest.is_some(),
        url: latest.as_ref().map(|_| PAGE_URL.to_string()),
        current: current.clone(),
        latest,
        ready,
        error,
    };

    if let Some(version) = pending() {
        return status(Some(version), true, None);
    }

    let found = match app.updater() {
        Ok(updater) => updater.check().await,
        Err(e) => return status(None, false, Some(e.to_string())),
    };
    let update = match found {
        Ok(Some(update)) => update,
        Ok(None) => return status(None, false, None),
        Err(e) => {
            log::warn!("[updates] check failed: {e}");
            return status(None, false, Some(friendly(&e.to_string())));
        }
    };

    let version = update.version.clone();
    log::info!("[updates] {version} available (running {current})");
    let bytes = match update.download(|_, _| {}, || {}).await {
        Ok(bytes) => bytes,
        Err(e) => {
            log::warn!("[updates] download failed: {e}");
            return status(Some(version), false, Some(friendly(&e.to_string())));
        }
    };
    *PENDING.lock().unwrap() = Some(Pending { update, bytes });
    crate::tray::refresh(app);
    status(Some(version), true, None)
}

/// Check a minute after launch, then every 6 hours, quietly.
pub fn start_background(app: &tauri::AppHandle) {
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(FIRST_CHECK).await;
        loop {
            if pending().is_none() {
                check(&app).await;
            }
            tokio::time::sleep(EVERY).await;
        }
    });
}

/// Install the downloaded version. `restart` relaunches the new one; without
/// it (the app is quitting) the next launch opens the new version.
pub fn install_pending(app: &tauri::AppHandle, restart: bool) -> Result<(), String> {
    let pending = PENDING.lock().unwrap().take();
    let Some(Pending { update, bytes }) = pending else {
        return Err(crate::i18n::tr("no update downloaded", "nenhuma atualização baixada").to_string());
    };
    log::info!("[updates] installing {}", update.version);
    // The resident whisper-server runs from inside the bundle being replaced.
    app.state::<crate::AppState>().whisper.stop();
    update.install(bytes).map_err(|e| e.to_string())?;
    if restart {
        app.restart();
    }
    Ok(())
}

fn friendly(error: &str) -> String {
    if error.contains("error sending request") || error.contains("dns") || error.contains("connect") {
        crate::i18n::tr("no connection", "sem conexão").to_string()
    } else {
        error.to_string()
    }
}
