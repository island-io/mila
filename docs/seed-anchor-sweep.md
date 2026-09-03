# Running the seed-anchor sweep (#206)

This is the procedure for answering a question the repository has been unable
to answer since the code was written: **is `3` the right seed anchor weight?**

Everything here exists so that whoever first has the audio does not have to
re-derive the protocol from a GitHub comment. Nothing here has been run —
nobody has the corpus yet, which is exactly why the question is still open.

## The question

When a recording starts, `LiveSpeakerDiarizer.seedPool` turns every stored
voice profile into a pool entry whose `sampleCount` is capped at
`seedAnchorWeight` — **n₀**, currently 3. `assign` folds each confident match
into that entry's centroid as a running mean, which telescopes over *k*
matches to

```
centroid_k = (n₀·c₀ + Σ eⱼ) / (n₀ + k)
```

so n₀ is literally *how many of this session's utterances the stored voice is
worth*. It is the only knob controlling how strongly a returning speaker's
stored centroid anchors matching, versus adapting to today's mic, room and
throat.

Since #204 it is a **matching-only** parameter — the persisted delta is
`observedCentroid`/`observedCount`, which n₀ never touches — so it can be
tuned with no risk to anyone's stored profiles. #248 pinned the value and
wrote down the derivation. What neither did, and what no amount of arithmetic
can do, is say whether 2, 3 or 4 recognises returning speakers *better*. Both
ends are provably wrong (0 discards the stored voice on its first match;
uncapped makes within-recording adaptation arithmetically impossible), and
everything in between is well-formed. That is an empirical question.

## What you need

From #206's protocol. The corpus is the expensive part; the sweep is free.

* **≥ 8 speakers.** The decision rule below is a paired test across speakers,
  and 8 is about the weakest thing worth acting on.
* **≥ 3 recordings per speaker, spanning ≥ 2 capture setups** — different
  mic, room, or headset. The cross-setup case is the *whole point*: a corpus
  recorded in one room on one microphone cannot show the thing the anchor
  weight trades off.
* **Real multi-party conversation, not read speech.** `assign` is fed VAD
  utterances, so realistic lengths (many under two seconds) and channel
  conditions matter. It refuses to mint a new speaker from anything under a
  second, so a corpus of tidy long turns exercises a path users rarely hit.
* **≥ 20 utterances per speaker per recording**, with per-utterance
  ground-truth labels (RTTM).
* **One held-out enrolment recording per speaker**, used only to build the
  stored profile. If enrolment audio is also replayed, the profile already
  contains the acoustics being matched against and every anchor weight scores
  implausibly well. `extract-voice-embeddings.py` refuses that overlap.

## Step 1 — extract embeddings once

This is the only slow step, and the only one needing pyannote or a GPU.

Write a manifest naming the audio and its ground truth:

```json
{
  "enrolments": [
    {"speaker": "alice", "wav": "alice-enrol.wav", "rttm": "alice-enrol.rttm"},
    {"speaker": "bob",   "wav": "bob-enrol.wav",   "rttm": "bob-enrol.rttm"}
  ],
  "recordings": [
    {"id": "standup-01", "setup": "headset-office",
     "wav": "standup-01.wav", "rttm": "standup-01.rttm"},
    {"id": "standup-02", "setup": "laptop-mic-kitchen",
     "wav": "standup-02.wav", "rttm": "standup-02.rttm"}
  ]
}
```

Audio must be 16 kHz mono WAV — what Mila records. Convert with
`ffmpeg -i in.m4a -ar 16000 -ac 1 out.wav`.

```
python3 scripts/extract-voice-embeddings.py \
  /Applications/Mila.app/Contents/Resources/DiarizationModels \
  manifest.json --out corpus.json
```

The script embeds every labelled turn with the same model the app uses, builds
each stored profile as the mean of that speaker's held-out embeddings (which is
what `SpeakerProfileStore.updateProfile` would have written, because a running
mean is the mean), and prints a summary — speakers enrolled, speakers heard but
not enrolled, capture setups, and warnings if the corpus is below the bar
above.

