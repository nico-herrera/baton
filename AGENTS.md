# AGENTS.md — patchthrough

## Project overview

Patchthrough records meetings (microphone and system audio as two separate
tracks), transcribes them **entirely on-device**, and hands the verbatim
transcript to a coding agent (Claude Code, Copilot, Codex, Kimi, opencode,
cursor-agent, plus GUI apps and chat websites). Nothing leaves the machine
except model downloads and whatever the user explicitly hands to an agent.

The repo ships **three products** that communicate only through a versioned
on-disk session format (`schemas/session-v1.md`):

1. **Native macOS app** — Swift 6, SwiftUI + AppKit, built with SwiftPM.
   Targets macOS 15+ (Core Audio process taps) and Apple Silicon (Neural
   Engine transcription). Parakeet is the safe default; Apple Speech and
   WhisperKit are evidence-gated or explicit benchmark paths. Runs as a
   menu-bar accessory app (`LSUIElement`) plus an embedded ArgumentParser CLI
   (`run`, `hand`, `transcripts`, `doctor`, `benchmark`, `benchmark-corpus`,
   `install`).
2. **Windows console recorder** (`windows/`) — C# on .NET 8. It captures
   microphone and WASAPI loopback audio, writes the same session contract,
   and supports on-device Parakeet and Whisper adapters. The portable ZIP and
   per-user Inno Setup installer are implemented, but remain unsigned previews
   until Authenticode and physical-hardware acceptance are complete. A tray UI
   is a later milestone.
3. **npm CLI** (`cli/`) — plain Node.js ≥18, zero dependencies, no install
   scripts, cross-platform. It reads the sessions the app writes, stages a
   transcript into a repo's `.meeting/` directory, and launches agents. It
   never records, transcribes, downloads a binary, or installs the app.

## Repository layout

- `Package.swift`, `Package.resolved` — SwiftPM manifest and lockfile for the
  app. Three dependencies, all pinned with `.exact()`:
  swift-argument-parser 1.8.2, FluidAudio 0.15.5, and WhisperKit through
  argmax-oss-swift 1.0.0.
- `Sources/patchthrough/` — the entire app (one executable target):
  - `Patchthrough.swift` — `@main` ArgumentParser CLI and `AppController`
    (owns menu bar, recording session, elapsed ticker). `AppController` and
    its UI-facing entry points are `@MainActor`.
  - `Audio/` — `MicRecorder` and `SystemAudioRecorder`, writing two `.caf`
    tracks.
  - `Transcription/` — the shared engine contract, Parakeet, Apple Speech,
    WhisperKit, evidence-gated quality selection/consensus, and
    `TranscriptionCoordinator` (including mic-echo dedup).
  - `UI/` — `PatchthroughWindow.swift` (`SessionStore` + all views; the
    window draws its own titlebar over a transparent system one — do not
    reintroduce `NSToolbar`, `NavigationSplitView`, or a sidebar `List`),
    `MenuBarController.swift` (AppKit status item), `Theme.swift` (design
    tokens), `HandoffAlert.swift`, `AppIcon.swift`.
  - `Handoff.swift` — agent/destination registry and handoff logic. **To add
    an agent or GUI target, add one entry here.**
  - `Config.swift` — reads `~/.config/patchthrough/config.json`.
  - `RecordingSession.swift` — one meeting = a timestamped directory with two
    tracks + `meta.json`.
  - `Doctor.swift`, `Install.swift`, `Notify.swift`, `Terminals.swift` —
    diagnostics, LaunchAgent install, notifications, terminal launching.
  - `Info.plist` — embedded into the binary via linker flags so TCC can
    attribute permissions when running as a LaunchAgent.
- `cli/` — the npm package: `bin/patchthrough.js` (executable arg parser),
  `src/patchthrough.js` (library: sessions, staging, agents, web targets),
  `test/patchthrough.test.js` (node:test), `verify.js` (package invariants).
- `windows/` — `Patchthrough.Core` (portable session/transcription logic),
  `Patchthrough.Windows` (WASAPI, AAC, model adapters, console entry point),
  xUnit tests, the cross-platform session fixture, and Windows release tooling.
  `windows/Directory.Build.props` enables NuGet lock files and locked restore
  for every project. `windows/packaging/` builds the self-contained x64 ZIP and
  per-user installer.
- `Tests/patchthroughTests/` — Swift contract, segmentation, quality-gate,
  consensus, and corpus-run tests.
- `models/registry.json` — cross-platform model metadata, size budgets, hashes,
  and system-asset declarations. `tools/verify-contracts.mjs` validates it with
  the shared transcript and quality fixtures.
- `quality/` — corrected-corpus schemas, fixtures, release-gate scoring, corpus
  bootstrap, and the private browser review-packet generator. Do not commit
  private corpus audio or generated review packets.
