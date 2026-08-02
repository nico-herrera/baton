# Patchthrough

Record the meeting. We'll patch you through to your agent.

Patchthrough is a macOS menu-bar app that records your meetings (your mic and the
other side of the call as two separate tracks), transcribes them **entirely
on-device**, and then hands the transcript to whatever coding agent you use —
Claude Code, Copilot, Codex, Kimi, opencode, cursor-agent — as a primed
session in the repo you were meeting about.

Nothing leaves your machine. There's no account, no server, no upload. The
handoff is the product: the gap between *"we agreed on it in the meeting"* and
*"an agent is implementing it with the transcript in context"* is one click.

```
┌─ meeting ─────────┐   ┌─ on-device ─────────┐   ┌─ your agent ──────────────┐
│ your mic     ──►  │   │ two-track           │   │ claude / copilot / codex  │
│ system audio ──►  │   │ transcription,      │──►│ kimi / opencode / cursor  │
│ (the other side)  │   │ me/them diarization │   │ primed with the transcript │
└───────────────────┘   └─────────────────────┘   └───────────────────────────┘
```

## How it works

1. **Click the Patchthrough in the menu bar → Start recording.** Your mic and
   everything the Mac plays are captured as two separate CAF tracks. Two
   tracks on purpose: speech models do better on clean single-source audio,
   and mic-vs-system gives you two-party diarization — `me` vs `them` — with
   no speaker-identification model at all.
