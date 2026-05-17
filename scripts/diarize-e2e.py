#!/usr/bin/env python3
"""End-to-end smoke test for the bundled speaker diarization pipeline.

Mirrors the Python script that ships inside `SpeakerDiarizer.swift`'s
`diarize()` — same monkey-patches for speechbrain / torch.load — but runs
standalone so CI can verify the pipeline works without launching the app.

Usage:
    diarize-e2e.py <models-dir> <wav-path> [--min-turns N]

`models-dir` must point at the bundled `DiarizationModels/` directory
(containing `config.yaml` plus the segmentation-3.0 and
pyannote-wespeaker-voxceleb-resnet34-LM subdirs).

Exits 0 iff the pipeline instantiates AND processes the WAV AND emits at
least `--min-turns` turns. Anything else exits non-zero with a message.
"""

import argparse
import json
import os
import sys
import tempfile
import types


def _apply_patches():
    """The pyannote.audio + speechbrain + torch combo refuses to import
    cleanly on PyTorch >= 2.6 + recent speechbrain releases without two
    monkey-patches. The Swift SpeakerDiarizer applies the same pair —
    keep them in sync if you bump either dep."""
    try:
        import speechbrain.utils.importutils as _sbiu
        _orig_ensure = _sbiu.LazyModule.ensure_module

        def _safe_ensure(self, *a, **kw):
            try:
                return _orig_ensure(self, *a, **kw)
            except ImportError:
                self.lazy_module = types.ModuleType(self.target)
                return self.lazy_module

        _sbiu.LazyModule.ensure_module = _safe_ensure
    except Exception:
        pass

    import torch
    _orig_torch_load = torch.load

    def _patched_torch_load(*args, **kwargs):
        kwargs["weights_only"] = False
        return _orig_torch_load(*args, **kwargs)

    torch.load = _patched_torch_load


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("models_dir")
    parser.add_argument("wav_path")
    parser.add_argument("--min-turns", type=int, default=1,
                        help="Fail if fewer than this many turns are detected")
    args = parser.parse_args()

    if not os.path.isdir(args.models_dir):
        sys.exit(f"models dir not found: {args.models_dir}")
    if not os.path.isfile(args.wav_path):
        sys.exit(f"wav not found: {args.wav_path}")

    _apply_patches()

    import torch
    from pyannote.audio import Pipeline

    config_path = os.path.join(args.models_dir, "config.yaml")
    with open(config_path) as f:
        config_text = f.read().replace("__MODELS_DIR__", args.models_dir)

    tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False)
    tmp.write(config_text)
    tmp.close()

    try:
        pipeline = Pipeline.from_pretrained(tmp.name)
        if torch.backends.mps.is_available():
            pipeline.to(torch.device("mps"))
            print("device: mps", file=sys.stderr)
        else:
            print("device: cpu", file=sys.stderr)

        diar = pipeline(args.wav_path)
        annotation = getattr(diar, "speaker_diarization", diar)

        turns = []
        for turn, _, speaker in annotation.itertracks(yield_label=True):
            turns.append({
                "start": round(turn.start, 3),
                "end": round(turn.end, 3),
                "speaker": speaker,
            })
    finally:
        os.unlink(tmp.name)

    speakers = sorted({t["speaker"] for t in turns})
    summary = {
        "ok": len(turns) >= args.min_turns,
        "turns": len(turns),
        "speakers": speakers,
    }
    json.dump(summary, sys.stdout, indent=2)
    sys.stdout.write("\n")

    if not summary["ok"]:
        sys.exit(f"expected >= {args.min_turns} turns, got {len(turns)}")


if __name__ == "__main__":
    main()
