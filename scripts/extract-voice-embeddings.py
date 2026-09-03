#!/usr/bin/env python3
"""Turn labelled audio into a cached embedding corpus for the seed-anchor
sweep (island-io/mila#206).

The sweep replays Mila's real speaker-matching code (`seedPool` / `assign`)
over cached embeddings, once per configuration. Only this step needs pyannote,
a GPU, or minutes of your life: run it once, and the 40-cell grid then takes
milliseconds and is reproducible on any machine.

    extract-voice-embeddings.py <models-dir> <manifest.json> --out corpus.json

`models-dir` is the bundled `DiarizationModels/` directory (the same one
`diarize-e2e.py` takes): `config.yaml` plus the segmentation-3.0 and
pyannote-wespeaker-voxceleb-resnet34-LM subdirectories. In an installed app
that is
`/Applications/Mila.app/Contents/Resources/DiarizationModels`.

The manifest names the audio and its ground truth:

    {
      "enrolments": [
        {"speaker": "alice", "wav": "alice-enrol.wav", "rttm": "alice-enrol.rttm"}
      ],
      "recordings": [
        {"id": "standup-01", "setup": "headset-office",
         "wav": "standup-01.wav", "rttm": "standup-01.rttm"}
      ]
    }

Enrolment recordings build the stored profiles and **must be held out** — an
enrolment file that also appears under `recordings` leaks the answer into the
profile and every anchor weight scores implausibly well. The script refuses
that.

Audio must be 16 kHz mono WAV, which is what Mila records. Convert with:

    ffmpeg -i in.m4a -ar 16000 -ac 1 out.wav

RTTM is the standard diarization ground-truth format, one line per turn:

    SPEAKER <file> 1 <start> <duration> <NA> <NA> <speaker> <NA> <NA>

See `docs/seed-anchor-sweep.md` for the whole procedure, and
`MilaTests/SeedAnchorSweepHarness.swift` for the corpus schema this writes.

NOTE: this script has never been run — nobody has the audio yet. It is
modelled line by line on the embedding path that ships in
`LiveSpeakerDiarizer.daemonScript` (same patches, same
`pipeline._embedding` call, same tensor shape). Expect to debug it the first
time; the sweep it feeds is exercised by CI on synthetic embeddings.
"""

import argparse
import json
import os
import sys
import tempfile
import types


def _apply_patches():
    """Same two monkey-patches the app applies. See
    `.claude/rules/python-subprocess.md` — keep them in sync with
    `SpeakerDiarizer.swift` and `LiveSpeakerDiarizer.swift` if either
    dependency is bumped."""
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


def read_rttm(path):
    """[(start, duration, speaker)] sorted by start."""
    turns = []
    with open(path) as f:
        for line_number, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith(";;"):
                continue
            fields = line.split()
            if len(fields) < 8 or fields[0].upper() != "SPEAKER":
                continue
            try:
                start, duration = float(fields[3]), float(fields[4])
            except ValueError:
                sys.exit(f"{path}:{line_number}: unparseable start/duration")
            turns.append((start, duration, fields[7]))
    if not turns:
        sys.exit(f"{path}: no SPEAKER lines")
    turns.sort(key=lambda t: (t[0], t[1], t[2]))
    return turns


def load_wav(path):
    import soundfile as sf
    samples, sample_rate = sf.read(path, dtype="float32")
    if samples.ndim > 1:
        samples = samples.mean(axis=1)
    if sample_rate != 16000:
        sys.exit(
            f"{path}: sample rate {sample_rate}, expected 16000. "
            f"Convert with:  ffmpeg -i {path} -ar 16000 -ac 1 out.wav"
        )
    return samples, sample_rate


def embed_turns(embedder, samples, sample_rate, turns, min_duration, label):
    """One embedding per turn long enough to be worth embedding."""
    import numpy as np
    import torch

    out, skipped = [], 0
    for start, duration, speaker in turns:
        if duration < min_duration:
            skipped += 1
            continue
        first = int(round(start * sample_rate))
        last = int(round((start + duration) * sample_rate))
        clip = samples[max(0, first):min(len(samples), last)]
        if len(clip) < int(min_duration * sample_rate):
            skipped += 1
            continue
        # Shape (batch, channels, samples) — pyannote 3.x's
        # `pipeline._embedding` is a PretrainedSpeakerEmbedding and takes the
        # tensor directly, NOT the {"waveform":…, "sample_rate":…} dict that
        # `Inference` takes. Passing the dict makes it call `.to(device)` on a
        # dict and fail; the app hit exactly that.
        wave = torch.from_numpy(np.ascontiguousarray(clip)).unsqueeze(0).unsqueeze(0)
        vector = embedder(wave)
        if hasattr(vector, "detach"):
            vector = vector.detach().cpu().numpy()
        array = np.asarray(vector).flatten()
        if not np.all(np.isfinite(array)):
            sys.exit(f"{label}: non-finite embedding at {start:.2f}s ({speaker})")
        out.append({
            "speaker": speaker,
            "start": round(float(start), 3),
            "end": round(float(start + duration), 3),
            "embedding": [float(x) for x in array],
        })
    if skipped:
        print(f"{label}: skipped {skipped} turns under {min_duration}s",
              file=sys.stderr)
    return out


