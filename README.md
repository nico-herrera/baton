# Patchthrough

Record the meeting. We'll patch you through to your agent.

Patchthrough is a macOS menu-bar app that records your meetings. It transcribes them
**entirely on-device**, then gives the transcript to the coding agent you use. It
records your microphone and the other side of the call as two separate tracks. The
agent starts as a primed session in the repository you discussed. Patchthrough
supports Claude Code, Copilot, Codex, Kimi, opencode, and cursor-agent.

Nothing leaves your machine. There is no account, no server, and no upload. The
handoff is the product. One click takes you from *"we agreed on it in the meeting"* to
*"an agent is implementing it with the transcript in context"*.

```
┌─ meeting ─────────┐   ┌─ on-device ─────────┐   ┌─ your agent ──────────────┐
│ your mic     ──►  │   │ two-track           │   │ claude / copilot / codex  │
│ system audio ──►  │   │ transcription,      │──►│ kimi / opencode / cursor  │
│ (the other side)  │   │ me/them diarization │   │ primed with the transcript │
└───────────────────┘   └─────────────────────┘   └───────────────────────────┘
```

## How it works

1. **Click Patchthrough in the menu bar, then click Start recording.** Patchthrough
   captures your microphone and everything the Mac plays as two separate CAF tracks.
   Two tracks are deliberate. Speech models work better on clean single-source audio.
   The two tracks also give you two-party diarization, `me` against `them`, with no
   speaker-identification model.
