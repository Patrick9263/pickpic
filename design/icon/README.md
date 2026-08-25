# App icon

Source files for the PickPic app icon. **The `.svg` files here are the editable
source**; the icon the app actually ships is the flattened PNGs in
`ipad/PickPic/Assets.xcassets/AppIcon.appiconset/`.

To change the icon, edit the SVG here, re-render, strip the alpha channel, and copy
the result into the appiconset — see "Regenerating" below.

## Preview

| File                 | What it shows                                                        |
| -------------------- | -------------------------------------------------------------------- |
| `variants-sheet.png` | Light / Dark / Tinted side by side, with the iOS corner mask applied |
| `size-test.png`      | The light icon at real system sizes, 180pt down to 29pt              |
| `icon-light.png`     | Light variant, 1024×1024                                             |
| `icon-dark.png`      | Dark variant, 1024×1024                                              |
| `icon-tinted.png`    | Tinted grayscale source, 1024×1024                                   |

The `.svg` next to each `.png` is the source; the PNGs are rendered from them with
`qlmanage -t -s 1024`.

## Design notes

**Full-bleed, no baked-in corners.** iOS applies its own mask. The `variants-sheet`
preview fakes that mask so the icons read correctly, but the shipping `icon-*.svg`
files are square to the edge.

**No hand.** The reference concept had a hand pinching a photo. Hands are the hardest
element to render convincingly, they draw the most scrutiny, and they're the first
thing to dissolve when scaled down — at 40pt it becomes a beige blob. Dropping it lets
the heart carry the meaning, which suits PickPic: a heart here is an edit request, not
a social reaction.

**The heart has a ring.** A stroke in the card color, drawn under the fill. This is what
keeps the heart legible where it overlaps the card, and it's load-bearing in tinted
mode — see below.

## Per-variant adjustments

These aren't cosmetic; each fixes something that looks wrong without it.

**Dark** — the photo window inverts (dark sky, lighter mountains). Keeping the light-mode
fill made the card look like a lit rectangle floating on black. The heart's ring changes
from white to the card gray `#D9DCE6`, because a white ring on a dark background reads as
a glow artifact.

**Tinted** — iOS maps luminance onto a user-chosen tint, so every hue collapses to one and
the red heart is gone. The heart stays readable only because it's the brightest value in
the icon (`#FFFFFF`) against a mid-gray card (`#B4B4B4`), with a dark ring holding it off
the card. Shapes must be separated by brightness alone here.

The fourth panel in `variants-sheet.png` is a hand-mapped approximation of how iOS would
composite the grayscale source with a blue tint. The luminance _relationships_ in that
panel are accurate; the exact hues depend on the tint the user picks.

## Regenerating

The appiconset already has its three appearance slots wired up in `Contents.json`, so
replacing the icon is just overwriting the three PNGs in place — no `Contents.json` or
`project.pbxproj` change. The asset catalog lives inside the
`PBXFileSystemSynchronizedRootGroup` covering `ipad/PickPic/`, so it does **not** need
the four-entry `project.pbxproj` dance that new Swift sources under `PickPic.swiftpm/`
require. Xcode does not need to be quit for this.

```bash
cd design/icon
for f in icon-light icon-dark icon-tinted; do
  qlmanage -t -s 1024 -o /tmp/out "$f.svg" && mv "/tmp/out/$f.svg.png" "$f.png"
done
cp icon-light.png icon-dark.png icon-tinted.png \
  ../../ipad/PickPic/Assets.xcassets/AppIcon.appiconset/
```

**Then strip the alpha channel.** App icons must be fully opaque, and every PNG encoder
reachable here — `qlmanage`, and `sips` even via a BMP round-trip — writes an alpha
channel back in. The working approach is a CoreGraphics context created with
`CGImageAlphaInfo.noneSkipLast`, driven by a throwaway Swift script (`swift Flatten.swift
*.png`). Verify with `sips -g hasAlpha <file>`, which must report `no`.

Confirm the result actually compiled in, rather than trusting a green build:

```bash
xcrun assetutil --info /path/to/PickPic.app/Assets.car | grep -iE '"Appearance"|AppIcon'
```

That should list `UIAppearanceDark` and `ISAppearanceTintable` alongside the default.
