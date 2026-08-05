# CLAUDE.md — patchthrough

Record a meeting, transcribe it on-device, hand the transcript to a coding agent.
Swift 6 / SwiftUI + AppKit, macOS 15+, built with SwiftPM. Ships as a menu-bar
accessory app (`LSUIElement`) plus a CLI.

## Build and run

```bash
swift build                                    # debug
.build/debug/patchthrough run --window         # daemon + open the window
./packaging/make-app.sh                        # release, sign, install to ~/Applications
```

`make-app.sh` also installs, so after it run
`launchctl kickstart -k gui/$(id -u)/com.nicoherrera.patchthrough` to restart the
daemon. Preferences live in the `com.nicoherrera.patchthrough` domain — the app is
not sandboxed, so `defaults read com.nicoherrera.patchthrough` shows real state.

Debug hooks (env vars, all off by default): `PATCHTHROUGH_DEBUG_WINDOW` logs the
window frame, `PATCHTHROUGH_DEBUG_SETTINGS` opens the settings sheet at launch,
`PATCHTHROUGH_DEBUG_MENU` opens the status-item menu from code (a screenshot
harness cannot click it without Accessibility permission).

## Design

**UI work in this repo follows [design/DESIGN_RULES.md](design/DESIGN_RULES.md).
Read it before adding or changing any view.** The short version:

- All colours, fonts and spacing come from `Sources/patchthrough/UI/Theme.swift`
  (`PT.C`, `PT.F`, `PT.M`). Never write a raw hex, font size, or padding number in
  a view. Never use `.secondary`, `.tertiary`, or `Color.gray` — they are cold
  system greys and clash with these warm neutrals.
- Red (`PT.C.signal`) means recording or destruction — nothing else. No second
  accent colour, ever. Red *text or icons* on dark use `PT.C.signalLit`; the fill
  colour fails contrast as text.
- Dark mode only. No light variants, no `colorScheme` branches.
- Selection is a filled row with a ring. Never a coloured left edge bar.
- The verb is "Patch through to". Sentence case, no emoji.
- Recording starts in the menu bar, not the window.
- `PT.M.turnMaxWidthFraction = 0.78` is load-bearing — raising it silently breaks
  the me-right / them-left transcript layout.
- Type sizes are fractional on purpose (14.5, 13.5, 12.5, 11.5, 10.5). Rounding
  them is the most common way this design drifts.

Design source of truth: `design/Patchthrough App Redesign.dc.html`, sections
**11a** (window), **10d** (settings), **10e** (menu bar). Rounds 10a–10c are
rejected explorations — don't build from them. `design/reference-swift/` holds the
designer's sample implementations, and `design/SPEC.md` the exact-value table.

Where the sample files and the mock disagree, **the mock wins** — it is the stated
source of truth. One such case is recorded in `Theme.swift`
(`transcriptLineSpacing`).

There is one deliberate deviation *from* the mock: the Settings control uses SF
`gearshape`, not 11a's `#i-gear`. That symbol is a ring with eight radial spokes,
which reads as a sun — a light/dark toggle — and this app is dark-only, so the
affordance has to be unmistakably a gear. It is commented at the call site; don't
revert it.

If a rule blocks what a feature needs, say so and ask. Don't work around it.

### Verifying a UI change

Screenshots are the only reliable check; SwiftUI drifts silently. `screencapture`
writes in the *display's* colour space, so convert before comparing pixel values
or every saturated colour reads as a near-miss:

```bash
screencapture -x -o -l<windowID> shot.png
sips --matchTo "/System/Library/ColorSync/Profiles/sRGB Profile.icc" shot.png --out shot.png
```

Get `<windowID>` from `CGWindowListCopyWindowInfo`. Per-window capture works even
when the screen is locked. Set the window to the mock's own size
(`defaults write com.nicoherrera.patchthrough window.frame -string "{{200, 300}, {952, 721}}"`)
so a capture diffs against `design/screenshots/01-window-11a.png` 1:1 — and put it
back afterwards.

Two traps worth knowing: an offscreen `cacheDisplay` render shows vibrant surfaces
as flat white, so it is useless for verifying this palette; and controls in an
inactive window render in a desaturated state (an ON switch looks grey), which is
not a bug.

## Architecture

- `Patchthrough.swift` — ArgumentParser CLI (`run`, `hand`, `transcripts`,
  `doctor`, `install`) and `AppController`, which owns the menu bar, the recording
  session, and the elapsed ticker. Everything is `@MainActor`.
- `UI/PatchthroughWindow.swift` — `SessionStore` (all window state) and the views.
  The window draws its **own** titlebar strip over a transparent system one:
  `NSToolbar` re-styles whatever it hosts, so a native toolbar cannot produce
  11a's two-tone red split button or unbordered chips. It is also not a
  `NavigationSplitView` — that insisted on a collapse control and would not honour
  a pinned 252pt column — nor a `List` for the sidebar, which adds ~16pt of
  horizontal inset on top of `listRowInsets`.
- `UI/MenuBarController.swift` — status item and menu. AppKit, so it uses the
  `PT.NS` token bridge. Use `NSColor(srgbRed:)`, never `calibratedRed:`: generic
  RGB renders `#D2371B` as `#DD4D22`.
- `Audio/` — mic + system-audio capture to two `.caf` tracks.
- `Transcription/` — on-device Parakeet via CoreML.
- `Handoff.swift` — stages a transcript into a repo and launches an agent.

## Conventions

- Never auto-commit; ask first.
- Session data lives in `~/Recordings/<yyyy.MM.dd-HHmm>/`. Treat it as user data:
  build fixtures in a scratch directory and pass `--out`, never write there.
- Signal handling in `Run.runMain()` deliberately keeps `withExtendedLifetime` —
  without it ARC releases the sources and SIGTERM becomes a silent no-op, so a
  recording in progress never gets finalized.
