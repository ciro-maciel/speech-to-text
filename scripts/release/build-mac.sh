#!/usr/bin/env bash
#
# build-mac.sh — the official macOS build: signed with Developer ID, hardened runtime,
# notarized by Apple and stapled.
#
#   scripts/release/build-mac.sh <out-dir>
#
# Used by .github/workflows/release.yml, and the same on a Mac with the certificate:
#
#   1. scripts/whisper.sh builds the whisper.cpp sidecars and fetches the voice detector;
#   2. `tauri build` signs the app and both sidecars with the Developer ID identity and the
#      hardened runtime (entitlements.mac.plist), has Apple notarize the app and staples
#      the ticket to it, then packs the .dmg and, with an updater key, the signed update
#      archive the installed apps download;
#   3. the .dmg itself is signed, notarized and stapled, so a browser download opens with
#      no warning, even offline.
#
# Needs, in the environment:
#   APPLE_API_KEY, APPLE_API_ISSUER, APPLE_API_KEY_PATH   App Store Connect API key (.p8)
#   APPLE_SIGNING_IDENTITY       optional: found in the keychain when unset
#   TAURI_SIGNING_PRIVATE_KEY    optional: without it there is no update archive
#   TAURI_SIGNING_PRIVATE_KEY_PASSWORD
#
# Writes to <out-dir>:
#   Speech-to-Text-<version>-macos.dmg
#   Speech-to-Text-<version>-macos.app.tar.gz and .sig   (with the updater key)

set -euo pipefail

OUT="$1"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

fail() { echo "✗ $1" >&2; exit 1; }
for v in APPLE_API_KEY APPLE_API_ISSUER APPLE_API_KEY_PATH; do
    [ -n "${!v:-}" ] || fail "$v is not set"
done
[ -f "$APPLE_API_KEY_PATH" ] || fail "no API key at APPLE_API_KEY_PATH"

if [ -z "${APPLE_SIGNING_IDENTITY:-}" ]; then
    APPLE_SIGNING_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
    [ -n "$APPLE_SIGNING_IDENTITY" ] || fail "no Developer ID Application identity in the keychain"
fi
export APPLE_SIGNING_IDENTITY

VERSION="$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' package.json | head -1)"
NAME="Speech-to-Text"
BUNDLE="src-tauri/target/release/bundle"

bash scripts/whisper.sh
bun install --frozen-lockfile

UPDATER='{}'
[ -n "${TAURI_SIGNING_PRIVATE_KEY:-}" ] && UPDATER='{"bundle":{"createUpdaterArtifacts":true}}'
rm -rf "$BUNDLE/macos" "$BUNDLE/dmg"
bunx tauri build --bundles app,dmg --config "$UPDATER"

APP="$BUNDLE/macos/Speech to Text.app"
DMG_BUILT="$(ls "$BUNDLE"/dmg/*.dmg | head -1)"
[ -d "$APP" ] && [ -f "$DMG_BUILT" ] || fail "tauri build left no app or .dmg"

# The app: Developer ID, hardened runtime, sidecars included, ticket stapled.
# (Read into a variable first: grep -q stops reading early, and under pipefail the
# writer's SIGPIPE would count as a failure.)
codesign --verify --deep --strict "$APP" || fail "the app signature does not verify"
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
grep -q "Authority=Developer ID Application" <<<"$SIGNATURE" || fail "the app is not signed with Developer ID"
grep -q "flags=.*runtime" <<<"$SIGNATURE" || fail "the app has no hardened runtime"
for BIN in whisper-cli whisper-server; do
    grep -q "flags=.*runtime" <<<"$(codesign -dvv "$APP/Contents/MacOS/$BIN" 2>&1)" || fail "$BIN has no hardened runtime"
done
xcrun stapler validate "$APP" >/dev/null || fail "the app has no stapled ticket"

mkdir -p "$OUT"
DMG="$OUT/$NAME-$VERSION-macos.dmg"
cp "$DMG_BUILT" "$DMG"
codesign --force --timestamp --sign "$APPLE_SIGNING_IDENTITY" "$DMG"
NOTARY="$(mktemp)"
xcrun notarytool submit "$DMG" --key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY" --issuer "$APPLE_API_ISSUER" \
    --wait --timeout 30m | tee "$NOTARY"
grep -q "status: Accepted" "$NOTARY" || fail "Apple did not accept the .dmg"
rm -f "$NOTARY"
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG"

if [ -n "${TAURI_SIGNING_PRIVATE_KEY:-}" ]; then
    cp "$BUNDLE/macos/Speech to Text.app.tar.gz" "$OUT/$NAME-$VERSION-macos.app.tar.gz"
    cp "$BUNDLE/macos/Speech to Text.app.tar.gz.sig" "$OUT/$NAME-$VERSION-macos.app.tar.gz.sig"
fi

echo "✓ Speech to Text $VERSION → $OUT"
ls -1 "$OUT"
