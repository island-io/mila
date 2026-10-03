# Design sources

## `AppIcon.svg` — the app icon master

Vector master for `Mila/Assets.xcassets/AppIcon.appiconset`. **Edit this file,
not the PNGs**, then regenerate the set.

The mark is drawn in a 256-unit space and placed on Apple's macOS icon grid: an
**824×824 tile centred in a 1024 canvas**. That inset is not decoration — every
system app icon uses it, so it is what makes Mila render at the same visual
weight as its neighbours in the Dock. Drawing the tile full-bleed would make
Mila ~24% larger than every other app.

The white tile is a **circle**, and the microphone badge deliberately overhangs
it at the lower right — the badge is *not* clipped to the tile. Keep that, or
the badge loses the layered look and reads as a flat cut-out.

### Regenerating the PNGs

Needs `rsvg-convert` (`brew install librsvg`). Render each size straight from
the vector — don't downscale one big PNG, the small sizes come out softer:

```bash
cd "$(git rev-parse --show-toplevel)"
for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
            128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 \
            512:icon_256x256@2x 512:icon_512x512 1024:icon_512x512@2x; do
  px="${spec%%:*}"; name="${spec##*:}"
  rsvg-convert -w "$px" -h "$px" design/AppIcon.svg \
    -o "Mila/Assets.xcassets/AppIcon.appiconset/${name}.png"
done
```

`Contents.json` already lists all ten files, so nothing else needs touching.
