#!/bin/bash
# Builds "dist/Speech to Text.app": SwiftPM for the binary (FluidAudio is a package), then the
# bundle around it. Command Line Tools are enough.
#   scripts/build.sh
#
# Signed with the Developer ID when the keychain has it (the official build, hardened runtime),
# else ad hoc: macOS ties Microphone and Accessibility to the signature, so the official
# identity keeps them from one version to the next and from the Tauri build to this one.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
APP="$ROOT/dist/Speech to Text.app"
RESOURCES="$APP/Contents/Resources"

SWIFT=(swift build --package-path "$ROOT" -c release --arch arm64)
# A failed build stops here: never wrap an older binary left in .build.
LOG="$(mktemp)"
if ! "${SWIFT[@]}" >"$LOG" 2>&1; then
    grep -vE '^\[ ?[0-9]+ ?/ ?[0-9]+ ?\]' "$LOG" >&2
    rm -f "$LOG"
    exit 1
fi
rm -f "$LOG"
BIN="$("${SWIFT[@]}" --show-bin-path)/SpeechToText"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RESOURCES"
cp "$BIN" "$APP/Contents/MacOS/SpeechToText"
# Every build carries VERSION; the window's footer reads it back.
sed "s/__VERSION__/$VERSION/g" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
cp -R "$ROOT/Resources/AppIcon.icns" "$ROOT/Resources/Fonts" "$ROOT/Resources/Icons" \
    "$ROOT/Resources/en.lproj" "$ROOT/Resources/pt-BR.lproj" "$RESOURCES/"

DEVELOPER_ID="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1 || true)"
SIGN="${DEVELOPER_ID:--}"
[ "$SIGN" = "-" ] && echo "warning: no Developer ID: signing ad hoc, macOS will ask for the permissions again" >&2
TIMESTAMP=(); if [ "$SIGN" != "-" ]; then TIMESTAMP=(--timestamp); fi
codesign --force --options runtime ${TIMESTAMP[@]+"${TIMESTAMP[@]}"} --identifier click.ciromaciel.speech-to-text \
    --entitlements "$ROOT/scripts/SpeechToText.entitlements" --sign "$SIGN" "$APP"
codesign --verify --deep --strict "$APP"
echo "signed with: $([ "$SIGN" = "-" ] && echo "ad hoc" || echo "$SIGN")"
echo "Speech to Text $VERSION → $APP"
