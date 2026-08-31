# Persisted formats are cross-process and cross-version contracts

Several files here are read by a **different process** than wrote them (the
embedded MCP helper) or by an **older build** than wrote them (a user who has not
updated). Changing what is written is changing a contract.

## Mirrors must move in lockstep — including nested types

A read-only mirror of a persisted type exists so a separate binary can decode the
store without pulling in the app's dependencies. When the app's type gains a
field, the mirror must gain it too, or the helper silently stops seeing data.

**A round-trip test cannot catch this**, because `JSONDecoder` ignores unknown
keys. Only a key-set assertion can. And a key-set assertion that compares only
**top-level** keys is not enough: element types inside arrays encode as nested
objects, so the top-level check sees the array key present on both sides however
far the element fields have drifted. That exact hole hid three unmirrored fields
on one element type, one of which carried the distinction between a commitment
the user *spoke aloud* and one a model *inferred* — a distinction a client had no
way to recover.

Keep the mirror's decoding lenient (decode-if-present with defaults) so an older
helper survives a newer app's schema.

## Ordering and handoffs

When a sidecar or pointer file tells another process "the real thing is ready",
publish it only **after** the write it refers to has completed *and reported
success*. Publishing on a status that is still pending points the reader at
something that does not exist yet — and a fixture asserting the premature
handoff will make that look intentional.

## What to flag

- A new or changed field on a persisted type with no corresponding mirror change.
- A key-set drift test that stops at depth 1.
- A mirror using non-optional decoding that would fail on an older file.
- A "ready"/"final" marker published before, or without checking, the write it
  points at.
- An absolute path written into a file that another process resolves, without
  verifying the reader would resolve the same location.