def mean_vector(vectors):
    return [sum(column) / float(len(vectors)) for column in zip(*vectors)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("models_dir")
    parser.add_argument("manifest")
    parser.add_argument("--out", required=True, help="corpus JSON to write")
    parser.add_argument("--min-duration", type=float, default=0.5,
                        help="skip turns shorter than this (seconds). Embeddings of "
                             "very short clips are noise; the default keeps the "
                             "sub-second turns `assign` deliberately refuses to mint "
                             "a speaker from, while dropping the unusable ones")
    args = parser.parse_args()

    if not os.path.isdir(args.models_dir):
        sys.exit(f"models dir not found: {args.models_dir}")
    with open(args.manifest) as f:
        manifest = json.load(f)

    base = os.path.dirname(os.path.abspath(args.manifest))

    def resolve(path):
        return path if os.path.isabs(path) else os.path.join(base, path)

    enrolments_in = manifest.get("enrolments") or []
    recordings_in = manifest.get("recordings") or []
    if not enrolments_in:
        sys.exit("manifest has no enrolments — with no stored profile there is "
                 "nothing for the seed anchor to weight")
    if not recordings_in:
        sys.exit("manifest has no recordings to replay")

    # The held-out check. An enrolment recording that is also replayed makes
    # every anchor weight look good, because the profile already contains the
    # exact acoustics being matched against.
    enrolment_wavs = {os.path.realpath(resolve(e["wav"])) for e in enrolments_in}
    for recording in recordings_in:
        if os.path.realpath(resolve(recording["wav"])) in enrolment_wavs:
            sys.exit(f"{recording['wav']} is used both as an enrolment and as a "
                     f"replayed recording. Enrolment audio must be held out — see "
                     f"docs/seed-anchor-sweep.md")

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
        embedder = getattr(pipeline, "_embedding", None)
        if embedder is None:
            sys.exit("pipeline._embedding not available — pyannote version changed?")
    finally:
        os.unlink(tmp.name)

    # Enrolments: the stored profile is the mean of that speaker's embeddings
    # in the held-out recording, with sampleCount the number of them. That is
    # exactly what `SpeakerProfileStore.updateProfile` would have written from
    # a recording where they were recognised, because the pool's
    # `observedCentroid` is a running mean and a running mean is the mean.
    enrolments = []
    for entry in enrolments_in:
        speaker = entry["speaker"]
        wav = resolve(entry["wav"])
        samples, sample_rate = load_wav(wav)
        turns = [t for t in read_rttm(resolve(entry["rttm"])) if t[2] == speaker]
        if not turns:
            sys.exit(f"{entry['rttm']}: no turns for enrolled speaker {speaker}")
        vectors = [u["embedding"] for u in
                   embed_turns(embedder, samples, sample_rate, turns,
                               args.min_duration, f"enrol/{speaker}")]
        if not vectors:
            sys.exit(f"enrol/{speaker}: every turn was too short to embed")
        enrolments.append({
            "speaker": speaker,
            "centroid": mean_vector(vectors),
            "sampleCount": len(vectors),
        })
        print(f"enrol/{speaker}: {len(vectors)} utterances", file=sys.stderr)

    recordings = []
    for entry in recordings_in:
        wav = resolve(entry["wav"])
        samples, sample_rate = load_wav(wav)
        turns = read_rttm(resolve(entry["rttm"]))
        utterances = embed_turns(embedder, samples, sample_rate, turns,
                                 args.min_duration, entry["id"])
        if not utterances:
            sys.exit(f"{entry['id']}: no usable turns")
        recordings.append({
            "id": entry["id"],
            "setup": entry.get("setup"),
            "utterances": utterances,
        })
        speakers = sorted({u["speaker"] for u in utterances})
        print(f"{entry['id']}: {len(utterances)} utterances, speakers {speakers}",
              file=sys.stderr)

    corpus = {"enrolments": enrolments, "recordings": recordings}
    with open(args.out, "w") as f:
        json.dump(corpus, f)

    enrolled = {e["speaker"] for e in enrolments}
    heard = {u["speaker"] for r in recordings for u in r["utterances"]}
    setups = sorted({r["setup"] for r in recordings if r.get("setup")})
    print(f"\nwrote {args.out}", file=sys.stderr)
    print(f"  enrolled speakers: {len(enrolled)}", file=sys.stderr)
    print(f"  speakers heard but not enrolled: {sorted(heard - enrolled)}",
          file=sys.stderr)
    print(f"  enrolled but never heard: {sorted(enrolled - heard)}", file=sys.stderr)
    print(f"  capture setups: {setups}", file=sys.stderr)
    if len(enrolled) < 8:
        print("  WARNING: #206's bar for acting on a result is >= 8 speakers",
              file=sys.stderr)
    if len(setups) < 2:
        print("  WARNING: fewer than two capture setups — the cross-setup case is "
              "the one the seed anchor exists for", file=sys.stderr)


if __name__ == "__main__":
    main()
