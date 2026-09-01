#!/bin/sh
# Fetch the whisper model into the image's HuggingFace cache, retrying a
# handful of times before giving up.
#
# WHY THIS ISN'T JUST `RUN python -c "snapshot_download(...)"` (issue #240)
# -----------------------------------------------------------------------
# That is what it used to be, and on 2026-09-01 it took `main` red:
#
#   huggingface_hub.errors.LocalEntryNotFoundError: An error happened while
#   trying to locate the file on the Hub and we cannot find the requested
#   files in the local cache.
#
# It failed 23 seconds in, inside `_raise_on_head_call_error` — the HEAD
# request to huggingface.co simply did not land. A re-run of the identical
# commit passed. One unlucky moment against an external service failed a
# 10-minute build and produced a red `main` that looked like somebody's
# change had broken something.
#
# Retrying is cheap here because `snapshot_download` is resumable: it writes
# into the HF cache and picks up where it left off, so a retry after a
# partial transfer does not re-fetch the ~1.6 GB from the start.
#
# The download call itself is left EXACTLY as it was. An earlier revision of
# this script also passed `max_retries=3`, on the theory that the per-file
# HTTP layer should retry too; the `huggingface_hub` pinned in the speaches
# base image has no such parameter, so every attempt died instantly with
# `TypeError: snapshot_download() got an unexpected keyword argument
# 'max_retries'` and the loop faithfully retried a call that could never
# work. The retry is the only thing this script adds — the invocation is the
# one the image has always used, and download-model-test.sh pins it, because
# nothing here can verify the real library's signature.
#
# Usage: download-model.sh <hf-model-id>
set -eu

MODEL_ID="${1:?usage: download-model.sh <hf-model-id>}"

# Overridable so the retry logic can be exercised without a real download —
# see download-model-test.sh, which puts a stub `python` on PATH and sets the
# backoff to 0. Defaults are what the image build actually uses.
ATTEMPTS="${MODEL_DOWNLOAD_ATTEMPTS:-5}"
BACKOFF_BASE="${MODEL_DOWNLOAD_BACKOFF_SECONDS:-10}"

attempt=1
while :; do
    # `if` suppresses errexit for the condition, so a failure lands below
    # rather than aborting the script.
    if python -c "from huggingface_hub import snapshot_download; snapshot_download(repo_id='${MODEL_ID}')"; then
        exit 0
    fi
    if [ "$attempt" -ge "$ATTEMPTS" ]; then
        echo "download-model: giving up on ${MODEL_ID} after ${attempt} attempt(s)" >&2
        exit 1
    fi
    delay=$((attempt * BACKOFF_BASE))
    echo "download-model: attempt ${attempt}/${ATTEMPTS} failed for ${MODEL_ID}; retrying in ${delay}s" >&2
    sleep "$delay"
    attempt=$((attempt + 1))
done
