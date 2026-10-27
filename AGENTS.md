# Notes for coding agents

Speech to Text is a native macOS menu bar app: AppKit and SwiftUI, one Swift package (`Package.swift`, FluidAudio its only dependency) wrapped into `dist/Speech to Text.app` by `scripts/build.sh`. Transcription is NVIDIA Parakeet on the Neural Engine, in the app's own process. Versions 1.x were a Tauri app; the last one is commit `a969093`.

## Layout

| Path | What it is |
| --- | --- |
| `Sources/SpeechToText/main.swift` | The app: menu bar glyph and menu, global shortcuts, the window, single instance, end-to-end commands |
| `Sources/SpeechToText/Dictation.swift` | The shortcut's state machine (hold, toggle, double tap, Esc) and the path from audio to pasted text |
| `Sources/SpeechToText/Transcriber.swift` | Parakeet through FluidAudio: download, load, transcribe |
| `Sources/SpeechToText/Recorder.swift` | The microphone: AVAudioEngine to 16 kHz mono, device choice, warm pre-roll, level |
| `Sources/SpeechToText/OpenRouter.swift` | Optional Refine and Translate, text only, with the person's key |
| `Sources/SpeechToText/System.swift` | Paste (clipboard + ⌘V), mute while dictating, tones, permissions, login item |
| `Sources/SpeechToText/Settings.swift`, `History.swift` | Settings (UserDefaults, the key in the Keychain), the one-time import of the 1.x settings, text history |
| `Sources/SpeechToText/Overlay.swift` | The overlay over other apps |
| `Sources/SpeechToText/Screens.swift` | The window's panes |
| `Sources/SpeechToText/MacShell.swift`, `Theme.swift`, `Components.swift`, `Controls.swift` | The house frame and controls, the same as Cleaner and the Assistant |
| `Resources/` | App icon, Montserrat, Tabler and menu bar icons as template PDFs, `en.lproj` and `pt-BR.lproj` |
| `scripts/build.sh` | Builds and signs the app |
| `scripts/dist.sh` | Bumps the patch version, builds, packs and notarizes the `.dmg`, installs it |
| `scripts/check.sh` | End-to-end check of a built app |
| `scripts/assets.mjs` | Regenerates the icon PDFs |
| `scripts/release/` | `.dmg`, publishing to blob.ciromaciel.click, the one-line installer; used by `.github/workflows/release.yml` |

## Before you say it works

```bash
scripts/build.sh
scripts/check.sh
```

`check.sh` runs a copy of the app under another identifier with `STT_DATA_DIR` in a temporary folder: it never touches the installed app, its history or its settings. The same hooks (`STT_E2E_TRIGGER`, `STT_E2E_WAV`, `STT_DATA_DIR`) drive any other check; never run one against the person's own data folder.

## Rules that must hold

- The audio never leaves the Mac. Network calls: the model download (Hugging Face), and Refine and Translate only when turned on. Nothing else, and no remote fonts or images.
- The bundle identifier `click.ciromaciel.speech-to-text` never changes, and builds are signed with the same identity: macOS ties Microphone and Accessibility to both.
- The model folder (`~/Library/Application Support/speech-to-text/models/parakeet-ultra`, with its `ready` marker) and `history.json` keep the 1.x layout, so moving between versions loses nothing.
- The version lives in `VERSION`. Publishing is the release workflow, run by hand.
- `latest.json` on blob.ciromaciel.click keeps the 1.x updater's shape (`version`, `notes`, `pub_date`, `platforms.darwin-aarch64.{signature,url}`), pointing to `<version>/Speech-to-Text-<version>-macos.app.tar.gz` signed with the Tauri updater key: that is how 1.x copies move to 2. 2.0.3 was published that way by hand (the archive signed with `tauri signer sign`, uploaded with `wrangler r2 object put`). `scripts/release/publish-mac.sh`, Cleaner's, writes another shape and would strand 1.x copies: change it before using it.
- Code, comments and file names are in English.
- Every user-facing string exists in English and Brazilian Portuguese: `Resources/en.lproj` and `Resources/pt-BR.lproj` (`Localizable.strings`, and `InfoPlist.strings` for the permission prompts), always the same keys in both. Every on-screen string goes through `L(...)`. The interface follows the Mac's language; the spoken language and the translation target are settings of their own.
- The window follows the house frame (Cleaner's): logotype, grouped menu, status line, version line. Icons only from Tabler, as template PDFs made by `scripts/assets.mjs`.
