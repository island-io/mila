# The Mila website

`site/` is Mila's public one-pager: what the app is, one download button, and a
section for teams that want to run their own transcription server. It is plain
HTML and CSS with one small script, no build step, no trackers and no
third-party assets.

It is served by GitHub Pages at **https://island-io.github.io/mila/**.

## What is in `site/`

| File | Purpose |
|---|---|
| `index.html` | The page. All asset links are relative, so it works under `/mila/` and at the root of a custom domain. |
| `styles.css` | Styles. System fonts, light and dark mode via `prefers-color-scheme`. |
| `download.js` | Points the download buttons at the latest stable DMG (see below). |
| `robots.txt`, `sitemap.xml` | Crawler hints. |
| `favicon.svg`, `favicon-64.png`, `apple-touch-icon.png`, `icon-256.png` | Copied from the app icon (`design/AppIcon.svg` and `Mila/Assets.xcassets/AppIcon.appiconset/`). |
| `og-image.png` | 1200×630 social preview, made from the app icon with ImageMagick. |

To preview locally, serve the folder with any static server, for example
`python3 -m http.server -d site 8000`, and open http://localhost:8000/.

### The download button

Release assets carry the version in their name (`Mila-1.9.6.dmg`), so there is
no fixed `releases/latest/download/<name>` URL. In the HTML the button links to
`https://github.com/island-io/mila/releases/latest`, which always redirects to
the newest stable release page. When the page loads, `download.js` asks GitHub's
public API for `/repos/island-io/mila/releases/latest` and, if that returns a
`.dmg` asset, swaps the button's link to the DMG itself and shows the version.

`/releases/latest` never returns drafts or pre-releases, so beta builds are
never offered on the site. If the API is unreachable or rate-limited (60
requests an hour per visitor IP), the button keeps the release-page link. The
page's Content-Security-Policy allows that one request (`connect-src
https://api.github.com`) and nothing else outside the site.

## How it is published

GitHub Pages for this repository is served **from the `gh-pages` branch**. That
branch already carries the Sparkle update feed: the release pipeline commits
`appcast.xml` there, and every installed copy of Mila checks
`https://island-io.github.io/mila/appcast.xml` for updates (`SUFeedURL` in
`project.yml`).

`.github/workflows/pages.yml` therefore publishes the site by copying `site/`
into `gh-pages`, next to the feed:

- It publishes on every push to `main` that touches `site/**`,
  `scripts/check-site.py` or the workflow, and on demand from
  **Actions → Website → Run workflow**. Pull requests touching the same paths
  run only the validation job, with read-only permissions and no push.
- `scripts/check-site.py` validates `site/` first (on PRs and again right
  before every publish). It fails on:
  - any entry that is not a regular file or a directory. A symlink would let
    the copy write somewhere it does not own, such as the feed.
  - a name reserved for `gh-pages`: `appcast.xml`, `.nojekyll`, `CNAME` or
    `.site-files` at the top level, or `.git` anywhere.
  - a local reference that does not resolve inside `site/`, or a root-relative
    `/...` URL, which would break under `/mila/`. It checks `href`, `src` and
    `srcset` (either quote style) and CSS `url()` in `.css` files and inline in
    HTML.
- The copy and the `gh-pages/.site-files` manifest come from one list of
  regular files. On the next run, only names from that manifest that have left
  `site/` are deleted. Nothing else on the branch is touched, and
  `appcast.xml`, `.nojekyll` and `CNAME` are never written or deleted.
- It never force-pushes. See the next section for how it handles a push from
  the release pipeline that lands at the same time.

GitHub's own Pages build then serves the new commit, usually within a minute.

### Two writers on `gh-pages`

The branch now has two writers, and both must follow the same rules.

**The Website workflow** (this repository) only ever adds a commit on top of
the current tip. If its push is rejected because the tip moved, it fetches the
new tip and rebases, but only when that is provably safe. Otherwise it fails
the run and changes nothing:

- If the old tip is no longer an ancestor of the new one, the branch was
  force-pushed or rebuilt. The run fails.
- If the new commits touched any file the run is writing, the run fails rather
  than overwrite another writer's file.
- If the push is still rejected after four retries, the run fails.

A failed run is safe to re-run once the cause is understood.

