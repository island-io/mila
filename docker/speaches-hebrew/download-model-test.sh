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

# 4. The model id must reach the download call -- a retry loop around the wrong
#    repo would still "pass" tests 1-3. It must arrive as a trailing ARGUMENT
#    and must not appear in the Python source at all; see test 6 for why.
stub="$(make_stub 0)"
PATH="$stub:$PATH" MODEL_DOWNLOAD_BACKOFF_SECONDS=0 sh "$SCRIPT" ivrit-ai/whisper-large-v3-turbo-ct2
recorded="$(cat "$stub/calls")"
case "$recorded" in
    *" ivrit-ai/whisper-large-v3-turbo-ct2")
        echo "  ok: model id is passed to python as a trailing argument" ;;
    *)
        echo "  FAIL: model id is not the final argument: $recorded" >&2
        failures=$((failures + 1)) ;;
esac
# The source half must be free of it -- otherwise it is being interpolated.
source_part="${recorded% ivrit-ai/whisper-large-v3-turbo-ct2}"
case "$source_part" in
    *ivrit-ai*)
        echo "  FAIL: model id is interpolated into the python source" >&2
        failures=$((failures + 1)) ;;
    *)
        echo "  ok: model id does not appear in the python source" ;;
esac

# 5. The exact invocation is pinned. A stub interpreter accepts ANY arguments,
#    so tests 1-4 pass just as happily against a call the real
#    `huggingface_hub` would reject -- which is precisely what happened when
#    this script briefly passed `max_retries=3`, a parameter the version in
#    the speaches base image does not have: every attempt raised TypeError and
#    the loop dutifully retried something that could never succeed. Nothing
#    here can check the real signature, so instead the call is frozen to the
#    one the image has always used. Changing it deliberately means changing
#    this string too -- and then verifying it against the actual library,
#    because this test cannot.
stub="$(make_stub 0)"
PATH="$stub:$PATH" MODEL_DOWNLOAD_BACKOFF_SECONDS=0 sh "$SCRIPT" some/model
expected="-c import sys; from huggingface_hub import snapshot_download; snapshot_download(repo_id=sys.argv[1]) some/model"
check "the download call is exactly the one the base image accepts" \
    "$expected" "$(cat "$stub/calls")"

# 6. MODEL_ID must reach Python as DATA, never as source. This one runs a real
#    interpreter against a stub `huggingface_hub` module, because a fake
#    `python` cannot show whether a payload would have executed. MODEL_ID is a
#    build arg, so interpolating it into `-c` source made it runnable Python.
real_dir="$(mktemp -d)"
cat > "$real_dir/huggingface_hub.py" <<'STUBMOD'
import os
def snapshot_download(repo_id, **kwargs):
    with open(os.environ["PROBE_REPO_ID"], "w") as fh:
        fh.write(repo_id)
STUBMOD
cat > "$real_dir/python" <<PYWRAP
#!/bin/sh
PYTHONPATH="$real_dir" exec python3 "\$@"
PYWRAP
chmod +x "$real_dir/python"

inject_marker="$real_dir/INJECTED"
repo_id_seen="$real_dir/repo_id"
payload="x'); __import__('os').system('touch $inject_marker'); ('"

PATH="$real_dir:$PATH" PROBE_REPO_ID="$repo_id_seen" MODEL_DOWNLOAD_BACKOFF_SECONDS=0 \
    sh "$SCRIPT" "$payload" >/dev/null 2>&1 || true

if [ -e "$inject_marker" ]; then
    echo "  FAIL: a crafted MODEL_ID executed code during the download" >&2
    failures=$((failures + 1))
else
    echo "  ok: a crafted MODEL_ID does not execute code"
fi
check "the crafted model id arrives verbatim as data" \
    "$payload" "$(cat "$repo_id_seen" 2>/dev/null)"

# 7. A missing model id is a usage error, not a silent five-attempt no-op.
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
