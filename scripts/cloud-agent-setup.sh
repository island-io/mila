#!/usr/bin/env bash
# Idempotent Cloud Agent (Linux) setup for the cross-platform surface of Mila.
#
# The Mila app itself is macOS-only (Xcode / SwiftUI) and cannot be built on
# Linux. What IS cross-platform — and what a Cloud Agent can build, test, and
# run end to end here — is:
#
#   * Packages/MilaKit           — the zero-dependency MCP/store package
#   * Packages/TranscriptionCore — WhisperEngine (whisper.cpp bindings), WAVReader,
#                                  WER calculator, VAD, and the whisper-e2e CLI
#
# TranscriptionCore links against whisper.cpp, which on Linux is provided as a
# system library (see Packages/TranscriptionCore/Sources/CWhisper/module.modulemap),
# so this script builds the whisper.cpp submodule into shared libraries and
# installs them where the Swift toolchain's linker finds them by default.
#
# This runs as the environment `install` step. It is safe to run repeatedly:
# every stage checks for existing state and skips work that is already done, so
# on a prebuilt snapshot it is a fast no-op, while on a bare Ubuntu image it
# bootstraps everything from scratch.
set -euo pipefail

SWIFT_VERSION="6.1.2"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WHISPER_DIR="$REPO_ROOT/Packages/TranscriptionCore/vendor/whisper.cpp"
WHISPER_MARKER="/usr/local/lib/.mila-whisper-sha"
MODEL_DIR="$HOME/.cache/whisper-models"

cd "$REPO_ROOT"

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

log() { printf '\n==> %s\n' "$1"; }

ensure_system_deps() {
  # Build toolchain + Swift runtime dependencies. Guarded so a snapshot that
  # already has them skips apt entirely.
  if command -v cmake >/dev/null 2>&1 && command -v g++ >/dev/null 2>&1 \
     && command -v git >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
     && dpkg -s libncurses-dev >/dev/null 2>&1; then
    log "System build dependencies already present; skipping apt"
    return
  fi
  log "Installing system build + Swift runtime dependencies"
  $SUDO apt-get update -qq
  $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    build-essential g++ cmake git curl ca-certificates pkg-config unzip \
    binutils libc6-dev libcurl4-openssl-dev libedit2 libncurses-dev \
    libpython3-dev libsqlite3-0 libxml2-dev libz3-dev tzdata zlib1g-dev \
    libgcc-13-dev libstdc++-13-dev
}

ensure_swift() {
  if command -v swift >/dev/null 2>&1; then
    log "Swift already installed: $(swift --version 2>/dev/null | head -1)"
    return
  fi
  log "Installing Swift $SWIFT_VERSION toolchain"
  local url tarball
  # Official swift.org build for Ubuntu 24.04 (x86_64).
  url="https://download.swift.org/swift-${SWIFT_VERSION}-release/ubuntu2404/swift-${SWIFT_VERSION}-RELEASE/swift-${SWIFT_VERSION}-RELEASE-ubuntu24.04.tar.gz"
  tarball="$(mktemp /tmp/swift-XXXXXX.tar.gz)"
  curl -fL --retry 4 --retry-delay 4 -o "$tarball" "$url"
  $SUDO mkdir -p /opt/swift
  $SUDO tar xzf "$tarball" -C /opt/swift --strip-components=1
  rm -f "$tarball"
  # Put the toolchain on the default PATH for every shell. Each symlink resolves
  # its sibling tools via its real location under /opt/swift.
  for b in /opt/swift/usr/bin/*; do
    $SUDO ln -sf "$b" "/usr/local/bin/$(basename "$b")"
  done
  swift --version | head -1
}

build_whisper() {
  log "Initializing whisper.cpp submodule"
  git submodule update --init --recursive

  local sha
  sha="$(git -C "$WHISPER_DIR" rev-parse HEAD)"

  if [ -f /usr/local/lib/libwhisper.so ] && [ -f "$WHISPER_MARKER" ] \
     && [ "$(cat "$WHISPER_MARKER")" = "$sha" ]; then
    log "whisper.cpp libraries already built for $sha; skipping"
    return
  fi

  log "Building whisper.cpp shared libraries ($sha)"
  # Use gcc/g++: the toolchain image's default clang c++ driver cannot locate
  # libstdc++ for linking the C++ sources.
  cmake -S "$WHISPER_DIR" -B "$WHISPER_DIR/build-linux" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DGGML_NATIVE=OFF \
    -DCMAKE_C_COMPILER=gcc \
    -DCMAKE_CXX_COMPILER=g++
  cmake --build "$WHISPER_DIR/build-linux" -j"$(nproc)"
  $SUDO cmake --install "$WHISPER_DIR/build-linux" --prefix /usr/local

  # Expose the dev symlinks on the default linker search path so `swift build`
  # resolves -lwhisper / -lggml* without needing LIBRARY_PATH.
  for lib in libwhisper.so libggml.so libggml-base.so libggml-cpu.so; do
    $SUDO ln -sf "/usr/local/lib/$lib" "/usr/lib/x86_64-linux-gnu/$lib"
  done
  $SUDO ldconfig
  echo "$sha" | $SUDO tee "$WHISPER_MARKER" >/dev/null
}

build_packages() {
  log "Building Swift packages (MilaKit, TranscriptionCore)"
  ( cd "$REPO_ROOT/Packages/MilaKit" && swift build )
  ( cd "$REPO_ROOT/Packages/TranscriptionCore" && swift build )
}

fetch_e2e_model() {
  local model="$MODEL_DIR/ggml-tiny.bin"
  if [ -f "$model" ]; then
    log "whisper tiny model already present; skipping download"
    return
  fi
  log "Downloading ggml-tiny.bin for the whisper-e2e transcription check"
  mkdir -p "$MODEL_DIR"
  curl -fL --retry 4 --retry-delay 4 -o "$model" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin"
}

ensure_system_deps
ensure_swift
build_whisper
build_packages
fetch_e2e_model

log "Cloud Agent setup complete"
