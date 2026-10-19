# Speech to Text by Ciro Cesar Maciel

**Dictation for the Mac: press a key, speak, and the text is typed where your cursor is.**

Transcription runs on your Mac with [whisper.cpp](https://github.com/ggml-org/whisper.cpp). Your voice is never uploaded: the audio becomes text on your machine and is thrown away. No account, no minute quota, no telemetry. A menu bar app built with Tauri and Rust.

[Português](README.pt-BR.md)

![Speech to Text: the home screen, with the shortcuts, today's count and the last transcriptions](docs/overview.webp)

## Install

```bash
curl -fsSL https://blob.ciromaciel.click/tools/speech-to-text/install.sh | bash
```

The script downloads the latest `.dmg`, copies Speech to Text to `/Applications` and opens it.

Prefer the disk image? [Download Speech-to-Text-macos.dmg](https://blob.ciromaciel.click/tools/speech-to-text/latest/Speech-to-Text-macos.dmg). Open it and drag Speech to Text to Applications. It is signed with Developer ID and notarized by Apple, so macOS opens it with no warning.

On first start, macOS asks for two permissions: **Microphone** (to hear you) and **Accessibility** (to paste the text where your cursor is). Installed copies keep themselves up to date.

## How it works

1. Put the cursor where the text should go, in any app.
2. Press **Cmd + Shift + Space** and speak. A small indicator shows it is listening.
3. Press again (or, in hold mode, let go). The text is pasted at the cursor, punctuated and capitalized.

| Shortcut | What it does |
| --- | --- |
| Cmd + Shift + Space | Dictate. Toggle by default; hold-to-talk with double tap for hands-free is one setting away |
| Cmd + Shift + T | Dictate and paste the text translated into the language you picked (optional, see below) |
| Cmd + Option + V | Paste the last transcription again |
| Esc | Cancel while recording; nothing is pasted |

Every shortcut can be changed in the settings window, opened from the menu bar icon.

## What it does

| Feature | Detail |
| --- | --- |
| Local transcription | whisper.cpp with Metal, kept loaded in memory so the first word does not wait for a cold start |
| Models | tiny, base, small, medium and large-v3-turbo; the app downloads the one you choose from Hugging Face |
| Languages | Portuguese, English, Spanish, French, German, Italian, or automatic detection |
| Interface | English and Brazilian Portuguese, following the Mac's language |
| Voice detection | Silero VAD trims silence before Whisper sees the audio |
| Glossary | Names, brands and acronyms written the way you registered them |
| Refine and translate | Optional. Cleans up hesitations or translates the dictation through [OpenRouter](https://openrouter.ai), with your own key and the model you pick |
| History | What you dictated, text only, kept on your Mac for 7 or 30 days, or only in memory |
| Clipboard | Used for under half a second to paste, then restored to what it held before |

## Privacy

What leaves your Mac, and only then:

- **Downloading a model**, from Hugging Face, when you choose one.
- **Checking for updates**, from `blob.ciromaciel.click`, a minute after start and every 6 hours.
- **Refine and translate**, only if you turn them on: the transcribed text (never the audio) goes to OpenRouter with your key.

Nothing else. The interface font is bundled with the app, there is no analytics and no account.

## Build it yourself

You need the Xcode Command Line Tools, [Rust](https://rustup.rs), [Bun](https://bun.sh) and CMake (`brew install cmake`).

```bash
git clone https://github.com/ciro-maciel/speech-to-text.git
cd speech-to-text
bun install
bash scripts/whisper.sh      # builds whisper.cpp from source and fetches the voice detector
bun run dev                  # or: bun run build → src-tauri/target/release/bundle
```

`scripts/whisper.sh` builds `whisper-cli` and `whisper-server` from a pinned whisper.cpp tag and places them where Tauri expects its sidecars. The speech models are not in the repository: the app downloads them on demand into `~/Library/Application Support/speech-to-text/models`.

A local build is signed ad hoc, so macOS asks for Microphone and Accessibility again after each rebuild. The official build is signed with Developer ID (`scripts/release/build-mac.sh`).

For development, an `.env` file at the repository root can set `OPENROUTER_API_KEY` and `OPENROUTER_MODEL`, the defaults of the Refine and Translate settings.

Check a build end to end on your Mac (the app runs with a throwaway home folder and never touches your settings):

```bash
scripts/smoke-test.sh "src-tauri/target/release/bundle/macos/Speech to Text.app/Contents/MacOS/speech-to-text" \
    src-tauri/target/release/bundle/macos/"Speech to Text.app"/Contents/MacOS \
    path/to/ggml-tiny.bin path/to/jfk.wav
```

## Limits

- Published for macOS 11 or newer on Apple Silicon only. The code is Tauri and also builds for Windows and Linux, but those builds are not published or maintained right now.
- Pasting needs Accessibility permission; without it, the text stays on the clipboard.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE). whisper.cpp, the Silero voice detector, Montserrat and the icons keep their own licenses: see [NOTICE](NOTICE).

---

Made by [Ciro Cesar Maciel](https://ciromaciel.click/?ref=oss-speech-to-text). I build tools and show how to use them: more [free tools](https://ciromaciel.click/tools?ref=oss-speech-to-text) and [the Speech to Text page](https://ciromaciel.click/tools/speech-to-text?ref=oss-speech-to-text).

**Want the next one?** [Follow @ciro-maciel](https://github.com/ciro-maciel) for the next open-source tools, and click **Watch → Custom → Releases** above to hear about every new version.
