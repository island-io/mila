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

### Triaging a red "CodeRabbit reviewed head"

Read the job log line `signals — review@head:… inline@head:… verdict:…
walkthrough@head:… rateLimitNotices:…`, then:

- `review@head:no`, `inline@head:0`, `verdict:no`, `walkthrough@head:no`, **and
  a rate-limit notice that names the current head** → **quota stall**, not a
  gap. The count alone is not enough: `rateLimitNotices` tallies every notice on
  the PR, including ones left on older heads, so a stale notice can dress a real
  review gap up as a quota problem. Check that a notice names *this* head. See
  *The quota is per PR author* below.
- same signals, but no rate-limit notice naming the head, and CodeRabbit has
  plainly commented on the head → likely a **detector gap**; check the comment
  against the four signals below before assuming the bot misbehaved.
- otherwise → **a real gap**: the head genuinely has no review.

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
   review object at all;
4. an issue comment from `coderabbitai[bot]` carrying the **walkthrough**. This
   one needs three things at once, because the commit line alone proves
   nothing:
   - the structured commit line, ending at the head:

     > Reviewing files that changed from the base of the PR and between
     > `<base-sha>` and `<head-sha>`.

     Both the 40-char and abbreviated forms are accepted. The match is anchored
     on the **second** SHA — the first is the diff base, and matching either
     would let the base of a later push masquerade as a review of it;
   - **no** `rate limited by coderabbit.ai` or `review in progress by
     coderabbit.ai` HTML state marker in the body;
   - an actual verdict string — `No actionable comments were generated` or
     `Actionable comments posted:`.

**Why signal 4 exists.** A review that finds *nothing* files **no review object
at all** and posts no "Review complete" line — only that issue comment. Signals
1–3 all miss it, so the gate called such PRs unreviewed forever: #163
(walkthrough posted 22s after the PR opened), and #138, #113, #107, #101 in an
audit of the last 45 PRs. It cost a day of chasing imaginary rate limits.

**Why it needs all three conditions.** The prose names no commit, so it cannot
prove *which* code was read. The commit line names commits but only says they
were **fetched** — and CodeRabbit **edits one comment id in place** through its
whole lifecycle, so the same comment can be a placeholder, then a verdict, then
a rate-limit notice for the next push. #163's walkthrough is now, in place, a
rate-limit notice naming a newer head. Only commit line **+** verdict **+** no
contradicting marker means "a review concluded on this commit".

### What does *not* count (the traps)

- **Empty review objects.** CodeRabbit files a `COMMENTED` review with a
  zero-length body every time it merely replies in a thread, and that object
  carries the current head SHA. Matching on `commit_id == head` alone therefore
  waves unreviewed code straight through. Hence the body-length requirement.
- **A "Review limit reached" notice.** It is the *opposite* of a review: the
  quota was exhausted and the review never started. The check refuses it and
  quotes the "Next review available in: N minutes" countdown in its output, so
  a red check reads as "blocked on quota", not "the bot is broken".

  This one is sharper than it looks. The rate-limit notice **embeds the same
  `Reviewing files that changed … between <base> and <head>` line as the
  walkthrough**, naming the head it did *not* review. Across the last 45 PRs,
  19 of the 23 head-naming commit lines belong to a rate-limit notice — only 4
  are genuine walkthroughs. Signal 4 therefore vetoes the whole comment body on
  both the prose and the `rate limited by coderabbit.ai` marker, and signals 1
  and 3 veto on the prose too.
- **A "review in progress" placeholder.** CodeRabbit reuses one comment id and
  edits it through its lifecycle, so the *same* comment can be a placeholder,
  then a verdict, then a rate-limit notice for the next push — #163's
  walkthrough was edited into a rate-limit notice naming a newer head, in
  place. The placeholder also carries the commit line, so firing on it would
  pass a review that has not finished. Rejected on its
  `review in progress by coderabbit.ai` marker, and again by the missing
  verdict string.
- **A bare "Action performed / Review finished" acknowledgement.** That ~384-char
  receipt is what the bot posts for *every* CodeRabbit command; it names no
  commit, carries no verdict, and is not evidence that a review ran. It is by
  far the most common CodeRabbit comment on this repo (77 of them in the last
  40 PRs), and counting it would reopen the exact hole this gate closes.

One more subtlety: for inline comments GitHub rolls `commit_id` *forward* to the
newest commit where the thread still applies, so it does not prove the comment
was written against the head. `original_commit_id` — the commit the comment was
actually authored on — is the one to match.

### Always paginate

Every comments/reviews read in the workflow goes through `github.paginate` with
`per_page: 100`, and manual inspection must pass `gh api --paginate`. The API
default is **30 items per page**: on a chatty PR the newest CodeRabbit comment —
the one naming the current head — sits past page 1, and an unpaginated read
returns a stale slice with no error. That produced its own round of wrong
conclusions during the 2026-08-02 incident, independently of the missing
walkthrough signal.

### Clearing the check

It re-evaluates itself; no manual re-run is needed — any one of the four
signals above clears it. Beyond `pull_request`, it
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

### The quota is per PR *author*

The review limit is not per repo and not per whoever asks — it belongs to the
**PR author**, and the notices name them (`@urisland`, `@ValeroK`). Nobody else
can top it up or review on their behalf, so once an author is out of quota
their PR can sit unreviewable indefinitely, however many people comment on it.

The way out is to re-open the same branch as a PR from an account that has
quota (#164 / #165 are the worked example). Preserve authorship with a
`Co-authored-by:` trailer when you do.

### When the manual review command actually helps

Auto-review is enabled here, so while a review is pending or already done the
manual review command does nothing but reply "Review finished" — reaching for
it out of impatience is noise.

The exception matters: a review the **quota refused outright** is never
retried. No push, no timer, nothing restarts it. Once the countdown in the
rate-limit notice has elapsed, one manual review command is the only way to get
that PR reviewed — #165 was reviewed minutes after exactly that. Filed *before*
the countdown expires it is refused again and burns the attempt, so wait it out
first.

Note that the gate's own failure comment deliberately does not print the
command literally: CodeRabbit parses commands out of any comment body, fenced
or not, so a literal one in an automated comment makes the gate invoke a review
on every failure (#162 / #163).
