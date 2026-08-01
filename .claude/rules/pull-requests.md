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
