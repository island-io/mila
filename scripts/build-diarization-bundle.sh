#!/usr/bin/env bash
# build-diarization-bundle.sh
#
# Build a self-contained Python + pyannote.audio runtime tree that can be
# bundled into IslandWhisper.app/Contents/Resources/PythonRuntime/ for offline
# speaker diarization.
#
# Strategy:
#   1. Download python-build-standalone (PBS) "install_only" arm64 tarball
#      (cached by SHA-256 in build/python-bundle-cache/).
#   2. Extract -> patch _sysconfigdata so it has no absolute build-host path.
#   3. install_name_tool the embedded libpython to use @rpath.
#   4. Resolve the full transitive dep tree for pyannote.audio==3.3.2 in a
#      throwaway venv, drop torch/torchaudio/nvidia-* (those are downloaded by
#      the app at first launch), pip-freeze the rest -> frozen.txt.
#   5. pip install --target into python/site-packages using arm64 wheels for
#      macOS 11/12/14 (scipy has no macosx_11_0 wheel, hence multi-platform).
#   6. Strip __pycache__/, .dist-info/RECORD, and big test trees.
#   7. Ad-hoc codesign every .so / .dylib inside-out (deepest first).
#   8. Emit MANIFEST.txt with package versions, PBS release id, total bytes.
#
# Caching / distribution:
#   This script is meant to be invoked by `make bundle-diarization` (developer
#   workstation and CI). The output tree is ~150 MB uncompressed and is NOT
#   meant to be committed to git -- distribute it as a GitHub release asset
#   (or equivalent), pulled down at build time when needed. See `.gitignore`.
#
# Idempotency:
#   Re-running with the same inputs reproduces an equivalent tree. The PBS
#   tarball is cached by SHA-256; pip downloads use the standard pip cache.
#   Re-runs delete and recreate $OUTPUT_DIR so partial states never linger.
#
# Usage:
#   scripts/build-diarization-bundle.sh [--output-dir <path>] [--keep-tmp]
#
# Exits non-zero on any failure.

set -euo pipefail

# ---- Configuration ---------------------------------------------------------
PBS_RELEASE="20260510"
PYTHON_VERSION="3.11.15"
PBS_FILENAME="cpython-${PYTHON_VERSION}+${PBS_RELEASE}-aarch64-apple-darwin-install_only.tar.gz"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_RELEASE}/${PBS_FILENAME}"
PBS_SHA256="03bcedae9b19a48888d7dc8ba064f73f6efaaf2b13f6a8e1a1bcc062df13e855"

PYANNOTE_VERSION="3.3.2"
TORCH_VERSION="2.2.2"           # pinned; downloaded at runtime by the app
TORCHAUDIO_VERSION="2.2.2"      # pinned; downloaded at runtime by the app

# pip --platform tags; pip accepts multiple, scipy needs 12.0+ for arm64.
PIP_PLATFORMS=(macosx_11_0_arm64 macosx_12_0_arm64 macosx_14_0_arm64)
PIP_PYTHON_VERSION="3.11"
PIP_IMPLEMENTATION="cp"

# ---- Paths -----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_OUTPUT_DIR="$REPO_ROOT/IslandWhisper/Resources/PythonRuntime"
CACHE_DIR="$REPO_ROOT/build/python-bundle-cache"

OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"
KEEP_TMP=0

# ---- Arg parsing -----------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --keep-tmp)
            KEEP_TMP=1
            shift
            ;;
        -h|--help)
            sed -n '1,40p' "$0"
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