**The release pipeline** (private, maintained by the original authors) must:

1. **Fetch and rebase (or merge) onto the current `gh-pages` tip before
   pushing `appcast.xml`, and retry on a non-fast-forward rejection.** Since
   this workflow can push between the pipeline's checkout and its push, a
   pipeline that gives up on a rejected push leaves a release without its feed
   entry.
2. **Never force-push `gh-pages`, and never rebuild it from scratch** (an
   orphan commit or a fresh tree containing only `appcast.xml` and
   `.nojekyll`). Either would delete the website until its next publish. Change
   only `appcast.xml`.

The branch's history so far (one "Publish Mila … to the update feed" commit
per release, each touching only `appcast.xml`) suggests the pipeline already
commits incrementally. Confirm the retry behaviour in the pipeline itself.

### No repository setting to change, and one not to change

Nothing needs to be enabled: Pages is already on and serving `gh-pages`.

**Do not switch Settings → Pages → Source to "GitHub Actions".** That mode
serves only what a workflow uploads with `actions/deploy-pages`; pushes to
`gh-pages` stop being published. The site would keep working, but every
release's `appcast.xml` would stop reaching users, and auto-updates would
freeze with no error anywhere. Moving to Actions-based deploys is possible
later, but only together with a change to the release pipeline: the deploy
would have to include the feed, and the pipeline would have to trigger it after
each `appcast.xml` commit.

### The site's address