- `docs/` — transcription architecture/engine selection and the Windows
  physical-hardware acceptance checklist.
- `schemas/session-v1.md` — the app↔CLI contract. A session is a directory
  `<recordings root>/<yyyy.MM.dd-HHmm>/` with `meta.json`, `mic.caf`,
  `system.caf`, `transcript.json`, `transcript.md`, `handoff.md`. Presence of
  `transcript.json` marks a completed transcription; older sessions may lack
  `handoff.md` (fall back to wrapping `transcript.md`).
- `packaging/` — build/release scripts and supply-chain baselines:
  `make-app.sh`, `make-dist.sh`, `notarize.sh`, `verify-deps.sh`,
  `verify-models.sh`, `DEPS.lock`, `MODELS.lock`,
  `patchthrough.entitlements`, and `design/` (logo assets, app icon sets,
  `DESIGN.md` brand handoff).
- `dist/` — release artifacts (gitignored).

## Build and run

```bash
swift build                                    # debug build of the app
.build/debug/patchthrough run --window         # daemon + open the window
./packaging/make-app.sh                        # release build, sign, install to ~/Applications
```

`make-app.sh` also installs, so restart the daemon afterwards:
`launchctl kickstart -k gui/$(id -u)/com.nicoherrera.patchthrough`.
Preferences live in the `com.nicoherrera.patchthrough` defaults domain (the
app is not sandboxed). Debug env vars (all off by default):
`PATCHTHROUGH_DEBUG_WINDOW`, `PATCHTHROUGH_DEBUG_SETTINGS`,
`PATCHTHROUGH_DEBUG_MENU`.

The Parakeet models (~600 MB) download from HuggingFace on first
transcription into `~/Library/Application Support/FluidAudio/Models`.

The Windows solution builds from any platform, but capture and installer
acceptance require Windows:

```bash
dotnet restore windows/Patchthrough.sln --locked-mode
dotnet build windows/Patchthrough.sln -c Release --no-restore -warnaserror
dotnet test windows/Patchthrough.sln -c Release --no-build
./windows/verify-contract.sh
```

On Windows, `windows\packaging\build-release.ps1 -Version <version>` builds
the portable ZIP and Inno Setup installer. Follow it with
`windows\packaging\verify-release.ps1 -ExpectedVersion <version>`.

## Testing instructions

Run the shared and native pipeline tests for contract, transcription, model,
or quality changes:

```bash
node tools/verify-contracts.mjs
node quality/score.mjs --manifest quality/fixtures/corpus.json \
  --candidate quality/fixtures/candidate.json \
  --baseline quality/fixtures/baseline.json --out /tmp/patchthrough-score.json
node --test quality/prepare-review.test.mjs
swift test
dotnet test windows/Patchthrough.sln -c Release
./windows/verify-contract.sh
```

The Swift test target covers shared transcript decoding, segmentation,
consensus/quality evidence gates, and the corpus run shape. The Windows xUnit
suite covers the same portable contract plus gap arithmetic and formatting.
`verify-contract.sh` creates a session through real C# code and reads/stages it
through the npm CLI.

Some app verification remains manual:

- `patchthrough doctor` checks recordings dir, permissions, agents.
- UI changes are verified by screenshot, because SwiftUI drifts silently.
  Capture per-window with `screencapture -x -o -l<windowID>`, then convert
  colour space (`sips --matchTo .../sRGB Profile.icc ... --out ...`) before
  comparing pixel values. Offscreen `cacheDisplay` renders are useless for
  the palette, and inactive windows desaturate controls (not a bug).

The CLI has real tests — run them for any `cli/` change:

```bash
cd cli
npm test          # node --test
npm run check     # verify.js (package invariants) + tests; also runs on prepack
```

Tests build session fixtures in temp dirs; follow that pattern. Do not encode a
test-count claim in this file; it becomes stale whenever coverage grows.

**If you change `schemas/session-v1.md`, add compatibility coverage to the
CLI tests**, including a fallback for sessions older app versions wrote.

## Code style and conventions

- Language of code, comments and docs is English. Prose is plain, sentence
  case; the product verb is "Patch through to".
- Comments in this repo explain *why*, often at length — keep that habit,
  especially for non-obvious platform behaviour (TCC, hardened runtime,
  SwiftUI/AppKit quirks).
- Swift: everything UI-facing is `@MainActor`. Signal handling in
  `Run.runMain()` deliberately keeps `withExtendedLifetime` — without it ARC
  releases the signal sources and SIGTERM becomes a silent no-op, so a
  recording never gets finalized. Do not "clean that up".
