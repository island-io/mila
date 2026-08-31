# Consent gates must fail closed, and revocation must be complete

Mila gates access to recordings, transcripts and learned voice data behind
explicit user consent. Two properties matter, and **both have failed here
before**, in opposite directions.

## 1. Deny on missing, unreadable or malformed input

A gate that reads its answer from a file must treat *absent*, *unparseable* and
*unexpected shape* as **deny**, never as allow-by-default. Ask of any new gate or
any change to one: if this file did not exist, or contained garbage, would the
caller get access?

Do not put a cache in front of a gate. Re-read it per call, so revoking access
bites a process that is already running.

## 2. Publishing the two directions is not symmetric

Failing to publish *granted* is safe — the reader keeps denying. Failing to
publish *revoked* is **not** safe, because the previous "granted" state survives
a failed write and keeps granting. So the revoke path needs to escalate (delete
the file rather than overwrite it) and report failure honestly, and the UI must
not show an "off" switch that did not turn anything off.

## 3. Consent is necessary but not sufficient

What gets published should be `consent && the-thing-is-actually-reachable`.
Verify a write by reading back what an external reader would resolve, rather than
trusting that the write succeeded — a pointer can be written successfully and
still name a location the app has stopped using.

## 4. Revocation must stop reads, not only writes

Write gates are the easy half. If revoking leaves copied state in memory —
a seeded cache, a snapshot, a pool of loaded values — then reads continue to
serve revoked data for the rest of the operation. That has shipped here twice:
once for an explicit opt-out and once for a *different* toggle that also made the
feature unconfigured but had no observer wired to it.

When reviewing a revocation path, enumerate **every** way the feature can become
unavailable, and check each one clears the same state. If one trigger clears the
cache and another does not, the inconsistency is the bug even when the impact
looks small.

## What to flag

- A gate whose failure mode on a missing/corrupt input is "allow".
- A cache, memo or stored copy in front of a consent check.
- A revoke path that only stops persistence while reads continue.
- A new way to disable a feature that does not clear what the existing disable
  path clears.
- A write to a consent or location file that is not verified by reading back.