Keep `corpus.json`. Every later run replays it, so results stay comparable and
nobody needs the audio again.

## Step 2 — run the sweep

```
make project        # project.yml is the source of truth; regenerate first

MILA_SEED_ANCHOR_CORPUS=$PWD/corpus.json \
MILA_SEED_ANCHOR_REPORT=$PWD/grid.json \
  xcodebuild -project Mila.xcodeproj -scheme Mila -configuration Debug \
    -derivedDataPath build -destination 'platform=macOS' \
    -only-testing:MilaTests/SeedAnchorSweepTests/test_sweep_a_provided_corpus \
    test
```

The grid is printed to stdout, so it lands in xcodebuild's output; pipe through
`tee` if you want it in a file. `MILA_SEED_ANCHOR_REPORT` is the dependable
route — a machine-readable grid you can attach to the issue or diff against a
later run.

If the environment variables do not reach the test process on your setup, set
them in the scheme's **Test** action instead (Product → Scheme → Edit Scheme →
Test → Arguments → Environment Variables). The test reads them through
`ProcessInfo`, so either route works.

It replays the corpus through the **real** `seedPool` / `assign` — not a model
of them — once per cell of

* n₀ ∈ {1, 2, 3, 4, 6, 8, 12, uncapped}
* `similarityThreshold` ∈ {0.50, 0.55, 0.60, 0.65, 0.70}

and prints the grid. Narrow it with `MILA_SEED_ANCHOR_WEIGHTS=1,2,3,uncapped`
and `MILA_SEED_ANCHOR_THRESHOLDS=0.55` while you are getting set up.

The threshold is swept alongside n₀ rather than held at its default because
the two interact: n₀ sets how fast the compared centroid moves, and the
threshold sets how far it may move before a match is refused. The best n₀ at
0.55 need not be the best at 0.70 — and Settings lets users pick anything in
0.5–0.95.

Without `MILA_SEED_ANCHOR_CORPUS` the test skips. That skip is the honest
state of the question, not a failure.

## Step 3 — read the grid

Five tables come out. **Expect them to disagree; that disagreement is the
signal.**

1. **Returning-speaker recall** — utterances whose true speaker reached the
   entry seeded from *their* profile. "It recognised me." Note this counts the
   raw-id assignment, including a *borderline attach* that produces an interval
   without folding into the centroid. Whether the speaker's **name** actually
   appeared is table 3.
2. **Cross-speaker false-attach rate** — utterances that landed on someone
   else's seeded entry, over all utterances. This is the harm: the wrong name
   against someone's words, and the wrong voice folded into a stored profile.
   Counted for non-enrolled speakers too — a stranger landing on Alice's entry
   is exactly as harmful as Bob doing it.
3. **Auto-name precision / recall** — did the recording end up applying the
   right names? This includes `RecognisedSpeakerAssigner.finish`'s
   `observedCount > 0` guard, which per-utterance metrics cannot see: a speaker
   who only ever attached borderline is *not* auto-named, however many
   utterances they got.
4. **Speaker-count error** — `|ids used − true speakers|`, plus the signed
   version. Positive is over-segmentation. Watch this one when reading a heavy
   anchor: keeping the entry further from today's acoustics makes a returning
   speaker's *later* utterances more likely to fall below the create floor and
   mint a duplicate `SPEAKER_NN`, so a **stronger** anchor can *increase*
   fragmentation. That runs opposite to intuition and is a reason to distrust
   reasoning here.
5. **Exact Wilcoxon p** for per-speaker recall against the shipping weight, at
   the same threshold.

Two rules for reading it:

* **Judge a weight by its worst cell across the threshold row, not its best.**
  Users can set any threshold in 0.5–0.95, so a weight that is excellent at
  0.55 and dreadful at 0.70 has not earned the default.
* **The paired test is across speakers, never across utterances.** Utterances
  within a recording are heavily correlated — same mic, same room, same
  cold — so an utterance-level test will report significance that is not there.
  The harness pairs per-speaker recall for exactly this reason.

