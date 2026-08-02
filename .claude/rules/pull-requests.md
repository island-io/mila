# Pull Requests

## Every PR must be linked to a GitHub issue

**This is enforced by CI** — the `Require linked issue` workflow
(`.github/workflows/require-linked-issue.yml`, check name **"Linked issue"**)
fails any PR that has no linked issue.

1. **Create the issue first** if one doesn't already exist. Describe the
   problem, the root cause, and the intended fix — a repro helps.
2. **Link the PR to the issue.** Either mechanism satisfies the check:
   - a closing keyword in the PR description — `Closes #<n>` (`Fixes` and
     `Resolves` work too, any case; so do the `owner/repo#<n>` and full-URL
     forms). `.github/pull_request_template.md` puts a `Closes #` line at the
     top so this is the default path;
   - GitHub's own linkage, via the sidebar **Development → Link an issue**.

A closing keyword is preferred — it also auto-closes the issue on merge, so the
two stay permanently cross-referenced.

**Why:** the issue is the durable, searchable record of *what was wrong and
why*; the PR is *how it was fixed*. Linking them keeps that history navigable
(release notes, regression hunts, "why did we change this?" archaeology)
instead of scattering the context across commit messages that are easy to lose.

### Scope and escape hatches

The requirement applies to **every** PR, not just bug fixes. This replaces the
older "trivial chores don't need an issue" carve-out, which in practice was
self-applied to almost everything. Two exemptions exist instead, both narrow
and both visible:

- **Dependabot PRs are exempt automatically.** They can never have an issue,
  and the repo receives them regularly; without this every dependency bump
  would be permanently red. Detected by the PR author (or triggering actor)
  being `dependabot[bot]`.
- **The `no-issue-needed` label bypasses the check.** For genuine trivia — a
  typo, a comment tweak. It is a deliberate, attributable maintainer action
  that shows up in the PR timeline, which is the point: skipping the rule
  should leave a trace rather than being the silent default. Adding or removing
  the label re-runs the check immediately.

Anything a user could file a bug about does not qualify for the label.

### Notes for maintainers

- The check runs on `pull_request`, not `pull_request_target`, so it never runs
  privileged against untrusted fork code and it checks nothing out. Fork PRs
  are still checked; the only degradation is that the read-only fork token
  cannot post the explanatory comment, so the guidance goes to the failure
  annotation and the run summary instead.
- The workflow posts a single comment and updates it in place — pushes do not
  spam new comments, and the comment flips to a resolved note once the link is
  added.
- Placeholder text inside HTML comments does not count: the check strips HTML
  comments before matching, so an unfilled `Closes #` template still fails.

## CodeRabbit must have reviewed the code that is merging

**This is enforced by CI** — the `Require CodeRabbit review` workflow
(`.github/workflows/require-coderabbit-review.yml`, check name **"CodeRabbit
reviewed head"**) fails any PR whose **current head commit** has no CodeRabbit
review.

### Do not trust the `CodeRabbit` status check

The `CodeRabbit` status check that the app itself posts goes **green even when
no review happened**, including when the account hits its per-user review quota
and the bot refuses to start. Reading it as "reviewed" is what caused the
2026-08-01/02 incident: of ten PRs merged in 24 hours, seven landed code
CodeRabbit had never seen — #118, #120, #126 and #150 were never reviewed at
all, and #133, #145 and #148 were reviewed and then had further commits pushed
before merge.

### What counts as reviewed

Exactly one of these, and it must point at the **current head SHA**:

1. a review object from `coderabbitai[bot]` with `commit_id == head` **and** a
   substantive body (>200 chars — the "Actionable comments posted: N" summary
   qualifies);
2. inline review comments from `coderabbitai[bot]` whose `original_commit_id`
   is the head;
3. an issue comment from `coderabbitai[bot]` reading `Review complete …
   <short-sha>` for the head, e.g. "Review complete. I found no issues in
   `005bc14`." — CodeRabbit frequently files its verdict this way and posts no
   review object at all.

### What does *not* count (the two traps)

- **Empty review objects.** CodeRabbit files a `COMMENTED` review with a
  zero-length body every time it merely replies in a thread, and that object
  carries the current head SHA. Matching on `commit_id == head` alone therefore
  waves unreviewed code straight through. Hence the body-length requirement.
- **A "Review limit reached" notice.** It is the *opposite* of a review: the
  quota was exhausted and the review never started. The check refuses it and
  quotes the "Next review available in: N minutes" countdown in its output, so
  a red check reads as "blocked on quota", not "the bot is broken".

One more subtlety: for inline comments GitHub rolls `commit_id` *forward* to the
newest commit where the thread still applies, so it does not prove the comment
was written against the head. `original_commit_id` — the commit the comment was
actually authored on — is the one to match.

### Clearing the check

It re-evaluates itself; no manual re-run is needed. Beyond `pull_request`, it
also triggers on `pull_request_review` (submitted) and on `issue_comment`
(created, restricted to CodeRabbit's own comments on PRs), so it flips green the
moment the review lands. Those two events run against the default branch rather
than the PR head, so the job re-reports the same check name on the head SHA via
the Checks API; GitHub takes the most recent check run per name, which
supersedes the earlier red one.

### Escape hatch

- **The `coderabbit-not-required` label bypasses the check** — a deliberate,
  attributable maintainer action visible in the PR timeline. It is the *only*
  way past this gate. Adding or removing it re-evaluates immediately.
- **Dependabot is deliberately not exempt** here (unlike the linked-issue
  gate): CodeRabbit does review dependabot PRs, so there is nothing to work
  around.

Rate-limited? Wait out the countdown before commenting `@coderabbitai review` —
a request filed too early is refused, and repeated requests just churn the
queue.
