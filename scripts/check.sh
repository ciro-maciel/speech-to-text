#!/bin/zsh
# End-to-end check of a built app on this Mac, without a voice or a keyboard:
#   scripts/check.sh [path/to/Speech to Text.app]      (default: dist/)
#
# A copy of the app runs under its own identifier (…speech-to-text.check), so it never meets
# the installed one, with STT_DATA_DIR in a temporary folder, so it never reads or writes the
# person's history or settings. Its binary is run from the shell: macOS lends it the terminal's
# Microphone permission. STT_E2E_TRIGGER drives the shortcut's handlers and STT_E2E_WAV
# replaces what the microphone heard with speech made by `say`.
#
# Needs the Parakeet model already downloaded (the app's Transcription screen); it is linked,
# not copied.
set -u
ROOT="${0:A:h:h}"
SOURCE="${1:-$ROOT/dist/Speech to Text.app}"
MODEL="$HOME/Library/Application Support/speech-to-text/models/parakeet-ultra"
ID="click.ciromaciel.speech-to-text.check"
WORK="$(mktemp -d)"
DATA="$WORK/data"
APP="$WORK/check.app"
TRIGGER="$WORK/trigger"
HISTORY="$DATA/click.ciromaciel.speech-to-text/history.json"
fails=0

[ -d "$SOURCE" ] || { print "no app at $SOURCE: run scripts/build.sh"; exit 1; }
[ -f "$MODEL/ready" ] || { print "no Parakeet model at $MODEL: download it in the app first"; exit 1; }

ok() { print "  ok   $1"; }
bad() { print "  FAIL $1"; fails=$((fails + 1)); }
count() { python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["entries"]))' "$HISTORY" 2>/dev/null || echo 0; }
last() { python3 -I -c 'import json,sys; e=json.load(open(sys.argv[1]))["entries"][0]; print(e["kind"] + " | " + e["original"])' "$HISTORY"; }
send() { print "$1" > "$TRIGGER"; sleep 0.3; }
dictate() { # wav → waits for a new history entry
    local before=$(count)
    cp "$1" "$WORK/input.wav"
    send "press transcribe"; sleep 1.5; send "release transcribe"
    for _ in {1..60}; do [ "$(count)" -gt "$before" ] && return 0; sleep 0.5; done
    return 1
}

mkdir -p "$DATA/speech-to-text/models"
ln -s "$MODEL" "$DATA/speech-to-text/models/parakeet-ultra"
cp -R "$SOURCE" "$APP"
plutil -replace CFBundleIdentifier -string "$ID" "$APP/Contents/Info.plist"
codesign --force --sign - --identifier "$ID" "$APP" 2>/dev/null
defaults delete "$ID" >/dev/null 2>&1
defaults write "$ID" importedTauriSettings -bool true
defaults write "$ID" dictationShortcut -data "$(printf none | xxd -p)"
defaults write "$ID" translateShortcut -data "$(printf none | xxd -p)"
defaults write "$ID" autoPaste -bool false
defaults write "$ID" triggerMode hold
say -v Luciana -o "$WORK/speech.aiff" "O gabinete do governador afirmou que dezenove dos feridos eram agentes policiais."
afconvert -f WAVE -d LEI16@16000 -c 1 "$WORK/speech.aiff" "$WORK/speech.wav"
python3 -I -c 'import sys,wave; w=wave.open(sys.argv[1],"wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(bytes(96000)); w.close()' "$WORK/silence.wav"
: > "$TRIGGER"
CLIPBOARD="$(pbpaste)"

print "Speech to Text — end-to-end check"
cp "$WORK/silence.wav" "$WORK/input.wav"
STT_DATA_DIR="$DATA" STT_E2E_TRIGGER="$TRIGGER" STT_E2E_WAV="$WORK/input.wav" "$APP/Contents/MacOS/speech-to-text" >"$WORK/app.log" 2>&1 &
PID=$!
for _ in {1..120}; do grep -q "\[parakeet\] preloaded" "$WORK/app.log" && grep -q "microphone open" "$WORK/app.log" && break; sleep 0.5; done
grep -q "\[parakeet\] preloaded" "$WORK/app.log" && ok "starts, loads Parakeet and opens the microphone" || bad "did not load: $(tail -3 "$WORK/app.log")"
[ "$(count)" = 0 ] && ok "nothing dictated on its own" || bad "dictated before any command"

if dictate "$WORK/speech.wav"; then
    last | grep -qi "governador" && ok "dictation → $(last)" || bad "wrong text: $(last)"
else
    bad "the dictation never finished"
fi
if dictate "$WORK/silence.wav"; then
    last | grep -q "^nothing" && ok "silence pastes nothing" || bad "silence became text: $(last)"
else
    bad "the silent dictation never finished"
fi
# A chosen microphone, the way the select chooses it: the default input, but by its identifier.
# Choosing a device used to loop the engine and deliver nothing.
cat > "$WORK/uid.swift" <<'SWIFT'
import CoreAudio
var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
var u = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var uid: Unmanaged<CFString>?; var us = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
AudioObjectGetPropertyData(id, &u, 0, nil, &us, &uid)
print(uid!.takeRetainedValue())
SWIFT
UID="$(swift "$WORK/uid.swift" 2>/dev/null)"
send "microphone $UID"; sleep 1.5
if dictate "$WORK/speech.wav"; then
    last | grep -qi "governador" && ok "with a chosen microphone ($UID)" || bad "chosen microphone, wrong text: $(last)"
else
    bad "a chosen microphone delivered no audio ($UID)"
fi
send "microphone default"; sleep 1

before=$(count); cp "$WORK/speech.wav" "$WORK/input.wav"
send "press transcribe"; sleep 1; send "escape"; sleep 2
[ "$(count)" = "$before" ] && grep -q "\[dictation\] cancelled" "$WORK/app.log" && ok "Esc cancels" || bad "Esc did not cancel"
print "  memory: $(footprint -p $PID 2>/dev/null | sed -n 's/.*Footprint: \([0-9.]* [MKG]B\).*/\1/p' | head -1)"

kill $PID 2>/dev/null; wait $PID 2>/dev/null
print -n "$CLIPBOARD" | pbcopy
defaults delete "$ID" >/dev/null 2>&1
rm -rf "$WORK"
print "$([ $fails = 0 ] && echo "Check passed" || echo "$fails failure(s)")"
exit $fails
