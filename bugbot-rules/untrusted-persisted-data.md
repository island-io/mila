# Validate persisted data before it reaches arithmetic or indexing

Files under Application Support are user-editable, and they are also written by
*older versions* of the app. A value that decodes successfully is not therefore
valid. Validate at the **decode boundary**, before the value can propagate.

## Float division does not trap — that is the dangerous part

A zero or negative count used as a divisor in `Int` arithmetic traps, which is at
least loud. In `Float` it yields `-inf`/`inf`/`NaN`, which propagates silently.
This shipped here: a negative sample count in a stored profile produced a NaN
centroid, and because `NaN > x` is **false**, the poisoned entry captured the
"best match" slot without ever clearing the threshold. Every utterance then
minted a fresh speaker, so the same voice became `SPEAKER_00`, `SPEAKER_01`, and
so on. Silent misrecognition, no crash, no log line.

Also present in the same area: an unvalidated vector length reaching a fold and
indexing past the end, and a count near `Int.max` trapping on overflow when
summed.

## Rules of thumb

- Reject rather than clamp-and-continue when the value is structurally
  impossible, and **drop the individual bad entry with a log line** rather than
  rejecting a whole file — one hand-edited row should not destroy the rest.
- If you clamp a stored value, make sure the clamp is applied to what is
  *stored*, not to a value also used as a **divisor**. Clamping the denominator
  while the numerator keeps its true weights silently stops producing a mean.
- Enforce an invariant where it is *local* to the risk. A guard that depends on
  a distant clamp (a Settings-side range, say) is only as good as that clamp, and
  mutable properties can be set from anywhere.
- Prefer a stated, bounded imprecision over a path that can trap — and say so in
  a comment, so the next reader knows it was a decision.

## What to flag

- A decoded count, length or dimension used in division, indexing or a sum
  without validation.
- A comment asserting an unconditional guarantee that actually depends on a
  positive threshold, a clamp elsewhere, or a caller behaving.
- Validation that rejects an entire file where per-entry rejection is possible.
