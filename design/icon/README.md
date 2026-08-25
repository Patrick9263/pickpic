# App icon concept

Working files for a PickPic app icon. **Nothing here is wired into the build yet** —
these are proposals for review, not assets the app consumes. The asset catalog at
`ipad/PickPic/Assets.xcassets` is untouched.

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

## If this moves forward

Wiring it up means adding an `AppIcon` image set to `ipad/PickPic/Assets.xcassets` with
the light/dark/tinted slots. That's inside the `PBXFileSystemSynchronizedRootGroup`
covering `ipad/PickPic/`, so it does **not** need the four-entry `project.pbxproj` dance
that new Swift sources under `PickPic.swiftpm/` require.
