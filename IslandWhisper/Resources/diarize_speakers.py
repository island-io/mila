#!/usr/bin/env python3
"""Speaker diarization helper for IslandWhisper.

Takes a 16kHz mono WAV path as argv[1], runs pyannote speaker-diarization-3.1,
and prints a JSON array of {start, end, speaker} turns to stdout.

Requires: pip install pyannote.audio torch
HF_TOKEN env var must be set with a token that has accepted the model terms at
https://hf.co/pyannote/speaker-diarization-3.1
"""
import json
import os
import sys

# pyannote.audio 3.x uses torch.load without weights_only=False,
# which breaks on PyTorch >= 2.6 where the default flipped to True.
import torch
_orig_torch_load = torch.load
def _patched_torch_load(*args, **kwargs):
    kwargs["weights_only"] = False
    return _orig_torch_load(*args, **kwargs)
torch.load = _patched_torch_load


def main():
    if len(sys.argv) < 2:
        print("usage: diarize_speakers.py <wav_path>", file=sys.stderr)
        sys.exit(1)

    wav_path = sys.argv[1]
    hf_token = os.environ.get("HF_TOKEN", "")
    if not hf_token:
        print("HF_TOKEN not set", file=sys.stderr)
        sys.exit(1)

    from pyannote.audio import Pipeline

    pipeline = Pipeline.from_pretrained(
        "pyannote/speaker-diarization-3.1"
    )
    if torch.backends.mps.is_available():
        pipeline.to(torch.device("mps"))

    diar = pipeline(wav_path)
    annotation = getattr(diar, "speaker_diarization", diar)

    turns = []
    for turn, _, speaker in annotation.itertracks(yield_label=True):
        turns.append({
            "start": round(turn.start, 3),
            "end": round(turn.end, 3),
            "speaker": speaker,
        })

    json.dump(turns, sys.stdout)


if __name__ == "__main__":
    main()