- UI design tokens: all colours, fonts and spacing come from
  `Sources/patchthrough/UI/Theme.swift` (`PT.C`, `PT.F`, `PT.M`). Never write
  a raw hex, font size, or padding number in a view. Never use `.secondary`,
  `.tertiary`, or `Color.gray`. Dark mode only — no light variants. Red
  (`PT.C.signal`) means recording or destruction only; red text/icons use
  `PT.C.signalLit`. Fractional type sizes (14.5, 13.5, 12.5, …) are
  deliberate — do not round them. `PT.M.turnMaxWidthFraction = 0.78` is
  load-bearing for the me-right/them-left transcript layout. In AppKit use
  `NSColor(srgbRed:)`, never `calibratedRed:`.
- CLI: plain CommonJS Node, no dependencies, no install scripts, must stay
  cross-platform (`cli/verify.js` enforces this and more).
- Windows: keep hardware-independent behavior in `Patchthrough.Core`; only
  capture, codecs, devices, and concrete engine adapters belong in
  `Patchthrough.Windows`. A cross-platform compile proves API shape, not that
  WASAPI, Media Foundation, model loading, or inference works on hardware.
- Session data in `~/Recordings/` is **user data**. Never write there from
  tests or fixtures; build fixtures in a scratch directory and pass `--out`.
- Handoff staging writes `.meeting/` into the target repo and adds it to the
  repo's **local** git excludes (`./.git/info/exclude`) — never touch the
  user's `.gitignore`.
- Never auto-commit; ask first.

## Security considerations

The transcript of a meeting is about as sensitive as data gets; the
supply-chain posture is deliberate and must be preserved:

- **Exact dependency pins.** Swift packages use `.exact()` and commit
  `Package.resolved`. Windows direct NuGet references use exact bracket ranges,
  every project commits `packages.lock.json`, and normal restores run with
  `RestoreLockedMode=true`. Any dependency change must show up as a reviewable
  direct and transitive diff.
- **`./packaging/verify-deps.sh`** fails the build when resolved deps drift
  from `packaging/DEPS.lock`, when a checkout in `.build/checkouts` doesn't
  match the lockfile, or when a dependency checkout has local modifications.
  `--update` re-baselines — only after actually reviewing the new code.
- **`./packaging/verify-models.sh`** does the same for the downloaded Core ML
  models against `packaging/MODELS.lock` (change detection; the first
  download cannot be authenticated).
- **No npm install scripts, no native downloads** in the CLI package
  (enforced by `cli/verify.js`: no `postinstall`, no `os`/`cpu` fields).
- **Windows distribution is verified but not yet trusted.** CI downloads the
  pinned Inno Setup release through GitHub and verifies its release asset
  attestation before compiling the installer. Public artifacts must sign and
  verify both `Patchthrough.exe` and the installer with Authenticode, use a
  trusted timestamp, and pass `docs/windows-hardware-acceptance.md`.
- The app needs `com.apple.security.device.audio-input` + hardened runtime
  together: without the entitlement the hardened runtime *silently* denies
  microphone access and recordings come back empty. Re-test a real recording
  after touching signing flags or entitlements.
- Custom handoff destinations validate `id` and require `http(s)` URLs,
  because the URL reaches `/usr/bin/open`, which would hand other schemes to
  whatever claims them.

## Releases

The app and the CLI release independently from this repo:

- App: `./packaging/make-dist.sh <version>` (requires a clean tree, full
  Xcode, and the Developer ID identity) builds and signs
  `dist/Patchthrough-arm64.dmg` + `.sha256`; `./packaging/notarize.sh
  dist/Patchthrough-arm64.dmg` then notarizes and staples it (not optional —
  macOS 15+ blocks un-notarized downloads). App tags look like `v1.0.2`.
- Windows: `windows\packaging\build-release.ps1 -Version <version>` builds
  `Patchthrough-windows-x64.zip`, the per-user setup executable, and SHA-256
  files. CI artifacts are unsigned previews. A public build also requires a
  certificate thumbprint, successful Authenticode verification, and completed
  physical-hardware acceptance. Do not describe Windows as generally available
  or add a public download until those gates pass.
- CLI: `cd cli && npm publish`. CLI tags look like `cli-v2.0.0`. The CLI's
  major version starts at 2 (the 1.x npm package was an app installer).

## Gotchas

- A silent recording almost always means Screen & System Audio Recording
  permission is off for patchthrough in System Settings.
- The default Parakeet model transcribes English only; expect errors on proper
  nouns and identifiers (the handoff prompt warns the agent about this).
- A global system-audio tap records everything the Mac plays, including
  notification sounds.
- Windows capture, AAC encoding, model loading, and inference compile and have
  model-free coverage, but still require evidence on a physical Windows machine.
  Never turn passing cross-platform tests into a hardware-support claim.
- `CLAUDE.md` exists in this working copy and carries extra maintainer notes,
  but it is gitignored (local only). It references a root `design/` directory
  with UI mock files that is not present in this checkout; the design assets
  that do ship live under `packaging/design/`. `Theme.swift` and the rules
  above are the enforceable source of truth here.