# Normalize OUTPUT_DIR to absolute
if [[ "$OUTPUT_DIR" != /* ]]; then
    OUTPUT_DIR="$REPO_ROOT/$OUTPUT_DIR"
fi

log() { printf '[bundle] %s\n' "$*" >&2; }
die() { printf '[bundle] FATAL: %s\n' "$*" >&2; exit 1; }

# ---- Preflight -------------------------------------------------------------
[[ "$(uname -s)" == "Darwin" ]] || die "must run on macOS (got $(uname -s))"
[[ "$(uname -m)" == "arm64"  ]] || die "must run on Apple Silicon arm64 (got $(uname -m))"
command -v curl              >/dev/null || die "curl not found"
command -v shasum            >/dev/null || die "shasum not found"
command -v tar               >/dev/null || die "tar not found"
command -v codesign          >/dev/null || die "codesign not found"
command -v install_name_tool >/dev/null || die "install_name_tool not found"
command -v /usr/bin/python3  >/dev/null || die "/usr/bin/python3 not found"

mkdir -p "$CACHE_DIR"

TMPDIR_ROOT="$(mktemp -d -t islandwhisper-bundle-XXXXXX)"
cleanup() {
    if [[ "$KEEP_TMP" -eq 0 ]]; then
        rm -rf "$TMPDIR_ROOT"
    else
        log "keeping tmp dir: $TMPDIR_ROOT"
    fi
}
trap cleanup EXIT

# ---- Step 1: download + verify PBS tarball ---------------------------------
TARBALL="$CACHE_DIR/$PBS_FILENAME"
download_pbs() {
    if [[ -f "$TARBALL" ]]; then
        local got
        got="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
        if [[ "$got" == "$PBS_SHA256" ]]; then
            log "cached PBS tarball OK (sha256 $PBS_SHA256)"
            return 0
        else
            log "cached PBS tarball checksum mismatch ($got != $PBS_SHA256); re-downloading"
            rm -f "$TARBALL"
        fi
    fi
    log "downloading $PBS_URL"
    curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$TARBALL.part" "$PBS_URL" >&2
    mv "$TARBALL.part" "$TARBALL"
    local got
    got="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
    [[ "$got" == "$PBS_SHA256" ]] || die "PBS sha256 mismatch (got $got, want $PBS_SHA256)"
    log "downloaded PBS tarball, sha256 verified"
}
download_pbs

# ---- Step 2: extract PBS into a clean output tree --------------------------
STAGING_DIR="$TMPDIR_ROOT/staging"
mkdir -p "$STAGING_DIR"
log "extracting PBS tarball"
tar -xzf "$TARBALL" -C "$STAGING_DIR"
# PBS extracts as "python/" directly. Verify.
[[ -x "$STAGING_DIR/python/bin/python3.11" ]] || die "python3.11 not found after extraction"

PY="$STAGING_DIR/python/bin/python3.11"
"$PY" --version >&2

# Sanity: arm64 binary
if ! file "$PY" | grep -q arm64; then
    die "expected arm64 binary at $PY"
fi

# ---- Step 3: patch _sysconfigdata to remove absolute build-host path -------
SYSCONFIG_DIR="$STAGING_DIR/python/lib/python3.11"
SYSCONFIG_FILE="$(ls "$SYSCONFIG_DIR"/_sysconfigdata__darwin_darwin.py 2>/dev/null || true)"
if [[ -n "$SYSCONFIG_FILE" && -f "$SYSCONFIG_FILE" ]]; then
    log "patching _sysconfigdata: stripping absolute build-host paths"
    # Strip leading paths that point at /install/ build host. We replace any
    # absolute path that contains "/install/" with the literal token
    # "@PYTHON_PREFIX@" so that downstream tools don't see the build host.
    /usr/bin/python3 - "$SYSCONFIG_FILE" <<'PYEOF'
import sys, re, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()
# Replace common PBS build paths.
patched = re.sub(r'/install/(\S+?)(?=["\'])', r'@PYTHON_PREFIX@/\1', src)
patched = re.sub(r"'/install'", "'@PYTHON_PREFIX@'", patched)
if patched == src:
    print("[bundle] _sysconfigdata: no changes (already clean?)", file=sys.stderr)
else:
    p.write_text(patched)
    print("[bundle] _sysconfigdata: patched", file=sys.stderr)
PYEOF
else
    log "WARN: _sysconfigdata__darwin_darwin.py not found under $SYSCONFIG_DIR; skipping patch"
fi

# Remove the cached pyc (it embeds the unpatched paths). Python regenerates it
# on first import.
find "$SYSCONFIG_DIR/__pycache__" -name '_sysconfigdata__darwin_darwin*' -delete 2>/dev/null || true

# ---- Step 4: install_name_tool libpython to @rpath -------------------------
LIBPY="$STAGING_DIR/python/lib/libpython3.11.dylib"
if [[ -f "$LIBPY" ]]; then
    current_id="$(otool -D "$LIBPY" | tail -1 || true)"
    log "libpython current id: $current_id"
    install_name_tool -id "@rpath/libpython3.11.dylib" "$LIBPY"
    log "libpython new id: $(otool -D "$LIBPY" | tail -1)"
else
    log "WARN: $LIBPY not present (static build?); skipping install_name_tool"
fi

# Upgrade pip + tooling so resolver/dist support is current.
log "upgrading pip + wheel inside bundle"
"$PY" -m pip install --upgrade --quiet pip wheel setuptools

# ---- Step 5: resolve full dep set in a throwaway venv ----------------------
RESOLVER_VENV="$TMPDIR_ROOT/resolver-venv"
log "creating throwaway resolver venv at $RESOLVER_VENV"
"$PY" -m venv "$RESOLVER_VENV"
RPY="$RESOLVER_VENV/bin/python"
"$RPY" -m pip install --upgrade --quiet pip wheel setuptools

# Constraints: keep huggingface_hub <1.0 (per project rule); avoid torch/torchaudio.
CONSTRAINTS_FILE="$TMPDIR_ROOT/constraints.txt"
cat >"$CONSTRAINTS_FILE" <<EOF
# Project-imposed constraints
huggingface_hub<1.0
# pyannote.audio 3.3.2 requires torch>=2.0; we pin to match runtime download.
torch==${TORCH_VERSION}
torchaudio==${TORCHAUDIO_VERSION}
EOF

log "resolving deps for pyannote.audio==${PYANNOTE_VERSION} (this can take 3-6 min)..."
# We install pyannote.audio fully so we capture the closure, then we'll filter
# torch/torchaudio/nvidia-* out at install time. We don't actually need torch
# wheels installed in the resolver venv -- but pip's resolver needs to see
# torch's METADATA to make it happy. Using --no-deps would skip resolution
# entirely, defeating the point.
#
# Quiet but show stderr-level progress so the user knows we're alive.
"$RPY" -m pip install \
    --quiet \
    --no-warn-script-location \
    --progress-bar off \
    -c "$CONSTRAINTS_FILE" \
    "pyannote.audio==${PYANNOTE_VERSION}" 1>&2

log "freezing resolved environment"
FROZEN_RAW="$TMPDIR_ROOT/frozen-raw.txt"
FROZEN_FILE="$TMPDIR_ROOT/frozen.txt"
"$RPY" -m pip freeze --exclude-editable >"$FROZEN_RAW"

# Filter out torch, torchaudio, nvidia-*; also strip pip/setuptools/wheel
# (those come from the venv itself, not from pyannote).
/usr/bin/python3 - "$FROZEN_RAW" "$FROZEN_FILE" <<'PYEOF'
import sys, re, pathlib
src = pathlib.Path(sys.argv[1]).read_text().splitlines()
# DROP only the packages we install at runtime (torch+torchaudio) plus
# inert metadata packages. The previous "torch-" catch-all was too greedy:
# it matched torch-audiomentations and torch-pitch-shift, which pyannote.
# audio's __init__ imports unconditionally. Build a bundle without them
# and `from pyannote.audio import Pipeline` ModuleNotFoundErrors at run
# time. Be explicit about what's stripped.
DROP_EXACT = {
    "torch", "torchaudio",   # pinned + downloaded at runtime by DiarizationBootstrap
    "triton",                # CUDA-only; not used on macOS
    "pip", "wheel", "setuptools",
}
DROP_PREFIXES = (
    "nvidia-",               # CUDA wheels (linux/win only anyway)
)
# Also drop anything named "torch" exactly (some pip versions emit base form)
out = []
for line in src:
    s = line.strip()
    if not s or s.startswith("#"):
        continue
    low = s.lower()
    # pip freeze emits "name==version"; check the name portion specifically
    # so we don't accidentally drop sibling packages like torch-audiomentations.
    name = re.split(r"[=<>!~ ]", low, 1)[0]
    if name in DROP_EXACT:
        continue
    if any(low.startswith(p) for p in DROP_PREFIXES):
        continue
    out.append(s)
pathlib.Path(sys.argv[2]).write_text("\n".join(out) + "\n")
print(f"[bundle] frozen.txt: {len(out)} packages (filtered from {len(src)})", file=sys.stderr)
PYEOF

log "frozen package list:"
sed 's/^/[bundle]   /' "$FROZEN_FILE" >&2

# ---- Step 6: install into target site-packages -----------------------------
SITE_PACKAGES="$STAGING_DIR/python/site-packages"
mkdir -p "$SITE_PACKAGES"

# Build platform args array.
PLATFORM_ARGS=()
for p in "${PIP_PLATFORMS[@]}"; do
    PLATFORM_ARGS+=(--platform "$p")
done

log "installing ${PYANNOTE_VERSION} stack into site-packages (this can take 3-6 min)..."
# --no-deps because we have the full resolved set in frozen.txt.
# --only-binary=:all: bans compilation of C-extension sdists (we don't want
# to ship .so files compiled against the build-host SDK).
# --no-binary=<pkgs> overrides per-package to allow pure-Python sdists
# (antlr4-python3-runtime, julius -- both ship sdist-only but are pure-py).
# Multiple --platform tags because scipy has only macosx_12_0_arm64+ wheels.
# No --abi flag: we want abi3 wheels (e.g. hf-xet ships cp37-abi3) to match.
PURE_PY_SDIST_OVERRIDE="antlr4-python3-runtime,julius"
"$PY" -m pip install \
    --no-warn-script-location \
    --progress-bar off \
    --target "$SITE_PACKAGES" \
    --no-deps \
    --only-binary=:all: \
    --no-binary="$PURE_PY_SDIST_OVERRIDE" \
    --python-version "$PIP_PYTHON_VERSION" \
    --implementation "$PIP_IMPLEMENTATION" \
    "${PLATFORM_ARGS[@]}" \
    -r "$FROZEN_FILE" 1>&2

# Sanity: pyannote/audio must be present.
[[ -d "$SITE_PACKAGES/pyannote/audio" ]] || die "pyannote/audio not present in site-packages after install"

# ---- Step 7: strip caches, test dirs, RECORD files -------------------------
log "stripping __pycache__/ trees and RECORD files"
find "$STAGING_DIR/python" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
find "$SITE_PACKAGES" -type f -path '*.dist-info/RECORD' -delete 2>/dev/null || true

# Trim large test directories across the scientific stack. These pull in
# ~20-40 MB of fixtures and example data without affecting runtime behavior.
#
# IMPORTANT: only strip `tests/` (plural). `numpy.testing` is a PUBLIC module
# (used by scipy/sklearn at import time), and so is `sklearn.utils._testing`,
# so we must NOT delete `testing/` directories. The `test/` (singular) form
# is used by a few packages (sympy) -- safe.
for pkg in numpy scipy pandas sklearn sympy networkx speechbrain \
           torch_audiomentations torchmetrics lightning pytorch_lightning \
           pyannote pyannote_core pyannote_database pyannote_pipeline \
           hyperpyyaml; do
    pkgdir="$SITE_PACKAGES/$pkg"
    if [[ -d "$pkgdir" ]]; then
        find "$pkgdir" -type d -name 'tests' \
            -prune -exec rm -rf {} + 2>/dev/null || true
    fi
done

# Strip any leftover __pycache__ inside site-packages (pip writes them on
# install).
find "$SITE_PACKAGES" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true

# Strip .pyi stubs in pure-data packages (pandas/sympy ship many; they're
# only useful to type checkers). Skip numpy/scipy as they're occasionally
# inspected at runtime by tooling.
for pkg in pandas sympy; do
    pkgdir="$SITE_PACKAGES/$pkg"
    [[ -d "$pkgdir" ]] && find "$pkgdir" -name '*.pyi' -delete 2>/dev/null || true
done

# Drop GUI / dev-only stdlib subpackages and their dylibs. Diarization is a
# pure-headless ML pipeline; tkinter/IDLE/ensurepip can never be reached.
# Saves ~10-12 MB.
log "trimming GUI/dev stdlib (tkinter, IDLE, ensurepip, lib2to3, tcl/tk)"
PY_STDLIB="$STAGING_DIR/python/lib/python3.11"
rm -rf "$PY_STDLIB/tkinter" \
       "$PY_STDLIB/idlelib" \
       "$PY_STDLIB/ensurepip" \
       "$PY_STDLIB/lib2to3" \
       "$PY_STDLIB/turtledemo" \
       "$PY_STDLIB/turtle.py" \
       "$STAGING_DIR/python/lib/tcl9.0" \
       "$STAGING_DIR/python/lib/tcl9" \
       "$STAGING_DIR/python/lib/tk9.0" \
       "$STAGING_DIR/python/lib/itcl4.3.5" \
       "$STAGING_DIR/python/lib/thread3.0.4" \
       "$STAGING_DIR/python/lib/libtcl9.0.dylib" \
       "$STAGING_DIR/python/lib/libtcl9tk9.0.dylib" \
       "$STAGING_DIR/python/lib/pkgconfig" 2>/dev/null || true
# Drop lib-dynload entries for stdlib modules we never need (Tk + DBM).
for so in "$PY_STDLIB"/lib-dynload/_tkinter*.so \
          "$PY_STDLIB"/lib-dynload/_dbm*.so \
          "$PY_STDLIB"/lib-dynload/_gdbm*.so; do
    [[ -f "$so" ]] && rm -f "$so"
done

# Re-strip __pycache__/ after our deletions (a few pyc files may be left over)
find "$STAGING_DIR/python" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true

# ---- Step 8: ad-hoc codesign every .so / .dylib (inside-out) ---------------
#
# Note: we deliberately do NOT pass `-o runtime` (hardened runtime). Hardened
# runtime defaults to enabling Library Validation, which under an ad-hoc
# signature (`-s -`) means the loading process and every loaded dylib must
# share a Team ID. Ad-hoc signatures have no Team ID, so two ad-hoc-signed
# binaries trying to interop are rejected with "different Team IDs".
#
# An ad-hoc internal build is not gatekeeper-bound anyway -- we just need
# valid signatures so macOS lets the binaries run on quarantine-free disks.
# Hardened runtime can be re-enabled later when the app moves to a real
# Developer ID signing identity (replace `-` with the identity and re-add
# `-o runtime` here).
log "collecting binaries to sign"
SIGN_LIST_FILE="$TMPDIR_ROOT/sign-list.txt"
# Build a depth-sorted list (deepest-first) using awk for the depth count.
# This is independent of any xargs argv limits.
/usr/bin/find "$STAGING_DIR/python" \
    \( -name '*.so' -o -name '*.dylib' \) -type f \
    | awk -F/ '{print NF"\t"$0}' \
    | sort -rn \
    | cut -f2- > "$SIGN_LIST_FILE"
# Append libpython and the python3.11 binary (sign them after their dependents).
[[ -f "$LIBPY" ]] && echo "$LIBPY" >> "$SIGN_LIST_FILE"
[[ -f "$PY"    ]] && echo "$PY"    >> "$SIGN_LIST_FILE"
SIGN_TOTAL="$(wc -l <"$SIGN_LIST_FILE" | tr -d ' ')"
log "ad-hoc signing $SIGN_TOTAL binaries (deepest first)"
SIGN_COUNT=0
SIGN_FAILED=0
SIGN_FAILED_LIST="$TMPDIR_ROOT/sign-failed.txt"
: > "$SIGN_FAILED_LIST"
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if codesign -f -s - --timestamp=none "$f" >/dev/null 2>&1; then
        SIGN_COUNT=$((SIGN_COUNT + 1))
    else
        SIGN_FAILED=$((SIGN_FAILED + 1))
        echo "$f" >> "$SIGN_FAILED_LIST"
    fi
done < "$SIGN_LIST_FILE"
if [[ "$SIGN_FAILED" -gt 0 ]]; then
    log "FAILED to sign $SIGN_FAILED binaries:"
    sed 's/^/[bundle]   /' "$SIGN_FAILED_LIST" >&2
    die "codesign failures (see above)"
fi
log "signed $SIGN_COUNT binaries"

# ---- Step 9: smoke test ----------------------------------------------------
log "smoke-testing bundled interpreter + pyannote.audio metadata"
# We don't import pyannote.audio fully -- it requires torch which is installed
# at runtime by the app, not at build time. We just confirm the dist-info is
# present and the interpreter can load native extensions.
set +e
"$PY" -c "
import sys
sys.path.insert(0, '$SITE_PACKAGES')
print('python:', sys.version.split()[0])
# numpy is a native extension -- this is the smoke test for codesign integrity.
import numpy
print('numpy version:', numpy.__version__)
import scipy
print('scipy version:', scipy.__version__)
# Read pyannote.audio version from dist-info (avoids importing torch).
from importlib.metadata import version
print('pyannote.audio version:', version('pyannote.audio'))
print('huggingface_hub version:', version('huggingface_hub'))
# Pure-python pyannote pieces:
import pyannote.core
print('pyannote.core OK')
" >&2
SMOKE_RC=$?
set -e
if [[ "$SMOKE_RC" -ne 0 ]]; then
    log "WARN: smoke test exited with $SMOKE_RC (continuing; investigate before shipping)"
fi

# ---- Step 10: MANIFEST.txt -------------------------------------------------
log "writing MANIFEST.txt"
# Use du -k (kilobytes, 1024) summed and converted to bytes -- robust on
# trees with many files (avoids argv limits in stat/xargs).
TOTAL_BYTES="$(/usr/bin/du -k -s "$STAGING_DIR/python" | awk '{print $1 * 1024}')"
{
    echo "IslandWhisper PythonRuntime bundle"
    echo "Generated: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    echo "Build host arch: $(uname -m)"
    echo "Build host macOS: $(sw_vers -productVersion 2>/dev/null || echo unknown)"
    echo ""
    echo "python-build-standalone release: ${PBS_RELEASE}"
    echo "Python version: ${PYTHON_VERSION}"
    echo "PBS tarball: ${PBS_FILENAME}"
    echo "PBS sha256: ${PBS_SHA256}"
    echo ""
    echo "pyannote.audio target version: ${PYANNOTE_VERSION}"
    echo "torch/torchaudio (downloaded at runtime by app): ${TORCH_VERSION}/${TORCHAUDIO_VERSION}"
    echo ""
    echo "Installed packages (from pip freeze):"
    sed 's/^/  /' "$FROZEN_FILE"
    echo ""
    echo "Total uncompressed bytes: ${TOTAL_BYTES}"
    echo "Total uncompressed (human): $(/usr/bin/du -sh "$STAGING_DIR/python" | awk '{print $1}')"
    echo ""
    echo "Signed binaries: ${SIGN_COUNT}"
} > "$STAGING_DIR/python/MANIFEST.txt"

# ---- Step 11: publish to OUTPUT_DIR ----------------------------------------
log "publishing to $OUTPUT_DIR"
mkdir -p "$(dirname "$OUTPUT_DIR")"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
# Move the python/ tree into OUTPUT_DIR/python/
mv "$STAGING_DIR/python" "$OUTPUT_DIR/python"

# ---- Done -----------------------------------------------------------------
FINAL_SIZE="$(/usr/bin/du -sh "$OUTPUT_DIR" | awk '{print $1}')"
log "DONE"
log "  output: $OUTPUT_DIR"
log "  size:   $FINAL_SIZE"
log "  python: $OUTPUT_DIR/python/bin/python3.11"
log "  manifest: $OUTPUT_DIR/python/MANIFEST.txt"