## Step 4 — decide, and prefer the smaller number

The report prints a starting point: the smallest weight whose worst-case
false-attach rate is within a tolerance of the grid's best. Treat it as a
starting point — the tolerance is a judgement call with no measurement behind
it, and the gate that matters is the paired test over ≥ 8 speakers.

Ties go to the **smaller** weight, on an asymmetry that is an argument rather
than a guess:

* A too-light anchor lets one noisy or false-positive match half-steal the
  entry — but the damage is confined to that recording, because n₀ never
  reaches persistence.
* A too-heavy anchor keeps a returning speaker below the match threshold
  forever. They never confidently match, so `observedCount` stays 0, so
  `finish` correctly refuses to auto-name them, so **nothing is learned and
  the profile can never adapt in a future recording either.** The profile that
  most needs updating becomes the one that cannot be updated.

If the answer is not 3, change these together:

1. `LiveSpeakerDiarizer.seedAnchorWeight`;
2. the weight table and rationale in its doc comment;
3. `SeedAnchorWeightTests` — it hardcodes 3 deliberately, as a tripwire;
4. post the report into #206 so the next person sees the evidence, not just
   the number.

If the answer *is* 3, that is a result worth posting too. It is the difference
between a measured 3 and the current one.

## What this does not measure

#206 carries a second question the sweep does not touch: the stored centroid is
a plain running mean over every observation ever recorded, so it never forgets
old acoustics. A decayed or windowed mean might recognise a returning speaker
better.

That is deliberately out of scope here, and the order of experiments matters:

* **Cheapest first, and it changes no persisted state.** Have `assign` compare
  against both the stored centroid *and* the most recent recording's observed
  centroid, taking the higher similarity. Pure matching change, no schema
  change, measurable on this same corpus with this same harness, and it
  degrades safely — it can only make a returning speaker easier to match.
* **A windowed mean beats a decay constant** if it comes to that: keeping the
  last K per-recording observations gives forgetting *and* repair (a bad
  observation can be dropped, which a decayed scalar can never be). The cost
  is a `speaker-profiles.json` schema change, which needs lenient decoding for
  older builds and `VoiceProfile.unusableReason` extended to validate every
  element of the window — that file is user-editable, and a NaN reaching a
  centroid poisons it permanently.
* Note that the stored mean **already** forgets slowly and by accident:
  `updateProfile` clamps the stored count at `VoiceProfile.maxSampleCount`
  while dividing by the true total, so a mature profile's effective learning
  rate settles at a floor instead of going to zero. An explicit decay would
  compound with that. Decide the interaction deliberately.

## Corpus file format

Written by `extract-voice-embeddings.py`, read by `SeedAnchorCorpus` in
`MilaTests/SeedAnchorSweepHarness.swift`.

```json
{
  "enrolments": [
    {"speaker": "alice", "centroid": [0.01, -0.02, "…"], "sampleCount": 24}
  ],
  "recordings": [
    {"id": "standup-01", "setup": "headset-office",
     "utterances": [
       {"speaker": "alice", "start": 12.4, "end": 14.9,
        "embedding": [0.01, -0.03, "…"]}
     ]}
  ]
}
```

* `centroid` / `embedding` — every vector in the corpus must have the same
  dimension (256 for the bundled wespeaker model). A mismatch is refused
  rather than measured: `assign` cannot make a confident match across
  dimensions, so a mixed corpus would score zero recall for a reason that has
  nothing to do with the anchor.
* `sampleCount` — must be in `1...VoiceProfile.maxSampleCount`, the same bound
  `updateProfile` enforces, so the sweep only ever sees profiles the app could
  have written.
* `start` / `end` — seconds. Both matter: replay is chronological, and
  `assign` treats a sub-second utterance as untrustworthy for minting a
  speaker.
* `setup` — optional free text, reported so you can confirm the corpus really
  spans more than one capture setup.

Non-finite values, empty vectors, duplicate enrolments for one speaker and
empty recordings are all refused up front, because each of them produces a
grid of plausible numbers that measures nothing.
