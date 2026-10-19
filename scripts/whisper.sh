#!/usr/bin/env bash
#
# whisper.sh — prepares what the app bundles from whisper.cpp, once per checkout:
#
#   - whisper-cli and whisper-server, built from source at WHISPER_VERSION and copied to
#     src-tauri/ with the target triple in the name (Tauri's sidecar convention);
#   - the Silero voice detector (ggml-silero-v6.2.0.bin, 865 KB) in src-tauri/resources,
#     downloaded from ggml-org on Hugging Face and checked against its SHA-256.
#
#   bash scripts/whisper.sh          (or: bun run whisper)
#
# Static and self-contained: no OpenMP and no shared libraries, so a fresh Mac runs it;
# Metal stays on, embedded in the binary. The build is kept in .whisper/<version>, so a
# second run only copies. Needs git, cmake and the Xcode Command Line Tools.
#
# The speech models themselves (tiny, base, small...) are not here: the app downloads the
# one you pick, from ggerganov/whisper.cpp on Hugging Face, into
# ~/Library/Application Support/speech-to-text/models.

set -euo pipefail

WHISPER_VERSION="${WHISPER_VERSION:-v1.8.4}"
VAD_FILE="ggml-silero-v6.2.0.bin"
VAD_URL="https://huggingface.co/ggml-org/whisper-vad/resolve/main/$VAD_FILE"
VAD_SHA256="2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/.whisper/$WHISPER_VERSION"
TRIPLE="$(rustc -vV | sed -n 's|host: ||p')"
[ -n "$TRIPLE" ] || { echo "rustc not found: install Rust from https://rustup.rs" >&2; exit 1; }

if [ ! -x "$CACHE/whisper-server" ]; then
    SRC="$(mktemp -d)"
    trap 'rm -rf "$SRC"' EXIT
    echo "Building whisper.cpp ${WHISPER_VERSION}…"
    git clone -q --depth 1 --branch "$WHISPER_VERSION" https://github.com/ggml-org/whisper.cpp.git "$SRC"
    cmake -S "$SRC" -B "$SRC/build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DGGML_NATIVE=OFF \
        -DGGML_OPENMP=OFF \
        -DWHISPER_BUILD_TESTS=OFF \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 >/dev/null
    cmake --build "$SRC/build" --config Release -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)" \
        --target whisper-cli whisper-server >/dev/null
    mkdir -p "$CACHE"
    cp "$SRC/build/bin/whisper-cli" "$SRC/build/bin/whisper-server" "$CACHE/"
fi

for BIN in whisper-cli whisper-server; do
    cp "$CACHE/$BIN" "$ROOT/src-tauri/$BIN-$TRIPLE"
    chmod +x "$ROOT/src-tauri/$BIN-$TRIPLE"
done
echo "whisper.cpp $WHISPER_VERSION → src-tauri/whisper-{cli,server}-$TRIPLE"

VAD="$ROOT/src-tauri/resources/$VAD_FILE"
if [ ! -f "$VAD" ] || [ "$(shasum -a 256 "$VAD" | cut -d' ' -f1)" != "$VAD_SHA256" ]; then
    mkdir -p "$(dirname "$VAD")"
    curl -fsSL -o "$VAD.part" "$VAD_URL"
    [ "$(shasum -a 256 "$VAD.part" | cut -d' ' -f1)" = "$VAD_SHA256" ] ||
        { rm -f "$VAD.part"; echo "$VAD_FILE does not match its SHA-256" >&2; exit 1; }
    mv "$VAD.part" "$VAD"
fi
echo "voice detector → src-tauri/resources/$VAD_FILE"