2. **Click Stop.** Transcription starts automatically. It uses Parakeet TDT 0.6B
   through [FluidAudio](https://github.com/FluidInference/FluidAudio) and Core ML.
   Expect roughly 20 seconds of processing for each hour of audio on Apple Silicon.
3. **In the menu bar, click Patch through to, then click claude.** The menu lists every
   agent that Patchthrough finds on your machine. Select the project folder. A terminal
   opens in that folder with the agent running and the transcript staged. You can also
   run this command inside the repository:

   ```sh
   patchthrough hand claude
   ```

The agent gets the verbatim transcript, not a summary. This is deliberate. A lossy
summary is where requirements get dropped quietly. Patchthrough adds a prompt with the
transcript. The prompt tells the agent to extract work items, decisions, and
ambiguities, to ask you before it guesses at a garbled term, and to change no code
until you agree the plan.

The transcript lands in `.meeting/` inside your repository. Patchthrough adds
`.meeting/` to the repository's **local** git excludes. Meeting content cannot reach a
commit by accident, and Patchthrough does not touch your `.gitignore`.

## Install the macOS app

[Download Patchthrough-arm64.dmg](https://github.com/nico-herrera/patchthrough/releases/latest/download/Patchthrough-arm64.dmg),
open it, and drag Patchthrough into Applications. Patchthrough Settings has an option
to launch the app at login.

Apple notarizes each release, and each release is signed with Developer ID and
published with a SHA-256 checksum. Releases therefore open on a normal double-click.
This open-source project ships directly through GitHub instead of the Mac App Store.
Developer ID is Apple's supported path for that kind of distribution.

macOS 15 removed the old right-click → **Open** bypass for unsigned apps. If you build
an unsigned copy yourself, open **System Settings → Privacy & Security**, find the
blocked-app notice, and click **Open Anyway**.

To build from source instead:

```sh
git clone https://github.com/nico-herrera/patchthrough
cd patchthrough
./packaging/make-app.sh                  # builds and installs to ~/Applications
```

`~/Applications` needs no `sudo`. The app bundle gives macOS a stable name, icon,
signature, and permission identity.

**Requires:** macOS 15 or later, because system-audio capture uses Core Audio process
taps. Apple Silicon is also required, because transcription runs on the Neural Engine.
The models are about 600 MB and download once on the first transcription. Record a
short test session while you are online, before your first real meeting.

## Command-line client

The npm package is a separate transcript client that runs on any platform. It does not
download or install the macOS app, and it has no install scripts:

```sh
npm i -g patchthrough
```

```sh
patchthrough hand [agent]           # hand the newest transcript to an agent, here
patchthrough hand claude -s <session> -d <repo> -n
patchthrough transcripts            # list sessions: length, status, first line
patchthrough hand codex --file meeting.md
```

The CLI reads the sessions that the app writes. It also accepts any transcript file or
input on stdin, so you can use the CLI without the app. See [`cli/`](cli/) for the full
CLI documentation. If you upgrade from npm package 1.x, your installed app and your
recordings stay in place. The upgrade only replaces the old wrapper command with the
new CLI.

Sessions land in `~/Recordings/<yyyy.MM.dd-HHmm>/`. Each session holds the two audio
tracks, `meta.json`, `transcript.json` with timed and speaker-tagged segments, and
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

`on_stop` runs any command and passes the finished session directory as the argument.
Use it for summarization, filing, indexing, or any other step that follows the
transcript.

## Agents

Patchthrough detects two kinds of destination automatically.

**Terminal sessions.** Patchthrough looks for agent CLIs in the usual install
locations: `claude`, `copilot`, `codex`, `kimi`, `opencode`, and `cursor-agent`. Most
agents launch as `<agent> "<prompt>"`. opencode uses `opencode run`. kimi takes no
initial prompt, so Patchthrough stages the prompt on your clipboard.

**GUI apps.** Run `patchthrough hand <target> --gui`, or start the handoff from the
menu bar. Each app gets the best entry point that the app exposes:

| target | how the handoff lands |
|---|---|
| `copilot` | VS Code opens through `code chat` in agent mode, with the transcript attached as context |
| `cursor` | Cursor opens the repository, and the prompt arrives through the `cursor://` deeplink (clipboard fallback) |
| `claude` | The Claude app opens **with the transcript file attached**, because it accepts any file as a document. Instructions go to the clipboard |
| `claude-cowork` | Claude opens the **whole session folder** as a workspace, including audio, timing, and transcript |
| `codex` | The ChatGPT app opens. The prompt and the full transcript go to the clipboard as one paste |
| `kimi` | The Kimi app opens with the same clipboard payload |

Some apps expose no prompt API. For those apps, the clipboard payload is
self-contained: instructions first, then the verbatim transcript. Add
`"auto_paste": true` to the config, and Patchthrough completes the paste for you. It
synthesizes ⌘N and ⌘V after the app opens. macOS asks for Accessibility permission
once, and you still press send.

The Patchthrough window is the universal entry point. Open it from the menu bar. Every
session in the window has a **drag chip**. Drag the transcript file into any chat
input, including the input of an app that Patchthrough has no button for. The generated
`handoff.md` is self-contained. It carries both the instructions for the agent and the
verbatim transcript, so a dragged or attached file keeps the instructions.

To add an agent or a GUI target, add one entry to
`Sources/patchthrough/Handoff.swift`.

## Trust

The transcript of your meetings is about as sensitive as data gets. The supply-chain
posture is therefore deliberate:

- **Everything on-device.** Audio, transcripts, and the handoff never touch a network.
  The only downloads are the transcription models. FluidAudio fetches them once from
  HuggingFace.
- **Exact dependency pins.** Patchthrough has two dependencies,
  swift-argument-parser and FluidAudio, and pins both with `.exact()`. No version range
  can pull unreviewed code into a binary that has microphone access.
- **Reviewed baselines.** `packaging/verify-deps.sh` fails the build in three cases:
  the resolved dependencies drift from the committed baseline, the compiled checkout
  does not match the lockfile, or a dependency checkout has local modifications.
  `packaging/verify-models.sh` does the same for the downloaded model files. Core ML
  executes those files, and nothing else covers them.
- **No npm install scripts.** The npm package is plain JavaScript. It never downloads
  or executes a native binary during installation.
- **Documented handoff contract.** The app and the CLI communicate through the
  versioned session files that
  [`schemas/session-v1.md`](schemas/session-v1.md) documents.
- **Small native app bundle.** The executable, Info.plist, icon, and required assets
  live in a normal signed macOS bundle. Dock identity and TCC permissions therefore
  stay attached to Patchthrough.

## Gotchas

- A global tap records **everything** the Mac plays. This includes notification sounds
  and music. Do not play anything that you do not want in the transcript.
- A silent recording usually means one thing: System Settings → Privacy & Security →
  Screen & System Audio Recording is off for patchthrough.
- Parakeet transcribes English only.
- Expect transcription errors on proper nouns and identifiers. The handoff prompt warns
  the agent about exactly this.

## Releases

The app and the CLI share this repository and the session-file contract, but they
release independently:

- `./packaging/make-dist.sh <version>` builds the signed disk image.
  `./packaging/notarize.sh` then notarizes and staples the disk image before you attach
  it to a GitHub release.
- `cd cli && npm publish` publishes the JavaScript CLI. CLI releases use tags such as
  `cli-v2.0.0`. App releases keep `v1.0.2`-style tags.

If you change `schemas/session-v1.md`, add compatibility coverage to the CLI tests. Add
a fallback for the sessions that older app versions wrote.

## Credits

Patchthrough began as a detached rebuild of
[quill](https://github.com/digimata/quill) by digimata. The recording and transcription
core descends from quill (MIT, see LICENSE). Transcription uses
[Parakeet TDT](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) through
[FluidAudio](https://github.com/FluidInference/FluidAudio)'s Core ML port.

## License

MIT
