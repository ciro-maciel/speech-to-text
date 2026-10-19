#!/bin/bash
#
# Installs Speech to Text with one line, on a Mac with Apple Silicon:
#
#   curl -fsSL https://blob.ciromaciel.click/tools/speech-to-text/install.sh | bash
#
# Downloads the latest .dmg (signed with Developer ID and notarized by Apple), copies the
# app to /Applications and opens it. publish-mac.sh uploads this file as install.sh.

set -euo pipefail

BASE="https://blob.ciromaciel.click/tools/speech-to-text"
PAGE="https://ciromaciel.click/tools/speech-to-text"
APP="Speech to Text.app"

WORK="$(mktemp -d)"
cleanup() {
    hdiutil detach "$WORK/volume" -quiet 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

[ "$(uname -s)" = Darwin ] || { echo "Speech to Text is published for the Mac only. More at $PAGE"; exit 1; }
[ "$(uname -m)" = arm64 ] || { echo "Speech to Text needs a Mac with Apple Silicon (M1 or newer)."; exit 1; }

TARGET="/Applications"
[ -w "$TARGET" ] || { TARGET="$HOME/Applications"; mkdir -p "$TARGET"; }

echo "Downloading Speech to Text…"
curl -fL --progress-bar -o "$WORK/app.dmg" "$BASE/latest/Speech-to-Text-macos.dmg"
hdiutil attach -nobrowse -readonly -quiet -mountpoint "$WORK/volume" "$WORK/app.dmg"

# An open copy would keep running the old version.
osascript -e 'quit app "Speech to Text"' >/dev/null 2>&1 || true
sleep 1

rm -rf "${TARGET:?}/$APP"
cp -R "$WORK/volume/$APP" "$TARGET/"

echo "Installed in $TARGET. Opening…"
open "$TARGET/$APP"
