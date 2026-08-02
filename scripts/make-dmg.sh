#!/bin/bash
# Build a distribution DMG from a Release-built Mila.app.
#
# Usage: scripts/make-dmg.sh path/to/Mila.app Mila-1.0.0.dmg 1.0.0
#
# Output: $DMG_PATH (relative or absolute), a LOCAL TEST artifact. Published
# releases are produced by the private signing pipeline, which notarizes and
# runs the release-notes gate (scripts/check-release-notes.sh) before building;
# this script deliberately skips that gate so local test DMGs don't require
# release notes. Signing identity: $CODESIGN_IDENTITY if set (CI / private pipeline),
# else the persistent "Mila Local Dev" self-signed cert if present in the
# login keychain (created by scripts/install-debug.sh — keeps TCC mic/screen
# grants across installs), else ad-hoc. Ad-hoc-signed apps get the Gatekeeper
# right-click → Open prompt on first launch and lose TCC grants on every
# reinstall; pass CODESIGN_IDENTITY=- to force ad-hoc (e.g. to test that
# Gatekeeper first-launch path). Re-sign with
# `codesign -s "Developer ID Application: ..."` before distributing externally.

set -euo pipefail

APP_PATH="${1:?usage: make-dmg.sh APP_PATH DMG_PATH VERSION}"
DMG_PATH="${2:?usage: make-dmg.sh APP_PATH DMG_PATH VERSION}"
VERSION="${3:?usage: make-dmg.sh APP_PATH DMG_PATH VERSION}"

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: $APP_PATH does not exist or is not a directory" >&2
    exit 1
fi

# Stage the DMG contents in a clean temp dir. Includes the .app and a symlink
# to /Applications so the standard "drag to install" UX works out of the box.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# Re-sign the bundle to make sure the embedded `whisper.framework` and the
# wrapping app stay in sync after the cp -R above. Identity resolution:
#   1. $CODESIGN_IDENTITY — CI / the private signing pipeline sets this (its
#      SHA1 fingerprint is the trust anchor for TCC permissions across
#      releases — every build signed with the SAME cert keeps the user's
#      previously-granted Accessibility / mic permissions).
#   2. The persistent "Mila Local Dev" self-signed cert (created by
#      scripts/install-debug.sh) if it exists in the login keychain, signed
#      by SHA-1 since self-signed certs never become "trusted identities" —
#      same stability property for local installs.
#   3. Ad-hoc ("-") as a last resort; macOS treats every ad-hoc rebuild as a
#      new app, so TCC re-prompts for mic/recording after each install.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENTITLEMENTS="$SCRIPT_DIR/../Mila/Resources/Mila.entitlements"

if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    LOCAL_DEV_SHAS=$(security find-certificate -c "Mila Local Dev" -a -Z \
        "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null \
        | awk '/SHA-1 hash/ {print $NF}' || true)
    if [[ $(grep -c . <<<"$LOCAL_DEV_SHAS") -gt 1 ]]; then
        echo "warning: multiple 'Mila Local Dev' certs in login keychain; using the first —" >&2
        echo "         if TCC still re-prompts, delete the stale duplicates and re-sign." >&2
    fi
    LOCAL_DEV_SHA=$(head -1 <<<"$LOCAL_DEV_SHAS")
    if [[ -n "$LOCAL_DEV_SHA" ]]; then
        echo "signing with Mila Local Dev cert ($LOCAL_DEV_SHA)" >&2
        CODESIGN_IDENTITY="$LOCAL_DEV_SHA"
    else
        echo "warning: no CODESIGN_IDENTITY and no 'Mila Local Dev' cert in login keychain;" >&2
        echo "         ad-hoc signing — TCC will re-prompt for mic/recording after install." >&2
        echo "         Run scripts/install-debug.sh once to create the persistent cert." >&2
        CODESIGN_IDENTITY="-"
    fi
fi

STAGED_APP="$STAGE/$(basename "$APP_PATH")"
# Deep-sign nested code first, then re-sign the outer bundle with the app
# entitlements (mic access, disable-library-validation, …) — a --deep sign
# with --entitlements would stamp the app's entitlements onto every nested
# framework, so entitlements go on the outer signature only.
codesign --force --deep --sign "$CODESIGN_IDENTITY" "$STAGED_APP"
codesign --force --sign "$CODESIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$STAGED_APP"

VOLNAME="Mila $VERSION"
TMP_DMG="$(mktemp -t MilaDMG.XXXXXX).dmg"

rm -f "$DMG_PATH" "$TMP_DMG"

# UDZO = compressed read-only DMG, the standard format for distribution.
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    "$TMP_DMG" >/dev/null

mv "$TMP_DMG" "$DMG_PATH"
echo "$DMG_PATH"
