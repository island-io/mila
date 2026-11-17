// Point the "Download for Mac" buttons straight at the latest stable DMG.
//
// Release assets carry the version in their name (Mila-1.9.6.dmg), so there is
// no fixed /releases/latest/download/<name> URL to link to. Without this
// script, or if GitHub's API is unreachable or rate-limited, the buttons keep
// their HTML href: the latest release page, one click from the DMG.
//
// /releases/latest never returns drafts or pre-releases, so beta builds are
// never offered here.
//
// The repository comes from <meta name="mila-repo"> in index.html, which the
// publish workflow rewrites for a fork, so a fork's site offers the fork's
// own releases.
(function () {
  "use strict";

  var meta = document.querySelector('meta[name="mila-repo"]');
  var repo = meta ? meta.getAttribute("content") || "" : "";
  if (!/^[A-Za-z0-9-]+\/[A-Za-z0-9._-]+$/.test(repo)) return;

  var API = "https://api.github.com/repos/" + repo + "/releases/latest";
  var ASSET_PREFIX = "https://github.com/" + repo + "/releases/download/";

  function apply(release) {
    var assets = (release && release.assets) || [];
    var dmg = null;
    for (var i = 0; i < assets.length; i++) {
      var url = assets[i] && assets[i].browser_download_url;
      if (typeof url === "string" && url.indexOf(ASSET_PREFIX) === 0 && /\.dmg$/i.test(url)) {
        dmg = url;
        break;
      }
    }
    if (!dmg) return;

    var links = document.querySelectorAll("#download, [data-download-link]");
    for (var j = 0; j < links.length; j++) links[j].href = dmg;

    var tag = typeof release.tag_name === "string" ? release.tag_name.replace(/^v/, "") : "";
    var label = document.getElementById("download-version");
    if (label && /^[0-9][0-9A-Za-z.\-]*$/.test(tag)) label.textContent = "Version " + tag;
  }

  function run() {
    if (!window.fetch) return;
    var controller = window.AbortController ? new AbortController() : null;
    var timer = controller ? setTimeout(function () { controller.abort(); }, 5000) : null;

    fetch(API, {
      headers: { Accept: "application/vnd.github+json" },
      credentials: "omit",
      signal: controller ? controller.signal : undefined
    })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(apply)
      .catch(function () { /* keep the fallback link */ })
      .then(function () { if (timer) clearTimeout(timer); });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", run);
  } else {
    run();
  }
})();
