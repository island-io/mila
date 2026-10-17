#!/usr/bin/env python3
"""Validate site/ before it is published into the gh-pages branch.

Usage: scripts/check-site.py SITE_DIR

Run by .github/workflows/pages.yml on pull requests and before every publish.
Fails (exit 1, one ::error:: line per problem) when:

- an entry is anything but a regular file or a directory (a symlink could
  make the publish step overwrite a file it does not own, such as the
  Sparkle feed);
- a path uses a name reserved for the gh-pages branch (appcast.xml, .nojekyll,
  CNAME, .site-files at the top level; .git anywhere) or one the publish step
  cannot handle safely (newlines, leading "-");
- an HTML or CSS file references a local file that does not exist, or uses a
  root-relative URL ("/x"), which breaks when the site is served under
  /mila/ on github.io. Checked: href, src and srcset attributes (either
  quote style) and CSS url(), in .css files and inline in HTML.
"""

import os
import re
import stat
import sys
from urllib.parse import unquote, urlsplit

RESERVED_TOP_LEVEL = {"appcast.xml", ".nojekyll", "CNAME", ".site-files"}

ATTR = re.compile(r"""\b(href|src|srcset)\s*=\s*(?:"([^"]*)"|'([^']*)')""", re.I)
CSS_URL = re.compile(r"""url\(\s*(?:"([^"]*)"|'([^']*)'|([^)'"\s]*))\s*\)""", re.I)


def walk(root):
    """Yield (relative path, lstat) for every entry, without following links."""
    for dirpath, dirnames, filenames in os.walk(root):
        for name in dirnames + filenames:
            full = os.path.join(dirpath, name)
            yield os.path.relpath(full, root), os.lstat(full)


def refs_in(path, text):
    """Local references in an HTML or CSS file."""
    out = []
    if path.endswith(".html"):
        for attr, dq, sq in ATTR.findall(text):
            value = dq if dq or not sq else sq
            if attr.lower() == "srcset":
                out += [c.strip().split()[0] for c in value.split(",") if c.strip()]
            else:
                out.append(value)
    for dq, sq, bare in CSS_URL.findall(text):
        out.append(dq or sq or bare)
    return out


def main(root):
    errors = []
    files = []
    for rel, st in walk(root):
        parts = rel.split(os.sep)
        if not (stat.S_ISREG(st.st_mode) or stat.S_ISDIR(st.st_mode)):
            errors.append(f"{rel}: not a regular file or directory (symlinks are not published)")
        if rel in RESERVED_TOP_LEVEL or ".git" in parts:
            errors.append(f"{rel}: name is reserved for the gh-pages branch")
        if any(p.startswith("-") for p in parts) or any(c in rel for c in "\n\r\t"):
            errors.append(f"{rel}: unsupported file name")
        if stat.S_ISREG(st.st_mode):
            files.append(rel)

    for rel in files:
        if not rel.endswith((".html", ".css")):
            continue
        with open(os.path.join(root, rel), encoding="utf-8") as fh:
            text = fh.read()
        base = os.path.dirname(rel)
        for ref in refs_in(rel, text):
            ref = ref.strip()
            if not ref or ref.startswith(("#", "data:", "mailto:")):
                continue
            parts = urlsplit(ref)
            if parts.scheme or ref.startswith("//"):
                continue  # absolute URL
            if ref.startswith("/"):
                errors.append(f"{rel}: root-relative URL {ref!r} breaks under /mila/")
                continue
            target = os.path.normpath(os.path.join(base, unquote(parts.path)))
            if target.startswith(".."):
                errors.append(f"{rel}: {ref!r} points outside the site")
            elif parts.path in ("", "./") or parts.path.endswith("/"):
                if not os.path.isfile(os.path.join(root, target, "index.html")):
                    errors.append(f"{rel}: {ref!r} has no index.html")
            elif not os.path.isfile(os.path.join(root, target)):
                errors.append(f"{rel}: missing file {ref!r}")

    for msg in errors:
        print(f"::error::{msg}")
    if not errors:
        print(f"site OK: {len(files)} files")
    return 1 if errors else 0


if __name__ == "__main__":
    if len(sys.argv) != 2 or not os.path.isdir(sys.argv[1]):
        sys.exit("usage: check-site.py SITE_DIR")
    sys.exit(main(sys.argv[1]))
