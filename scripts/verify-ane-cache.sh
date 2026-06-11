#!/usr/bin/env bash
# Verify that UPGRADING Mila (rebuild + re-sign + reinstall) does NOT trigger
# a CoreML / Neural-Engine cold recompile of the whisper encoder.
#
# Why this exists
# ---------------
# whisper.cpp loads a sibling `<model>-encoder.mlmodelc` and CoreML compiles
# it for the ANE on first use (~2 min for large-v3 on a cold cache). That
# compiled artifact is cached by macOS keyed on the MODEL (content + device),
# NOT on the app's code signature, and the model files live OUTSIDE the app
# bundle (~/Library/Application Support/Mila/Models). So re-signing /
# upgrading the app should reuse the cache and NOT recompile.
#
# This script proves that property — and guards against regressions (e.g. if
# someone later bundles the models inside the .app, an upgrade WOULD change
# their path and invalidate the cache, which this test would catch).
#
# How it works
# ------------
#   1. WARM:    launch the installed app, let `prewarm` load + ANE-compile the
#               model once (populating the cache), then quit.
#   2. UPGRADE: re-install via install-debug.sh (re-signs the bundle → new
#               cdhash → a genuine "new version" from the OS's point of view).
#   3. TEST:    launch again and watch WhisperEngine's logs. PASS iff the model
#               loads WITHOUT a "CoreML cold compile detected" line and under
#               the latency threshold.
#
# This is a LOCAL / self-hosted test: it needs a real Neural Engine, the model
# installed, and a GUI session. It is NOT runnable on GitHub-hosted CI
# (VM runners have no ANE and no installed model). Run it on a dev Mac or a
# self-hosted ANE-equipped runner.
#
# Usage:  ./scripts/verify-ane-cache.sh
# Exit:   0 = no recompile on upgrade (PASS); 1 = recompile detected / error.

set -euo pipefail

APP="/Applications/Mila.app"
SUBSYS="io.island.mila.TranscriptionCore"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Warm/test load must finish under this. A warm load is a few seconds; a cold
# ANE compile is ~100s+, so a generous ceiling cleanly separates the two.
MAX_WARM_LOAD_SECONDS="${MAX_WARM_LOAD_SECONDS:-25}"
# How long to wait for prewarm's load to log a result before giving up.
LAUNCH_LOG_TIMEOUT="${LAUNCH_LOG_TIMEOUT:-240}"
# Always use the absolute path: a `log` shell function/alias in the user's
# profile shadows /usr/bin/log and breaks the predicate parsing.
LOG_BIN="/usr/bin/log"

if [[ ! -d "$APP" ]]; then
  echo "FAIL: $APP not installed — run \`make build && ./scripts/install-debug.sh\` first" >&2
  exit 1
fi

quit_mila() {
  osascript -e 'tell application "Mila" to quit' >/dev/null 2>&1 || true
  sleep 1
  pkill -TERM -f "Mila.app/Contents/MacOS/Mila" >/dev/null 2>&1 || true
  sleep 1
}

# Launch Mila, stream WhisperEngine logs to $1, and block until we see a
# "Loaded … elapsed=…s" line (prewarm finished) or LAUNCH_LOG_TIMEOUT elapses.
# Echoes the captured elapsed seconds on stdout.
launch_and_capture() {
  local logfile="$1"
  : > "$logfile"
  "$LOG_BIN" stream --predicate "subsystem == \"$SUBSYS\"" --info --debug --style compact \
    > "$logfile" 2>/dev/null &
  local stream_pid=$!
  # Give the stream a beat to attach before the app starts logging.
  sleep 1
  open -a "$APP"

  local waited=0
  while (( waited < LAUNCH_LOG_TIMEOUT )); do
    if grep -q "Loaded .* elapsed=" "$logfile"; then break; fi
    sleep 2; waited=$((waited + 2))
  done
  kill "$stream_pid" >/dev/null 2>&1 || true
}

echo "==> WARM phase: priming the ANE cache (first launch may compile; that's expected)"
quit_mila
WARM_LOG="$(mktemp -t mila-ane-warm)"
launch_and_capture "$WARM_LOG"
if ! grep -q "Loaded .* elapsed=" "$WARM_LOG"; then
  echo "FAIL: warm launch never logged a model load within ${LAUNCH_LOG_TIMEOUT}s." >&2
  echo "      (Is a model installed for the current recording language?)" >&2
  echo "      --- captured TranscriptionCore log ---" >&2
  cat "$WARM_LOG" >&2
  exit 1
fi
echo "    warm load: $(grep -o 'Loaded .* elapsed=[0-9.]*s' "$WARM_LOG" | tail -1)"

echo "==> UPGRADE phase: reinstalling (re-sign → new cdhash, simulating a version bump)"
quit_mila
"$ROOT/scripts/install-debug.sh" >/dev/null

echo "==> TEST phase: launching the 'upgraded' build and watching for a recompile"
TEST_LOG="$(mktemp -t mila-ane-test)"
launch_and_capture "$TEST_LOG"
quit_mila

if ! grep -q "Loaded .* elapsed=" "$TEST_LOG"; then
  echo "FAIL: post-upgrade launch never logged a model load within ${LAUNCH_LOG_TIMEOUT}s." >&2
  cat "$TEST_LOG" >&2
  exit 1
fi

LOADED_LINE="$(grep -o 'Loaded .* elapsed=[0-9.]*s' "$TEST_LOG" | tail -1)"
ELAPSED="$(printf '%s' "$LOADED_LINE" | grep -oE 'elapsed=[0-9.]+' | cut -d= -f2)"
echo "    post-upgrade load: $LOADED_LINE"

# Primary signal: the engine flags its own cold compiles.
if grep -q "CoreML cold compile detected" "$TEST_LOG"; then
  echo "FAIL: the upgrade triggered a CoreML/ANE COLD RECOMPILE." >&2
  echo "      The compiled-encoder cache was not reused across the reinstall." >&2
  grep "CoreML cold compile detected" "$TEST_LOG" >&2
  exit 1
fi

# Secondary signal: latency. A warm reuse is seconds; a recompile is ~100s+.
if awk "BEGIN{exit !($ELAPSED > $MAX_WARM_LOAD_SECONDS)}"; then
  echo "FAIL: post-upgrade model load took ${ELAPSED}s (> ${MAX_WARM_LOAD_SECONDS}s)." >&2
  echo "      That latency means the ANE encoder was recompiled, not reused." >&2
  exit 1
fi

echo "PASS: upgrade reused the compiled ANE encoder (no recompile; load ${ELAPSED}s)."
