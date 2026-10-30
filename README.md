# Speech to Text by Ciro Cesar Maciel

**Dictation for the Mac: press a key, speak, and the text is typed where your cursor is.**

One of [six free, open-source Mac apps](#more-from-ciro-cesar-maciel) by [Ciro Cesar Maciel](https://ciromaciel.click/?ref=oss-speech-to-text).

**[Watch the 1-minute video](https://youtu.be/FjEQF7LmHqg)**

[![As seen on Open Source Alternatives](https://www.opensourcealternatives.to/badge-osa.svg)](https://www.opensourcealternatives.to) [![Speech to Text by Ciro Cesar Maciel | AlternativeTo](https://alternativeto.net/static/badges/badge-compact-color.svg)](https://alternativeto.net/software/speech-to-text-by-ciro-cesar-maciel/about/?utm_source=badge&utm_medium=referral)

Transcription runs on your Mac, with NVIDIA Parakeet on the Neural Engine through [FluidAudio](https://github.com/FluidInference/FluidAudio). Your voice is never uploaded: the audio becomes text on your machine and is thrown away. No account, no minute quota, no telemetry. A native menu bar app in Swift: 22 MB on disk, about 60 MB of memory with the model loaded.

[Português](README.pt-BR.md)

![Speech to Text: the home screen, with the shortcuts, today's count and the last transcriptions](docs/overview.webp)

## Install

```bash
curl -fsSL https://blob.ciromaciel.click/tools/speech-to-text/install.sh | bash
```

The script downloads the latest `.dmg`, copies Speech to Text to `/Applications` and opens it.

With [Homebrew](https://github.com/ciro-maciel/homebrew-tap): `brew install --cask ciro-maciel/tap/ciro-speech-to-text`.

Prefer the disk image? [Download Speech-to-Text-macos.dmg](https://blob.ciromaciel.click/tools/speech-to-text/latest/Speech-to-Text-macos.dmg). Open it and drag Speech to Text to Applications. It is signed with Developer ID and notarized by Apple, so macOS opens it with no warning.

On first start, macOS asks for two permissions: **Microphone** (to hear you) and **Accessibility** (to paste the text where your cursor is), and the app opens on Transcription to download the speech model (643 MB, once).

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
| Local transcription | NVIDIA Parakeet on the Neural Engine, in the app's own process. On Brazilian Portuguese it made fewer errors than Whisper large-v3-turbo (3.6% against 3.7% on short sentences, 3.5% against 21.6% on two-minute dictations, where whisper.cpp dropped whole sentences), in about 80 MB instead of 2 GB. Two minutes of speech become text in about half a second |
| Languages | The 25 European languages Parakeet knows, Portuguese and English included |
| Interface | English and Brazilian Portuguese, following the Mac's language |
| Silence | Parakeet returns nothing for silence and room noise, so a press with no speech pastes nothing |
| Microphone | Opens on the shortcut and a tone says when to speak; closed between dictations, so the orange dot is off. Optionally kept ready, with no wait and the last 300 ms kept |
| Glossary | Names, brands and acronyms that Refine writes the way you registered them |
| Refine and translate | Optional. Cleans up hesitations or translates the dictation through [OpenRouter](https://openrouter.ai), with your own key and the model you pick |
| History | What you dictated, text only, kept on your Mac for 7 or 30 days, or only in memory |
| Clipboard | Holds the last dictation, which is pasted from it; what it held before is replaced |

## Privacy

What leaves your Mac, and only then:

- **Downloading the model**, from Hugging Face, once.
- **Refine and translate**, only if you turn them on: the transcribed text (never the audio) goes to OpenRouter with your key.

Nothing else. The interface font is bundled with the app, there is no analytics and no account. The OpenRouter key is kept in the macOS Keychain.

## Build it yourself

You need macOS 14 or later on Apple Silicon and the Xcode Command Line Tools (Swift 5.10 or later).

```bash
git clone https://github.com/ciro-maciel/speech-to-text.git
cd speech-to-text
scripts/build.sh             # → dist/Speech to Text.app
```

The build is a Swift package (FluidAudio is its one dependency) wrapped into the app bundle by `scripts/build.sh`. The speech model is not in the repository: the app downloads it on demand into `~/Library/Application Support/speech-to-text/models/parakeet-ultra`.

Without a Developer ID certificate the build is signed ad hoc, so macOS asks for Microphone and Accessibility again after each rebuild. `scripts/dist.sh` bumps the version, builds, packs the `.dmg`, has Apple notarize it (keychain profile `notary`) and installs it.

## Limits

- macOS 14 or newer on Apple Silicon.
- Pasting needs Accessibility permission; without it, the text stays on the clipboard.
- No automatic updates yet: install the new version the same way as the first.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE). FluidAudio, the Parakeet model, Montserrat and the icons keep their own licenses: see [NOTICE](NOTICE).

---

## More from Ciro Cesar Maciel

I build software on my own, with a team of AI agents, and open what I can. Six native Mac apps, all free, MIT, signed and notarized by Apple, in English and Brazilian Portuguese: [Cleaner](https://github.com/ciro-maciel/cleaner), the Mac cleaner that shows you everything before it deletes anything · [Screenshots](https://github.com/ciro-maciel/screenshots), capture, annotate and record the screen, with nothing leaving your Mac · [Speech to Text](https://github.com/ciro-maciel/speech-to-text), dictation by shortcut, with Parakeet running on your Mac (this one) · [Assistant](https://github.com/ciro-maciel/voice-assistant), Claude Code by voice · [Windows](https://github.com/ciro-maciel/windows), snap windows into place with a shortcut or by dragging them to the edge · [Text to Speech](https://github.com/ciro-maciel/text-to-speech), select text in any app and hear it read aloud.

Beyond the apps: [free tools for the browser](https://ciromaciel.click/tools?ref=oss-speech-to-text), [books](https://ciromaciel.click/books?ref=oss-speech-to-text), and [Infrastructure](https://myinfrastructure.click/?ref=oss-speech-to-text), the infrastructure AI agents already know how to run.

**Follow along.** [Follow @ciro-maciel](https://github.com/ciro-maciel) for the next open-source apps, click **Watch → Custom → Releases** above for every new version, and see how it is all made on [YouTube](https://www.youtube.com/@ciro-maciel) and at [ciromaciel.click](https://ciromaciel.click/?ref=oss-speech-to-text).