2. **Click Stop.** Transcription starts automatically (Parakeet TDT 0.6B via
   [FluidAudio](https://github.com/FluidInference/FluidAudio), Core ML,
   roughly 20 seconds per hour of audio on Apple Silicon).
3. **Menu bar → "Hand off to → claude"** (or any agent it detects on your
   machine). Pick the project folder; a terminal opens there with the agent
   running and the transcript staged. Or from a terminal, in the repo:

   ```sh
   patchthrough hand claude
   ```

The agent gets the verbatim transcript — deliberately not a summary, because a
lossy summary is exactly where requirements get quietly dropped — plus a prompt
that tells it to extract work items, decisions, and ambiguities, ask before
guessing at garbled terms, and not touch any code until you've agreed the plan.

The transcript lands in `.meeting/` inside your repo, which Patchthrough adds to the
repo's **local** git excludes — meeting content can't end up in a commit by
accident, and your `.gitignore` isn't touched.

## Install the macOS app

[Download Patchthrough-arm64.dmg](https://github.com/nico-herrera/patchthrough/releases/latest/download/Patchthrough-arm64.dmg),
open it, and drag Patchthrough into Applications. Launch at login is available
in Patchthrough Settings.

Releases are signed with Developer ID, notarized by Apple, and published with a
SHA-256 checksum, so they open on a normal double-click. This open-source
project is distributed directly through GitHub rather than the Mac App Store;
Developer ID is Apple's supported path for exactly that.

If you build an unsigned copy yourself, note that macOS 15 removed the old
right-click → **Open** bypass. Open **System Settings → Privacy & Security**,
find the blocked-app notice, and choose **Open Anyway**.

To build from source instead:

```sh
git clone https://github.com/nico-herrera/patchthrough
cd patchthrough
./packaging/make-app.sh                  # builds and installs to ~/Applications
```

No `sudo` is needed for `~/Applications`. The app bundle gives macOS a stable
name, icon, signature, and permission identity.

**Requires:** macOS 15+ (system-audio capture uses Core Audio process taps),
Apple Silicon (transcription runs on the Neural Engine). Models (~600 MB)
download once on first transcription — record a short test while online before
your first real meeting.

## Command-line client

The npm package is a separate, cross-platform transcript client. It does not
download or install the macOS app and has no install scripts:

```sh
npm i -g patchthrough
```

```sh
patchthrough hand [agent]           # hand the newest transcript to an agent, here
patchthrough hand claude -s <session> -d <repo> -n
patchthrough transcripts            # list sessions: length, status, first line
patchthrough hand codex --file meeting.md
```

The CLI reads sessions written by the app, but it also accepts any transcript
file or stdin and can be used without the app. See [`cli/`](cli/) for its full
documentation. Upgrading from npm package 1.x leaves the already-installed app
and recordings in place; it only replaces the old wrapper command with the new
CLI.

Sessions land in `~/Recordings/<yyyy.MM.dd-HHmm>/`: the two audio tracks,
`meta.json`, `transcript.json` (timed, speaker-tagged segments), and
`transcript.md`.

Optional config at `~/.config/patchthrough/config.json`:

```json
{
  "recordings_dir": "~/Recordings",
  "transcription": { "enabled": true, "engine": "parakeet" },
  "mic_voice_processing": false,
  "on_stop": "my-hook"
}
```

`on_stop` runs any command with the finished session directory as its argument
— summarization, filing, indexing, whatever comes after the transcript.

## Agents

Two kinds of destination, both auto-detected:

**Terminal sessions** — Patchthrough looks for agent CLIs in the usual install
locations: `claude`, `copilot`, `codex`, `kimi`, `opencode`, `cursor-agent`.
Most launch as `<agent> "<prompt>"`; opencode uses `opencode run`; kimi takes
no initial prompt, so Patchthrough stages it on your clipboard.

**GUIs** (`patchthrough hand <target> --gui`, or straight from the menu bar) — each
app gets the best door it actually exposes:

| target | how the handoff lands |
|---|---|
| `copilot` | VS Code opens via `code chat` — agent mode, transcript attached as context |
| `cursor` | Cursor opens the repo, prompt arrives via its `cursor://` deeplink (clipboard fallback) |
| `claude` | Claude app opens **with the transcript file attached** (it accepts any file as a document); instructions on the clipboard |
| `claude-cowork` | Claude opens the **whole session folder** as a workspace — audio, timing, transcript, all of it |
| `codex` | ChatGPT app opens; prompt + full transcript on the clipboard, one paste |
| `kimi` | Kimi app opens; same clipboard payload |

Where an app exposes no prompt API, the clipboard payload is deliberately
self-contained — instructions first, verbatim transcript below. Add
`"auto_paste": true` to the config and Patchthrough finishes the job itself,
synthesizing ⌘N + ⌘V after the app opens (one-time Accessibility grant; you
still press send).

And the universal door: the Patchthrough window (menu bar → Open Patchthrough) shows every
session with a **drag chip** — drag the transcript file into any chat input
anywhere, including apps Patchthrough has no button for. The generated
`handoff.md` is self-contained: it carries both the instructions for the agent
and the verbatim transcript, so the command is not lost when a file is dragged
or attached.

Adding an agent or GUI target is a one-line entry in
`Sources/patchthrough/Handoff.swift`.

## Trust

The transcript of your meetings is about as sensitive as data gets, so the
supply-chain posture is deliberate:

- **Everything on-device.** Audio, transcripts, and the handoff never touch a
  network. The only downloads are the transcription models, fetched once from
  HuggingFace by FluidAudio.
- **Exact dependency pins.** Two dependencies (swift-argument-parser,
  FluidAudio), pinned with `.exact()` — no version range can silently pull
  unreviewed code into a binary with microphone access.
- **Reviewed baselines.** `packaging/verify-deps.sh` fails the build if the
  resolved dependencies drift from the committed baseline, if the compiled
  checkout doesn't match the lockfile, or if a dependency checkout has local
  modifications. `packaging/verify-models.sh` does the same for the downloaded
  model files, which are executed by Core ML and otherwise covered by nothing.
- **No npm install scripts.** The npm package is plain JavaScript. It never
  downloads or executes a native binary during installation.
- **Documented handoff contract.** The app and CLI communicate through the
  versioned session files documented in [`schemas/session-v1.md`](schemas/session-v1.md).
- **Small native app bundle.** The executable, Info.plist, icon, and required
  assets live in a normal signed macOS bundle so Dock identity and TCC
  permissions stay attached to Patchthrough.

## Gotchas

- A global tap records **everything** the Mac plays — notification dings,
  music, all of it. Don't play anything you don't want transcribed.
- Silent recordings usually mean System Settings → Privacy & Security →
  Screen & System Audio Recording is off for patchthrough.
- Parakeet is English-only.
- Expect ASR errors on proper nouns and identifiers; the handoff prompt warns
  the agent about exactly this.

## Releases

The app and CLI share this repository and the session-file contract, but they
release independently:

- `./packaging/make-dist.sh <version>` builds the signed disk image, and
  `./packaging/notarize.sh` notarizes and staples it before it is attached to a
  GitHub release.
- `cd cli && npm publish` publishes the JavaScript CLI. CLI releases use tags
  such as `cli-v2.0.0`; app releases retain `v1.0.2`-style tags.

Changing `schemas/session-v1.md` requires compatibility coverage in the CLI
tests and a fallback for sessions written by older app versions.

## Credits

Patchthrough began as a detached rebuild of [quill](https://github.com/digimata/quill)
by digimata — the recording and transcription core descends from it (MIT, see
LICENSE). Transcription is [Parakeet TDT](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2)
via [FluidAudio](https://github.com/FluidInference/FluidAudio)'s Core ML port.

## License

MIT
