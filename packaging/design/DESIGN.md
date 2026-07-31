# Patchthrough — logo handoff

macOS menu bar app. Mark is **7b "Through"** as corrected in round 8.
Source of truth: `Patchthrough Logo.dc.html` (round 8, top section).

## The mark

A socket ring with a patch cord passing through it, off-centre. Drawn on a
**24 × 24 grid**, stroke-based, round caps, single colour, no fill, no gradient.

```
transform: translate(0, -0.45)
circle    cx=12 cy=12 r=6.3
path      M2.8 19.2 C 5.2 14.8 7.8 10.9 10.3 9.6 C 12.8 8.3 16.8 7.2 21.2 6.4
```

Two weights, both shipped:

| Weight | Stroke | Use |
| --- | --- | --- |
| Regular | 1.6 | menu bar, 16–22pt, inline UI |
| Heavy | 2.1 | dock icon, wordmark lockup, "patching" state |

Files: `patchthrough-mark.svg`, `patchthrough-mark-heavy.svg`, `patchthrough-icon-1024.svg`

### Non-negotiables

1. **The cord must never cross the centre of the ring.** A straight line through
   a circle is the universal "disabled / muted" sign. The cord's closest approach
   to the centre is 2.9 units, on the upper-left side.
2. **The counter must stay open at 16pt** — roughly 1.2px of clear space on each
   side of the cord where it passes inside the ring. Do not thicken the strokes
   for small sizes; use the Regular weight and let macOS antialias.
3. Ring and cord are the **same stroke weight**. Different weights make the cord
   read as a handle and the whole thing as a magnifying glass.
4. No vertical, axially-symmetrical objects in this identity. The upright plug was
   cut for this reason.

## Colour

| Token | Hex | Use |
| --- | --- | --- |
| Ink | `#16150F` | mark on light, dock icon ground |
| Paper | `#F2F0EA` | mark on ink |
| Signal | `#D2371B` | recording dot only |
| Icon paper variant | `#F2EFE7` ground, `#E2DED4` hairline | light-mode marketing |

Colour appears in exactly one place in the product: the recording dot.

## Dock icon

- Squircle, corner radius **22.4%** of the tile (1024 → 229.4).
- Art at **64%** of the tile, optically centred (1024 → 656px, inset 184).
- Heavy weight, `#F2F0EA` on `#16150F`.
- Flat fill. No bevel, no inner shadow, no gradient.
- Export 1024, 512, 256, 128, 64, 32, 16 into `AppIcon.appiconset`.

Approved: **Signal** — `#FFF9F4` mark on `#D2371B` — is the shipping dock icon.
**Paper** — ink mark on `#F2EFE7` with an `#E2DED4` hairline — is its light-context
counterpart. **Ink** is a fallback and is not for release.

## Menu bar

- Ship as a **template image** so macOS handles light/dark and Reduce Transparency:
  `NSImage.isTemplate = true`, art in black with alpha.
- Export at **18 × 18 @1x, @2x, @3x** (also supply 16 and 22 if the app offers a
  size preference).
- States:
  - **Idle** — Regular weight.
  - **Recording** — Regular weight + a 7px Signal dot at the lower right, pulsing
    1.6s ease-in-out. The dot is the only non-template layer.
  - **Patching** — Heavy weight, same geometry. No spinner.

## Wordmark

- Instrument Sans **600**, tracking **−0.035em** at display sizes, **−0.03em** in
  the lockup.
- Horizontal lockup: mark at 34px beside 32px text, gap 13px. Mark height ≈ 1.06×
  the cap height.
- Reversed lockup: `#F2F0EA` on `#16150F`.
- Optional: the second "o" of "through" replaced by the socket ring (ring stroke
  4.4 on the 24 grid so it matches the 600-weight stem). Approve before use — it
  costs legibility at small sizes.

## Open items

- **Export the assets** — template PNGs at 16/32/48 plus the 1024 appiconset.
- **Name clearance.** "Patchthrough" has not been searched. Note that "Baton", the
  earlier name, was crowded: an existing macOS presentation-handoff app plus live
  registered software marks. Run a proper search before you commit spend.
- Rounds 1–7 are kept in the file as history. **7a is dead** (reads as a magnifying
  glass) and the round 5–6 plug variants are dead (upright silhouette). Do not
  revive them.
