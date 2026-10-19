#!/usr/bin/env bash
#
# smoke-test.sh — proves an INSTALLED Speech to Text works on this OS.
#
#   scripts/smoke-test.sh <app-executable> <sidecar-dir> <model.bin> <speech.wav>
#
# Runs on macOS, Linux and Windows (Git Bash) against the packaged app, not
# the dev build, in three steps:
#
#   1. whisper-cli, as shipped, transcribes <speech.wav>.
#   2. whisper-server, as shipped, answers /inference with the same text.
#   3. The app itself starts with <model.bin> in its models folder and logs
#      "[whisper-server] preloaded" — its own sidecar found, the model and the
#      voice detector loaded, the tray and windows up — and keeps running.
#
# The speech is whisper.cpp's samples/jfk.wav: the check looks for "ask not
# what your country", which every model size gets right.
#
# On Linux it needs a display: run it under `xvfb-run -a`.

set -euo pipefail

APP="$1"
SIDECARS="$2"
MODEL="$3"
WAV="$4"
EXPECT="ask not what your country"
BOOT_TIMEOUT="${SMOKE_BOOT_TIMEOUT:-120}"

case "$(uname -s)" in
    Darwin) OS=mac; EXE="" ;;
    Linux) OS=linux; EXE="" ;;
    MINGW* | MSYS* | CYGWIN*) OS=windows; EXE=".exe" ;;
    *) echo "unknown OS $(uname -s)"; exit 1 ;;
esac

WORK="$(mktemp -d)"
cleanup() {
    [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true
    [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null || true
    if [ "$OS" = windows ]; then
        taskkill //F //IM "$(basename "$APP")" >/dev/null 2>&1 || true
        taskkill //F //IM "whisper-server.exe" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

pass() { printf '  ✓ %s\n' "$1"; }
fail() { printf '  ✗ %s\n' "$1"; exit 1; }
has_speech() { tr '[:upper:]' '[:lower:]' <"$1" | tr -d ',.' | grep -q "$EXPECT"; }

echo "Smoke test — $OS"
echo "  app:      $APP"
echo "  sidecars: $SIDECARS"

# ---- 1. whisper-cli ----------------------------------------------------------
"$SIDECARS/whisper-cli$EXE" -m "$MODEL" -f "$WAV" -l en -nt -np >"$WORK/cli.txt" 2>"$WORK/cli.err" ||
    { cat "$WORK/cli.err"; fail "whisper-cli exited with an error"; }
has_speech "$WORK/cli.txt" || { cat "$WORK/cli.txt"; fail "whisper-cli did not transcribe the sample"; }
pass "whisper-cli transcribed: $(tr -s ' \n' ' ' <"$WORK/cli.txt" | cut -c1-70)…"

# ---- 2. whisper-server ---------------------------------------------------------
PORT=18765
"$SIDECARS/whisper-server$EXE" -m "$MODEL" --host 127.0.0.1 --port "$PORT" >"$WORK/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 60); do
    curl -sf "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break
    kill -0 "$SERVER_PID" 2>/dev/null || { cat "$WORK/server.log"; fail "whisper-server died on start"; }
    sleep 1
done
curl -sf "http://127.0.0.1:$PORT/inference" -F "file=@$WAV" -F language=en -F response_format=json >"$WORK/server.json" ||
    { cat "$WORK/server.log"; fail "whisper-server did not answer /inference"; }
has_speech "$WORK/server.json" || { cat "$WORK/server.json"; fail "whisper-server did not transcribe the sample"; }
pass "whisper-server answered /inference"
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

# ---- 3. the app ---------------------------------------------------------------
# Same places the app uses: dirs::data_dir()/speech-to-text/models for the
# model (config.rs), the Tauri log dir for its log (tauri-plugin-log).
#
# On macOS and Linux the app runs with a throwaway HOME, so a run on a
# developer's machine never touches their models, settings or logs. Windows
# reads those folders from the system, not the environment; there the test
# runs on a disposable CI machine.
ID="click.ciromaciel.speech-to-text"
case "$OS" in
    mac)
        APP_HOME="$WORK/home"
        DATA="$APP_HOME/Library/Application Support"
        LOGS="$APP_HOME/Library/Logs/$ID"
        ;;
    linux)
        APP_HOME="$WORK/home"
        DATA="$APP_HOME/.local/share"
        LOGS="$DATA/$ID/logs"
        ;;
    windows)
        APP_HOME="$HOME"
        DATA="$(cygpath -u "$APPDATA")"
        LOGS="$(cygpath -u "$LOCALAPPDATA")/$ID/logs"
        rm -rf "$LOGS"
        ;;
esac
mkdir -p "$DATA/speech-to-text/models"
cp "$MODEL" "$DATA/speech-to-text/models/ggml-tiny.bin"

HOME="$APP_HOME" XDG_DATA_HOME= XDG_CONFIG_HOME= "$APP" >"$WORK/app.out" 2>&1 &
APP_PID=$!

booted=""
for _ in $(seq 1 "$BOOT_TIMEOUT"); do
    if cat "$WORK/app.out" "$LOGS"/*.log 2>/dev/null | grep -q "\[whisper-server\] preloaded"; then
        booted=1
        break
    fi
    if cat "$WORK/app.out" "$LOGS"/*.log 2>/dev/null | grep -q "\[whisper-server\] preload failed"; then
        break
    fi
    kill -0 "$APP_PID" 2>/dev/null || break
    sleep 1
done

if [ -z "$booted" ]; then
    echo "---- app output ----"
    cat "$WORK/app.out" 2>/dev/null || true
    echo "---- app log ----"
    cat "$LOGS"/*.log 2>/dev/null || true
    if ! kill -0 "$APP_PID" 2>/dev/null && [ ! -s "$WORK/app.out" ]; then
        # tauri-plugin-single-instance: a second copy hands over to the one
        # already open (a socket in /tmp, whatever HOME is) and exits silently.
        fail "the app exited at once — is another Speech to Text open? Quit it and run again"
    fi
    fail "the app did not load the model within ${BOOT_TIMEOUT}s"
fi
pass "the app started and loaded the model: $(cat "$WORK/app.out" "$LOGS"/*.log 2>/dev/null | grep -o 'preloaded .* in [0-9]*ms' | head -1 | sed 's|.*/||')"

sleep 5
kill -0 "$APP_PID" 2>/dev/null || { cat "$WORK/app.out"; fail "the app exited after starting"; }
pass "the app is still running 5 s later"

echo "Smoke test passed — $OS"
