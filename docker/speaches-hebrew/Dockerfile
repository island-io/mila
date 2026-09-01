# Speaches (faster-whisper / CTranslate2) serving a Hebrew whisper model,
# OpenAI-compatible at /v1/audio/transcriptions on port 8000.
#
# WHY THIS IMAGE EXISTS
# ---------------------
# Mila's remote-transcription backend (`RemoteWhisperEngine`) speaks the OpenAI
# `/v1/audio/transcriptions` protocol. Its E2E test normally runs against the
# stdlib echo mock (scripts/mock-openai-transcription-server.py), which proves
# the request *contract* but never actually transcribes. This image stands up a
# REAL self-hosted server with a REAL Hebrew model so the Hebrew E2E can prove
# Mila gets correct Hebrew text back over HTTP — the production "speaches serving
# an ivrit.ai model" path the app's own docs describe
# (Mila/Models/RemoteTranscriptionSettings.swift).
#
# It's also a standalone deliverable: `docker run -p 8000:8000 <image>` gives you
# a local Hebrew transcription endpoint for manual testing.
#
# MODEL
# -----
# ivrit-ai/whisper-large-v3-turbo-ct2 — Apache-2.0 (redistributable), CTranslate2
# format, model.bin ~1.62 GB. Baked into the image's HuggingFace hub cache at
# build time so the container is fully self-contained and needs no network at
# run time (important for hermetic CI). Override with --build-arg MODEL_ID=... .

# BASE IMAGE — pinned to a digest, refreshed by dependabot (issue #243)
# ----------------------------------------------------------------------
# We inherit this image's ENTIRE Python environment: huggingface_hub,
# faster-whisper, ctranslate2, the lot. It used to be `latest-cpu`, so that
# environment could change between two builds of an unchanged Dockerfile —
# and did: #242 called `snapshot_download(max_retries=3)`, a parameter that
# does not exist in the huggingface_hub this image ships, and the build broke
# for reasons nothing in this repo could explain. With a pin, the contract is
# knowable: as of this digest the base is speaches 0.8.3 (upstream commit
# c78b77d), whose uv.lock — installed with `uv sync --frozen` — gives
# huggingface_hub 0.33.4, faster-whisper 1.1.1, ctranslate2 4.5.0.
#
# WHY tag AND digest, not one or the other
#   - The digest is the pin. A tag, semver or not, is mutable at the
#     registry's discretion; upstream re-points `latest-cpu` on every release.
#     `sha256:21e3df…` is the only form that cannot move under us.
#   - The tag is not decoration. Docker resolves by digest and ignores it, but
#     dependabot keys its version search on the tag, and only a tag with a
#     comparable version can move: `latest-cpu` has none, so dependabot could
#     never bump it. `0.8.3-cpu` parses as version 0.8.3 + suffix `-cpu`, and
#     dependabot only compares tags with a matching suffix — so it will offer
#     `0.9.0-cpu` and never a `-cuda` or `-rc` tag. It also tells a human
#     reading the diff what they are actually on.
#
# WHY NOT `ARG SPEACHES_TAG` + `FROM …:${SPEACHES_TAG}` (what this replaced)
#   Dependabot's Dockerfile parser does not resolve ARGs. Its FROM regex wants
#   a literal tag (`[\w][\w.-]{0,127}`), `${SPEACHES_TAG}` cannot match it, and
#   a FROM line with neither tag nor digest is skipped outright. The `docker`
#   entry in .github/dependabot.yml has existed since #95 and has never opened
#   a PR — it had nothing to parse. Keep this line literal or it goes inert
#   again, silently.
#
# REFRESH PATH (a pin that freezes security updates is its own hazard)
#   1. Dependabot, weekly, with the 7-day cooldown in .github/dependabot.yml:
#      new upstream release -> a `docker:` PR bumping tag + digest together.
#      A same-tag digest refresh (upstream re-pushing patched bytes under
#      `0.8.3-cpu`) is also something dependabot can propose, but whether it
#      does is governed by a server-side dependabot experiment we cannot
#      observe from here — do not rely on it as the only path.
#   2. Manual: `Build Speaches Hebrew Image` has a `workflow_dispatch` for
#      exactly this, and any bump lands as a reviewable PR that rebuilds the
#      image and runs the Hebrew E2E against it.
FROM ghcr.io/speaches-ai/speaches:0.8.3-cpu@sha256:21e3df06d842fb7802ab470dd77c25f0e8c0d22950e8d8c6ae886e851af53ef8

