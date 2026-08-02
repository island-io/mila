# Pull Requests

## Every fix PR must be linked to a GitHub issue

When opening a PR that fixes a bug or changes reported behavior, it MUST be
connected to a GitHub issue:

1. **Create the issue first** if one doesn't already exist. Describe the
   problem, the root cause, and the intended fix — a repro helps.
2. **Link the PR to the issue** in the PR description with a closing keyword —
   `Closes #<n>` (or `Fixes #<n>`) — so merging the PR auto-closes the issue and
   the two stay permanently cross-referenced.

**Why:** the issue is the durable, searchable record of *what was wrong and
why*; the PR is *how it was fixed*. Linking them keeps that history navigable
(release notes, regression hunts, "why did we change this?" archaeology)
instead of scattering the context across commit messages that are easy to lose.

This applies to bug fixes and behavior changes. Trivial chores (typo fix,
comment tweak, dependency bump) don't need an issue, but anything a user could
file a bug about does.
