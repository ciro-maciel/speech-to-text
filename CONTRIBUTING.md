# Contributing

Thanks for helping. Speech to Text hears people and types into their apps, so the bar is "nothing leaves the Mac that the person didn't ask to send".

## Setup

```bash
bun install
bash scripts/whisper.sh      # whisper.cpp sidecars and the voice detector
bun run dev
```

You need the Xcode Command Line Tools, Rust, Bun and CMake. Use Bun, not npm: there is one lockfile, `bun.lock`.

## Before you open a pull request

Build the app and run the end-to-end check on your Mac. It transcribes a known sample with both sidecars, then starts the packaged app with a throwaway home folder and waits for it to load the model:

```bash
bun run build
curl -fsSLo /tmp/jfk.wav https://github.com/ggml-org/whisper.cpp/raw/v1.8.4/samples/jfk.wav
curl -fsSLo /tmp/ggml-tiny.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin
APP="src-tauri/target/release/bundle/macos/Speech to Text.app/Contents/MacOS"
scripts/smoke-test.sh "$APP/speech-to-text" "$APP" /tmp/ggml-tiny.bin /tmp/jfk.wav
```

Quit any running Speech to Text first: a second copy hands over to the open one and exits. If your change touches the window, attach a capture.

## House rules

- **The audio never leaves the Mac.** Transcription stays in whisper.cpp, on device. The only network calls are the model download, the update check and, when the person turns them on, Refine and Translate (text only, their own key). A new one needs a reason in the pull request and a line in the README's Privacy section.
- No analytics, no account, no remote font or script: the window loads only what is in `src/`.
- Code, comments and file names in English. The interface is in English and Brazilian Portuguese, following the Mac's language.
- Every user-facing string exists in English and Brazilian Portuguese (en.lproj / pt-BR.lproj or the i18n module); a change that adds text adds both. In this app that is `src/i18n.js` for the window and the overlay, `src-tauri/src/i18n.rs` (`tr(en, pt)`) for the menu bar and dialogs, and `src-tauri/locales/<lang>.lproj/InfoPlist.strings` for the permission prompts.
- The bundle identifier (`click.ciromaciel.speech-to-text`) never changes: macOS ties Microphone and Accessibility to it.

## Reporting a bug

Say which macOS version, which Mac, which model and what the app showed. The log folder is one click away in the settings window. Never paste an API key or a private transcript into an issue.

For anything that could expose someone's voice, text or key, read [SECURITY.md](SECURITY.md) first.
