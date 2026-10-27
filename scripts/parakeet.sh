#!/usr/bin/env bash
#
# parakeet.sh — builds the parakeet-server sidecar (parakeet/, Swift + FluidAudio) and copies
# it to src-tauri/ with the target triple in the name (Tauri's sidecar convention).
#
#   bash scripts/parakeet.sh          (or: bun run parakeet)
#
# Apple Silicon only, macOS 14 or later at run time. The SwiftPM build is kept in .parakeet/,
# so a second run only relinks. Needs the Xcode Command Line Tools (Swift 5.10 or later).
#
# The model itself is not here: the app downloads it from FluidInference on Hugging Face,
# through this same binary (--download), into
# ~/Library/Application Support/speech-to-text/models/parakeet-ultra.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TRIPLE="$(rustc -vV | sed -n 's|host: ||p')"
[ -n "$TRIPLE" ] || { echo "rustc not found: install Rust from https://rustup.rs" >&2; exit 1; }

echo "Building parakeet-server…"
SWIFT=(swift build --package-path "$ROOT/parakeet" --scratch-path "$ROOT/.parakeet" -c release --arch arm64)
"${SWIFT[@]}" --product parakeet-server 2>&1 | grep -vE '^\[ ?[0-9]+ ?/ ?[0-9]+ ?\]' || true
BIN="$("${SWIFT[@]}" --show-bin-path)/parakeet-server"
[ -x "$BIN" ] || { echo "parakeet-server did not build" >&2; exit 1; }

cp "$BIN" "$ROOT/src-tauri/parakeet-server-$TRIPLE"
chmod +x "$ROOT/src-tauri/parakeet-server-$TRIPLE"
echo "parakeet-server → src-tauri/parakeet-server-$TRIPLE"
