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

`make-app.sh` also installs to `~/Applications`. A running copy keeps the image it
launched with, so it has to be restarted before any of it is visible.

**How to restart depends on how the app was started, and only one of the two is a
daemon.** If `patchthrough install` set up the LaunchAgent, use
`launchctl kickstart -k gui/$(id -u)/com.nicoherrera.patchthrough`. If the app was
opened from Finder or a login item there is no service under that label, that
command fails with "Could not find service", and the answer is to quit from the
menu bar and open it again. `launchctl list | grep patchthrough` tells you which
you have: a `application.com.nicoherrera.patchthrough.<pid>.<n>` row is the plain
app, not an agent.

Preferences live in the `com.nicoherrera.patchthrough` domain — the app is not
sandboxed, so `defaults read com.nicoherrera.patchthrough` shows real state.

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
- **Customer-facing copy has no em dashes.** Use a period, a comma, or a colon.
  This covers every string a user reads: notification titles and bodies, alert
  text, menu items, window labels, `lastAction` status lines, Settings captions,
  and the prose in `handoff.md`. Code comments and doc files are exempt.
- **Every user-facing string starts with a capital**, including the half after a
  colon in a notification title (`Patchthrough: Transcript ready`, not
  `Patchthrough: transcript ready`) and short status lines (`Transcribing…`,
  `Settings saved`, `Moved <name> to the Trash`). Strings that open with an
  interpolated value are fine as they are. The exception is text that came from
  somewhere else, like a Graph error echoed into a notification body: it is not
  ours to recase.
- Recording starts in the menu bar. The window titlebar carries a second
  record/stop control as a fallback, because macOS hides a `.variableLength`
  status item once the menu bar runs out of room and an `LSUIElement` app has no
  Dock icon to fall back on — menu bar only meant the primary action could become
  unreachable while the app was running. Both paths call the same `toggle()`.
  Don't delete the window control as a rule violation; it is the exception.
- **The window is no longer review-only.** It was, when the only thing it did was
  read finished transcripts. Notes changed that: they are typed *during* the
  meeting, so `startSession()` brings the window up (`notes.open_window_on_record`,
  default on) and selects the live session. Treat the window as a recording-time
  surface when adding anything that a user does while a meeting is running, and
  don't assume it is closed. Recording still *starts* in the menu bar; what
  happens during a recording increasingly does not live there.
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
- `SessionNotes.swift` — notes the user types during a meeting, in `notes.json`.
  Timestamps are absolute instants, never offsets; the transcript's zero moves
  during recording. Read [docs/notes-and-the-recording-clock.md](docs/notes-and-the-recording-clock.md)
  before touching anything that computes a note's position.
- `TranscriptClock.swift` — the one place a millisecond offset becomes `[m:ss]`.
  `transcript.md` and the handoff's notes section both print it and must agree,
  or a note points at a line near the one it means.
- `Handoff.swift` — stages a transcript into a repo and launches an agent.

## Conventions

- Never auto-commit; ask first.
- Session data lives in `~/Recordings/<yyyy.MM.dd-HHmm>/`. Treat it as user data:
  build fixtures in a scratch directory and pass `--out`, never write there.
- Signal handling in `Run.runMain()` deliberately keeps `withExtendedLifetime` —
  without it ARC releases the sources and SIGTERM becomes a silent no-op, so a
  recording in progress never gets finalized.