# Declared after FROM so it's visible in this build stage — an ARG before FROM
# only reaches the FROM line itself.
ARG MODEL_ID=ivrit-ai/whisper-large-v3-turbo-ct2

LABEL org.opencontainers.image.source="https://github.com/island-io/mila"
LABEL org.opencontainers.image.description="Speaches serving the Apache-2.0 ivrit.ai Hebrew whisper model (CT2), OpenAI-compatible on :8000. Used by Mila's Hebrew remote-transcription E2E."
LABEL org.opencontainers.image.licenses="MIT AND Apache-2.0"
LABEL io.island.mila.model="${MODEL_ID}"

# Bake the model weights into the image's HF cache. The base image runs as the
# non-root `ubuntu` user with HOME=/home/ubuntu and pre-creates
# ~/.cache/huggingface/hub, so the download lands exactly where faster-whisper
# looks for it at run time — no network needed once the image is built.
ENV HF_HUB_DISABLE_TELEMETRY=1
# Retried rather than one-shot: a single unlucky HEAD call to huggingface.co
# used to fail the whole 10-minute build (issue #240). The loop lives in a
# script instead of inline here so its behaviour can actually be tested —
# see download-model-test.sh, which stubs the interpreter and asserts that a
# transient failure recovers while a permanent one still fails, bounded.
#
# The script is left in the image rather than removed: it is under 2 KB, and
# the base image runs as non-root `ubuntu`, which cannot delete a root-owned
# file from sticky /tmp.
COPY download-model.sh /tmp/download-model.sh
RUN sh /tmp/download-model.sh "${MODEL_ID}"

# Server config (speaches reads these env vars; see src/speaches/config.py).
#   - PRELOAD_MODELS: a JSON list. Load the model into memory at startup so the
#     very first transcription request doesn't pay the load cost (CI health-gates
#     on it). DERIVED from MODEL_ID (expanded at build time) so a custom
#     `--build-arg MODEL_ID=...` build preloads the model it actually baked into
#     the HF cache above — never a stale hard-coded repo.
#   - WHISPER__INFERENCE_DEVICE/COMPUTE_TYPE: CPU int8 — the GitHub runner has no
#     GPU, and int8 keeps the turbo model's latency tolerable.
#   - ENABLE_UI=false: no gradio UI; this is an API-only server.
#   - ALLOW_ORIGINS: the E2E client reaches it through a tunnel hostname.
#
# NOTE on the JSON-list vars (PRELOAD_MODELS, ALLOW_ORIGINS): speaches parses
# these with pydantic-settings as JSON, so the value must be a valid JSON list —
# `["*"]`, with the inner double-quotes intact. Docker's `ENV KEY=value` parser
# STRIPS surrounding double-quotes, so a bare `ALLOW_ORIGINS=["*"]` reaches the
# app as `[*]`, which pydantic rejects (`Input should be a valid list`) and the
# container crashes on boot. Escape the inner quotes (`\"`) so the env value is
# literally `["*"]`.
ENV PRELOAD_MODELS=["\"${MODEL_ID}\""] \
    WHISPER__INFERENCE_DEVICE=cpu \
    WHISPER__COMPUTE_TYPE=int8 \
    ENABLE_UI=false \
    ALLOW_ORIGINS=["\"*\""] \
    UVICORN_HOST=0.0.0.0 \
    UVICORN_PORT=8000

EXPOSE 8000

# Healthcheck so `docker run --health-*` / compose can gate on readiness. The
# base image installs curl. /health returns 200 once the app is up; we give it a
# long start period because PRELOAD_MODELS warms the ~1.6 GB model first.
HEALTHCHECK --interval=10s --timeout=5s --start-period=180s --retries=12 \
    CMD curl --fail http://localhost:8000/health || exit 1

# Inherit the base image's entrypoint/CMD (uvicorn serving the speaches app).
