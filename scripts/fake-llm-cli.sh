#!/bin/sh
# Mock stand-in for the `claude` / `cursor-agent` CLI, used by Mila's
# end-to-end tests so CI exercises the LLM seam with NO API key, no network,
# and no real model. Mila invokes it exactly like the real CLI — a one-shot
# `-p <prompt>` print that streams an answer to stdout and exits.
#
# Behaviour:
#   * If MILA_FAKE_LLM_LOG is set, append this invocation (the full argv,
#     NUL-separated, terminated by an ASCII record separator) so a test can
#     assert the app issued the right call.
#   * Print a deterministic reply to stdout (override with MILA_FAKE_LLM_REPLY)
#     and exit 0.
#
# The authoritative call-shape assertion lives in the unit suite
# (RecordingSummarizerTests.test_summarize_invokes_cli_with_transcript_in_one_shot_prompt);
# this stub lets the macOS UI e2e drive the same seam without a key.
set -eu

if [ -n "${MILA_FAKE_LLM_LOG:-}" ]; then
  { printf '%s\0' "$@"; printf '\036'; } >> "$MILA_FAKE_LLM_LOG"
fi

printf '%s' "${MILA_FAKE_LLM_REPLY:-Quarterly Planning Sync}"
