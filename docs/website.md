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

- It runs on every push to `main` that touches `site/**` (or the workflow
  itself), and on demand from **Actions → Website → Run workflow**.
- It checks that every relative link in `site/*.html` points at a file that
  exists, and that nothing uses a root-relative `/...` URL (which would break
  under `/mila/`).
- It never writes or deletes `appcast.xml`, `.nojekyll` or `CNAME`, and refuses
  to publish if `site/` contains one of those names.
- It records the files it published in `gh-pages/.site-files`, and on the next
  run deletes only files from that list that have left `site/`. Anything else
  on the branch is left alone.
- It pushes with retries. The release pipeline also pushes to `gh-pages`, but
  only ever changes `appcast.xml`, so rebasing onto its commits is always clean.

GitHub's own Pages build then serves the new commit, usually within a minute.

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
workflow substitutes it into the copies it publishes.

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

1. In DNS, add a `CNAME` record for the subdomain (for example
   `mila.example.com`) pointing to `island-io.github.io`.
2. Optionally, verify the domain for the organization (Organization settings →
   Pages → Add a domain) so nobody else can claim it for their own Pages site.
3. In the repository, Settings → Pages → Custom domain: enter the subdomain and
   save. GitHub commits a `CNAME` file to `gh-pages`; the Website workflow
   leaves that file alone.
4. Once the certificate is issued (minutes to an hour), tick **Enforce HTTPS**.
5. Set the `SITE_URL` repository variable to `https://mila.example.com/` and
   re-run the Website workflow so the canonical and social URLs match.

From then on GitHub answers `island-io.github.io/mila/...` with a 301 redirect
to `mila.example.com/...`, keeping the path. Sparkle follows redirects, so
installed apps keep finding `appcast.xml` at its new address.

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
| Failure modes | DNS mistakes | Host header, redirect loop if a Pages custom domain is also set, stale cache |

**Recommendation:** start with option A. It is one DNS record, GitHub handles
the certificate, and nothing new has to be monitored. Move to option B only
when there is a concrete need for something CloudFront provides, such as
security headers, WAF rules, access logs, or a policy that public company
domains are served from company AWS accounts. Because every link in the site is
relative and the absolute URLs come from `SITE_URL`, switching between A, B and
plain github.io needs no change to `site/`.