The absolute URLs a page needs (canonical link, Open Graph and Twitter image,
`robots.txt`'s sitemap line, `sitemap.xml`) are written as
`https://island-io.github.io/mila/` in `site/`. To publish under another
address without editing those files, set a repository variable
**`SITE_URL`** (Settings → Secrets and variables → Actions → Variables), for
example `https://mila.example.com/`, and re-run the Website workflow. The
workflow substitutes it into the copies it publishes, as a literal string
replacement.

**Forks** get their own site without editing `site/`. When the workflow runs in
a repository other than `island-io/mila`, it does three things:

- It rewrites `https://github.com/island-io/mila` links to the fork's
  repository.
- It rewrites the `<meta name="mila-repo">` tag that `download.js` reads, so
  the button offers the fork's own releases.
- It defaults the site URL to `https://<owner>.github.io/<repo>/`.

`SITE_URL` still takes precedence.

Note that crawlers only read `robots.txt` at the root of a host, so
`/mila/robots.txt` on github.io has no effect; it starts to count once the site
has its own domain. Until then, submit `sitemap.xml` in Google Search Console
to speed up indexing.

## Moving to a custom domain

Whatever you choose, keep one thing in mind: **`https://island-io.github.io/mila/appcast.xml`
is compiled into every Mila that has ever shipped.** That URL must keep
answering, either with the feed or with a redirect to it, for as long as old
builds should get updates. Both options below keep it working.

### Option A: point a subdomain straight at GitHub Pages

The simplest setup. GitHub serves the site and issues the TLS certificate.

**The risk window.** As soon as a custom domain is saved, GitHub starts
redirecting `island-io.github.io/mila/...` to the custom domain. Until GitHub
has issued the domain's certificate and **Enforce HTTPS** is on, that redirect
can point at `http://` (and the domain may not answer HTTPS at all). App
Transport Security makes Sparkle refuse a plain-HTTP feed. So during that
window every installed Mila's update check fails. A failed background check is
silent and retried on the next schedule, so nothing breaks permanently, but a
release published inside the window does not reach anyone. GitHub can take
from minutes up to 24 hours to issue the certificate. Keep the window short
and away from releases:

1. **Verify the domain first** (Organization settings → Pages → Add a domain,
   which adds a DNS `TXT` record). This stops anyone else from claiming it for
   their own Pages site.
2. **Create the DNS record before touching GitHub**: a `CNAME` for the
   subdomain (for example `mila.example.com`) pointing to
   `island-io.github.io`. Wait until it resolves publicly
   (`dig +short mila.example.com` returns the github.io name). GitHub only
   requests the certificate once DNS points at it, so this makes issuing fast.
3. **Pick a quiet moment**: just after a release, with no release planned
   until the steps below are done.
4. In the repository, **Settings → Pages → Custom domain**: enter the subdomain
   and save. GitHub commits a `CNAME` file to `gh-pages`, and the Website
   workflow leaves that file alone. The window starts now.
5. Reload the Pages settings until **Enforce HTTPS** can be ticked (it stays
   greyed out while the certificate is pending), then tick it. The window ends
   here.
6. Check what installed apps will see:
   `curl -sI https://island-io.github.io/mila/appcast.xml` must answer `301`
   with `location: https://mila.example.com/appcast.xml`, and
   `curl -sI https://mila.example.com/appcast.xml` must answer `200`.
7. Set the `SITE_URL` repository variable to `https://mila.example.com/` and
   re-run the Website workflow so the canonical and social URLs match.

If the certificate is still pending after a few hours, removing the custom
domain ends the window: github.io serves directly again.

From then on GitHub answers `island-io.github.io/mila/...` with a 301 redirect
to `https://mila.example.com/...`, keeping the path. Sparkle follows HTTPS
redirects, so installed apps keep finding `appcast.xml` at its new address.
Option B has no such window, because nothing about github.io changes.

The release pipeline can keep writing the same `appcast.xml`; its `<link>`
element still names the github.io URL, which is harmless.

### Option B: CloudFront in a separate AWS account, GitHub Pages as origin

Useful if the domain has to be served from company AWS infrastructure: shared
certificates, WAF, access logs, or a domain whose DNS lives in Route 53.

1. **Do not set a custom domain in GitHub Pages in this mode.** With a custom
   domain set, GitHub redirects every github.io request to that domain, so
   CloudFront fetching from github.io would get a redirect pointing back at
   itself, and the page would loop.
2. **Certificate:** request a public certificate for the domain in **AWS
   Certificate Manager in `us-east-1`** (CloudFront only uses certificates from
   that region), validated by DNS.
3. **Origin:** a custom origin with domain `island-io.github.io`, origin path
   `/mila`, protocol **HTTPS only**, TLS 1.2. GitHub Pages picks the site by
   the `Host` header, so the request must reach it with
   `Host: island-io.github.io`. With no origin request policy CloudFront
   already does that; if you need one, use the managed
   `AllViewerExceptHostHeader`, never `AllViewer`. Forwarding the viewer's
   `Host` makes GitHub answer 404.
4. **Behaviour:** redirect HTTP to HTTPS, allow `GET`/`HEAD`, compress
   objects. The managed `CachingOptimized` policy is fine for the page and
   assets. Give `appcast.xml` its own behaviour with a short TTL (or
   `CachingDisabled`) so a release reaches users as soon as it is published,
   not when the cache expires. GitHub Pages already sends
   `Cache-Control: max-age=600`.
5. **Alternate domain name:** add the domain, attach the ACM certificate, then
   point DNS at the distribution (Route 53 alias, or a `CNAME` elsewhere).
6. Set the `SITE_URL` repository variable to the domain and re-run the Website
   workflow. The site stays reachable on github.io as well; the canonical link
   tells search engines which address is the real one.
7. After a site change, either wait out the TTL or create an invalidation for
   `/*`.

Installed apps keep reading the feed from github.io directly; CloudFront is
only in the path for visitors who use the new domain.

### Which to choose

| | A: CNAME to GitHub Pages | B: CloudFront in front |
|---|---|---|
| Setup | One DNS record and one setting | Distribution, certificate, policies, DNS |
| TLS | Issued and renewed by GitHub | ACM certificate in `us-east-1`, renews automatically |
| Cost | Free | CloudFront traffic and requests (small for a one-pager) |
| Control | GitHub's CDN, headers and caching | Your own headers, WAF, logs, caching rules |
| Update feed | Redirected to the new domain | Untouched on github.io |
| Failure modes | DNS mistakes; update checks fail between saving the domain and enforcing HTTPS | Host header, redirect loop if a Pages custom domain is also set, stale cache |

**Recommendation:** start with option A, following the order above. It is one
DNS record, GitHub handles the certificate, and nothing new has to be
monitored. Move to option B only
when there is a concrete need for something CloudFront provides, such as
security headers, WAF rules, access logs, or a policy that public company
domains are served from company AWS accounts. Because every link in the site is
relative and the absolute URLs come from `SITE_URL`, switching between A, B and
plain github.io needs no change to `site/`.
