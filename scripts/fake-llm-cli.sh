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
#   * Mila drives this CLI from TWO prompts with DIFFERENT expected reply
#     shapes, so the stub branches on the prompt it was handed (the full
#     prompt is passed in argv):
#       - The LIVE AI tick prompt (LiveAISession) demands a single-line JSON
#         envelope `{"summary": "...", "items": [...]}`. Returning plain
#         text there leaves `aiSession.summary` empty and the
#         `liveAI.summary` element never renders — which is exactly what
#         the AudioLoopbackUITests assert on. Detected by the literal
#         `"summary"`/`"items"` JSON-object instruction the live prompt
#         carries.
#       - The post-recording SUMMARY prompt (RecordingSummarizer) wants a
#         plain-text title/summary. That's the default reply.
#   * Override either branch's payload with MILA_FAKE_LLM_REPLY (plain) /
#     MILA_FAKE_LLM_REPLY_JSON (envelope) if a test needs specific content.
#
# The authoritative call-shape assertion lives in the unit suite
# (RecordingSummarizerTests.test_summarize_invokes_cli_with_transcript_in_one_shot_prompt);
# this stub lets the macOS UI e2e drive the same seam without a key.
set -eu

# Capture the full argv as a single string so we can sniff which prompt
# Mila handed us (the prompt is one of the arguments — e.g. `-p <prompt>`).
ARGS="$*"

if [ -n "${MILA_FAKE_LLM_LOG:-}" ]; then
  { printf '%s\0' "$@"; printf '\036'; } >> "$MILA_FAKE_LLM_LOG"
fi

# Default live-AI envelope. Built in a plain variable (NOT inline in a
# `${VAR:-default}` expansion) because an unescaped `}` inside the default
# value would prematurely terminate the parameter expansion and corrupt the
# JSON — exactly the kind of silent breakage this stub exists to avoid.
DEFAULT_JSON='{"summary": "Team reviewed the roadmap: auth rewrite, search index migration, and billing dashboard.", "items": [{"id": "auth-rewrite", "text": "Finish the auth rewrite before end of quarter", "speaker": null, "timestamp_seconds": 0, "source": "inferred"}]}'

# The live-AI tick prompt asks for a JSON object with "summary" and "items".
# Match on that instruction so we only emit the envelope for the live path.
case "$ARGS" in
  *'"summary"'*'"items"'*)
    printf '%s' "${MILA_FAKE_LLM_REPLY_JSON:-$DEFAULT_JSON}"
    ;;
  *)
    printf '%s' "${MILA_FAKE_LLM_REPLY:-Quarterly Planning Sync}"
    ;;
esac
