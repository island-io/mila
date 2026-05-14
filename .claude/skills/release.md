---
name: release-islandwhisper
description: Use when the user asks to release, ship, cut a version, or tag a release of IslandWhisper. Triggers on "release", "cut a release", "ship it", "tag a version", "make a DMG", "push a release". Only applies when working directory is the IslandWhisper repo.
---

# Release IslandWhisper

Automates the full release SOP for IslandWhisper. Handles pre-flight checks, PR merge, tagging, and release workflow monitoring.

## Pre-flight

1. **Read version** from `project.yml` (`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`).
2. **Confirm version with user** — show current version, ask if it needs bumping. If yes, bump in `project.yml`, run `xcodegen generate`, commit, and push.
3. **Verify build number** (`CURRENT_PROJECT_VERSION`) is monotonically higher than the previous release. Sparkle keys updates on this value — a stale build number means existing installs won't see the update.
4. **Run `make test`** — all tests must pass (known flaky: `LLMRunnerTests.test_cursor_cli_returns_a_title_for_a_sample_transcript` can be ignored).
5. **Check CI on main** — `gh run list --workflow=CI.yml --branch=main --limit=1` should be green.

## Merge to main

6. If not already on `main`, find the current branch's PR:
   ```
   gh pr view --json number,mergeable,statusCheckRollup
   ```
7. Verify all checks pass and PR is mergeable. Merge with `gh pr merge <N> --merge --delete-branch`.
8. `git checkout main && git pull origin main`
9. Verify `git log --oneline -1` shows the expected HEAD.

## Tag and release

10. Create tag: `git tag v<VERSION>`
11. Push tag: `git push origin v<VERSION>`
12. Verify release workflow triggered: `gh run list --workflow=release.yml --limit=1`
13. Monitor: `gh run watch` (or poll with `gh run view <ID> --json status`).

## Post-release verification

14. Once workflow succeeds, verify the release page has the DMG:
    ```
    gh release view v<VERSION> --json assets -q '.assets[].name'
    ```
15. Report the release URL to the user: `gh release view v<VERSION> --json url -q .url`

## Manual fallback

If CI is unavailable, build locally:
```
make clean && make dmg
git tag v<VERSION> && git push origin v<VERSION>
gh release create v<VERSION> "IslandWhisper-<VERSION>.dmg" --title "IslandWhisper <VERSION>" --generate-notes
```

## Important

- Tags are **always** `v`-prefixed: `v1.3.2`, not `1.3.2`
- Version is bumped **only** in `project.yml` — `Info.plist` uses `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` placeholders
- After bumping `project.yml`, always run `xcodegen generate` to regenerate the xcodeproj
- DMG is ad-hoc signed; first launch requires right-click → Open
- If remote git/gh commands fail with TLS/sandbox errors, retry with `dangerouslyDisableSandbox: true`
