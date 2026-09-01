#!/bin/sh
# Tests for download-model.sh's retry loop (issue #240).
#
# The point of the retry is that a transient failure does not fail the build,
# and that a permanent one still does — neither of which the image build can
# demonstrate, because a real run either works or costs 10 minutes and 1.6 GB
# to fail. So the download itself is stubbed: a fake `python` earlier on PATH
# counts its invocations and fails on cue. Nothing in download-model.sh knows
# it is being tested; the stub replaces the interpreter, not a seam in the
# script.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/download-model.sh"
failures=0

# Build a throwaway PATH whose `python` fails its first $1 invocations and
# succeeds afterwards ($1 of -1 means "always fail"), recording every call.
make_stub() {
    fail_times="$1"
    stub_dir="$(mktemp -d)"
    : > "$stub_dir/calls"
    cat > "$stub_dir/python" <<STUB
#!/bin/sh
echo "\$@" >> "$stub_dir/calls"
n=\$(wc -l < "$stub_dir/calls" | tr -d ' ')
if [ "$fail_times" -lt 0 ] || [ "\$n" -le "$fail_times" ]; then exit 1; fi
exit 0
STUB
    chmod +x "$stub_dir/python"
    echo "$stub_dir"
}

calls_made() { wc -l < "$1/calls" | tr -d ' '; }

check() {
    label="$1"; expected="$2"; actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ok: $label"
    else
        echo "  FAIL: $label — expected '$expected', got '$actual'" >&2
        failures=$((failures + 1))
    fi
}

echo "download-model.sh retry tests"

# 1. The happy path must not retry, and must not sleep.
stub="$(make_stub 0)"
PATH="$stub:$PATH" MODEL_DOWNLOAD_BACKOFF_SECONDS=0 sh "$SCRIPT" some/model
check "succeeds first time -> exit 0" 0 $?
check "succeeds first time -> exactly 1 attempt" 1 "$(calls_made "$stub")"

# 2. The bug this fixes: a transient failure must NOT fail the build.
stub="$(make_stub 2)"
PATH="$stub:$PATH" MODEL_DOWNLOAD_BACKOFF_SECONDS=0 sh "$SCRIPT" some/model
check "two transient failures -> exit 0" 0 $?
check "two transient failures -> 3 attempts" 3 "$(calls_made "$stub")"

# 3. A permanent failure must still fail, and must be bounded. If this ever
#    passes, the retry has turned a broken build into a silently green one.
stub="$(make_stub -1)"
set +e
PATH="$stub:$PATH" MODEL_DOWNLOAD_ATTEMPTS=4 MODEL_DOWNLOAD_BACKOFF_SECONDS=0 sh "$SCRIPT" some/model 2>/dev/null
rc=$?
set -e
check "permanent failure -> non-zero exit" 1 "$rc"
check "permanent failure -> bounded at MODEL_DOWNLOAD_ATTEMPTS" 4 "$(calls_made "$stub")"

# 4. The model id must reach the download call — a retry loop around the wrong
#    repo would still "pass" tests 1-3.
stub="$(make_stub 0)"
PATH="$stub:$PATH" MODEL_DOWNLOAD_BACKOFF_SECONDS=0 sh "$SCRIPT" ivrit-ai/whisper-large-v3-turbo-ct2
if grep -q "repo_id='ivrit-ai/whisper-large-v3-turbo-ct2'" "$stub/calls"; then
    echo "  ok: model id is passed through to snapshot_download"
else
    echo "  FAIL: model id missing from the python invocation" >&2
    failures=$((failures + 1))
fi

# 5. A missing model id is a usage error, not a silent five-attempt no-op.
set +e
sh "$SCRIPT" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
    echo "  ok: missing model id exits non-zero"
else
    echo "  FAIL: missing model id should not succeed" >&2
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all checks passed"
