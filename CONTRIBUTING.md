# Contributing

Thanks for helping. Speech to Text hears people and types into their apps, so the bar is "nothing leaves the Mac that the person didn't ask to send".

## Setup

```bash
scripts/build.sh             # → dist/Speech to Text.app
```

You need macOS 14 or later on Apple Silicon and the Xcode Command Line Tools (Swift 5.10 or later). The one dependency, FluidAudio, comes through Swift Package Manager, pinned in `Package.resolved`.

## Before you open a pull request

Build the app and run the end-to-end check on your Mac. It runs a copy of the app under another identifier, in a temporary data folder, and checks a dictation made with `say`, silence and Esc:

```bash
scripts/build.sh
scripts/check.sh
```

It needs the Parakeet model downloaded once (the app's Transcription screen). If your change touches the window, attach a capture.

## House rules

- **The audio never leaves the Mac.** Transcription stays in Parakeet, on device. The only network calls are the model download and, when the person turns them on, Refine and Translate (text only, their own key). A new one needs a reason in the pull request and a line in the README's Privacy section.
- No analytics, no account, no remote font or image.
- Code, comments and file names in English. The interface is in English and Brazilian Portuguese, following the Mac's language.
- Every user-facing string exists in English and Brazilian Portuguese, with the same keys in `Resources/en.lproj` and `Resources/pt-BR.lproj`; a change that adds text adds both.
- The bundle identifier (`click.ciromaciel.speech-to-text`) never changes: macOS ties Microphone and Accessibility to it.

## Reporting a bug

Say which macOS version, which Mac and what the app showed. The app logs to the system log: `log show --last 10m --predicate 'process == "SpeechToText"'`. Never paste an API key or a private transcript into an issue.

For anything that could expose someone's voice, text or key, read [SECURITY.md](SECURITY.md) first.
