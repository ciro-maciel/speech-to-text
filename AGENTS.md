# Notes for coding agents

Speech to Text is a macOS menu bar app built with Tauri 2: Rust in `src-tauri/`, plain HTML, CSS and JavaScript in `src/` (no framework, no bundler). Transcription runs in whisper.cpp, shipped as two sidecar binaries.

## Layout

| Path | What it is |
| --- | --- |
| `src-tauri/src/lib.rs` | App setup, Tauri commands, the dictation pipeline |
| `src-tauri/src/hotkey.rs` | Global shortcuts: toggle and hold modes, double tap, Esc, translate, paste last |
| `src-tauri/src/whisper_server.rs` | Keeps `whisper-server` running with the model loaded; voice detection |
| `src-tauri/src/transcription.rs` | Audio to text, then paste through the clipboard, which is restored after |
| `src-tauri/src/refinement.rs`, `translation.rs` | Optional OpenRouter calls, text only, with the person's key |
| `src-tauri/src/models.rs`, `config.rs`, `history.rs` | Model downloads, settings (tauri-plugin-store), text history |
| `src-tauri/src/updates.rs` | The Tauri updater reading `latest.json` |
| `src-tauri/src/tray.rs`, `window.rs`, `permissions.rs` | Menu bar, the settings window and overlay, Microphone and Accessibility |
| `src/` | The settings window (`index.html`, `renderer.js`) and the recording overlay |
| `scripts/whisper.sh` | Builds the whisper.cpp sidecars from source and fetches the voice detector |
| `scripts/smoke-test.sh` | End-to-end check of a packaged build |
| `scripts/release/` | Signed and notarized build, publishing, the one-line installer; used by `.github/workflows/release.yml` |

## Before you say it works

```bash
bash scripts/whisper.sh
bun run build
APP="src-tauri/target/release/bundle/macos/Speech to Text.app/Contents/MacOS"
scripts/smoke-test.sh "$APP/speech-to-text" "$APP" path/to/ggml-tiny.bin path/to/jfk.wav
```

## Rules that must hold

- The audio never leaves the Mac. Network calls: model download (Hugging Face), update check (`blob.ciromaciel.click`), and Refine and Translate only when turned on. Nothing else, and no remote fonts or scripts in `src/`.
- The bundle identifier `click.ciromaciel.speech-to-text` never changes: macOS ties Microphone and Accessibility to it.
- `latest.json` and the updater's public key in `tauri.conf.json` belong to the official build; a fork changes both.
- The version lives in `package.json`; bumping it on `main` is a release.
- Bun, never npm. Code, comments and file names are in English.
- Every user-facing string exists in English and Brazilian Portuguese (en.lproj / pt-BR.lproj or the i18n module); a change that adds text adds both. The interface follows the Mac's language (first preferred language starting with `pt` → Brazilian Portuguese, anything else → English), with no in-app switch: `src/i18n.js` for the window and the overlay, `src-tauri/src/i18n.rs` (`tr(en, pt)`) for the menu bar and dialogs, `src-tauri/locales/<lang>.lproj/InfoPlist.strings` for the permission prompts. The dictation language (Whisper) and the translation target are separate settings and never follow the interface.
