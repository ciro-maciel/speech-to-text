/**
 * Tauri IPC bridge — uses the window.__TAURI__ globals (withGlobalTauri: true).
 *
 * Runs synchronously at script-load time so window.api is available before
 * deferred module scripts (renderer.js) execute.
 */

(function initBridge() {
  if (!window.__TAURI__) {
    console.error('[bridge] Tauri globals not found. Make sure withGlobalTauri is true.');
    return;
  }

  const { invoke } = window.__TAURI__.core;
  const { listen } = window.__TAURI__.event;
  const on = (event) => (callback) => listen(event, (e) => callback(e.payload));

  window.api = {
    // Settings: one generic setter, keyed by the camelCase config field.
    getConfig: () => invoke('get_config'),
    setSetting: (key, value) => invoke('set_setting', { key, value }),
    onConfigChanged: on('config-changed'),
    onNavigate: on('navigate'),

    // Hotkey capture pauses the global shortcuts while the user types a combo.
    setRecordingHotkey: (isRecording) => invoke('set_recording_hotkey', { isRecording }),

    // Microphones are enumerated here and mirrored into the tray menu.
    setMicrophones: (microphones) => invoke('set_microphones', { microphones }),

    // Permissions
    checkPermissions: () => invoke('check_permissions'),
    requestPermissions: () => invoke('request_permissions'),
    openSettings: (pane) => invoke('open_settings', { pane: String(pane) }),
    refreshTray: () => invoke('refresh_tray'),

    // Transcription. The WAV goes as a raw IPC body — far cheaper than a
    // JSON number array. mode: 'transcribe' | 'translate' | 'test'.
    sendAudioForTranscription: (audioData, mode = 'transcribe') =>
      invoke('transcribe_audio_command', new Uint8Array(audioData), { headers: { mode } }),
    onTranscription: on('transcription'),
    onStartRecording: on('start-recording'),
    onStopRecording: on('stop-recording'),
    onCancelRecording: on('cancel-recording'),
    sendAudioLevel: (level) => invoke('emit_audio_level', { level }),

    // History
    getHistory: () => invoke('get_history'),
    clearHistory: () => invoke('clear_history'),
    pasteLast: () => invoke('paste_last_transcription'),
    onHistoryChanged: on('history-changed'),
    copyToClipboard: (text) => invoke('copy_to_clipboard', { text }),

    // Models
    getModels: () => invoke('get_models'),
    downloadModel: (modelName) => invoke('download_model', { modelName }),
    cancelDownloadModel: (modelName) => invoke('cancel_download_model', { modelName }),
    onModelDownloadProgress: on('model-download-progress'),

    // AI provider
    testOpenrouter: () => invoke('test_openrouter'),

    // System
    getAutoLaunch: () => invoke('get_auto_launch'),
    setAutoLaunch: (enabled) => invoke('set_auto_launch', { enabled }),
    getAppInfo: () => invoke('get_app_info'),
    checkForUpdates: () => invoke('check_for_updates'),
    installUpdate: () => invoke('install_update'),
    openUrl: (url) => invoke('open_url', { url }),
    openLogFolder: () => invoke('open_log_folder'),
    getDiagnostics: () => invoke('get_diagnostics'),

    // Forward renderer logs to the Rust stdout (dev debugging)
    logToMain: async (msg) => { try { await invoke('log_message', { msg }); } catch (e) {} },
  };

  // The overlay window uses this one.
  window.overlayApi = {
    onAudioLevel: on('audio-level'),
    onState: on('overlay-state'),
    requestPermissions: () => invoke('request_permissions'),
  };
})();
