# Windows recorder

Read [`schemas/session-v1.md`](../schemas/session-v1.md) first. That contract is
the whole interface between a recorder and everything downstream.

## State

Milestone 1 is partly built. Be careful about what is verified here.

| Part | State | Verified how |
|---|---|---|
| Session format: meta.json, transcript.md, handoff.md | done | 24 unit tests, and `verify-contract.sh` reads a generated session with the real npm CLI |
| Silence padding arithmetic | done | unit tests, including a two-hour gap |
| Audio capture through WASAPI | written | **compiles only.** It has never run |
| AAC encoding through Media Foundation | written | **compiles only.** It has never run |
| Transcription | not started | the `ITranscriptionEngine` seam exists, with no engine behind it |
| Tray application | not started | milestone 2 |

`Patchthrough.Core` targets `net8.0` and holds everything that does not need
Windows, so the session format stays testable on any machine. That split is
deliberate: the format is the part that must be right, and it is the part a Mac
can check.

`Patchthrough.Windows` targets `net8.0-windows` and holds the audio. It builds
on macOS and Linux through `EnableWindowsTargeting`, which type-checks every
call into NAudio. A compile is not a run. Nobody has yet confirmed that this
code captures a single sample.

## Build and check

```sh
cd windows
dotnet test              # the session format and the padding arithmetic
./verify-contract.sh     # writes a session, then reads it with the npm CLI
```

`verify-contract.sh` is the interesting one. It generates a session with the
real `Patchthrough.Core` code path and hands it to `cli/bin/patchthrough.js`,
which is the definition of done for milestone 1.

## What is left in milestone 1

1. Run the recorder on Windows. Confirm that both tracks capture, and that a
   meeting with a long silence in the middle keeps its two tracks aligned.
2. Add a transcription engine behind `ITranscriptionEngine`.
3. Wire the pipeline into `Patchthrough rec`, so a session arrives transcribed.

## What a Windows recorder has to do

It records two tracks, transcribes them on the machine, and writes a session
directory. It does not need to know about agents, prompts, or the CLI.

The definition of done for the first milestone is one sentence: the npm CLI on
Windows runs `patchthrough transcripts` and `patchthrough hand claude` against
a session this recorder wrote, with no change to the CLI.

That means:

- One directory for each session, named `yyyy.MM.dd-HHmm`.
- `meta.json` with `duration_seconds`, `clean_stop`, and a `files` map that
  names each audio track. Write it when recording starts, so a crash leaves a
  recoverable marker, then rewrite it on stop. A `name` key is optional, and it
  holds a title the user gave the meeting.
- `transcript.md`, where each spoken segment starts with
  `**[timestamp] speaker:**`. The speakers are `me` and `them`.
- `handoff.md`, generated immediately after the transcript.
- Atomic writes. A reader must never see a half-written file.

The audio container is free. The contract names no extension, and the CLI opens
no audio file.

## Decided stack

| Concern | Choice | Reason |
|---|---|---|
| Language | C# on .NET 8 | Best access to WASAPI, tray, and single-file publish |
| Projects | `Patchthrough.Core` (net8.0) and `Patchthrough.App` (net8.0-windows) | Core stays testable on any platform. Only the shell needs Windows |
| Audio | NAudio: `WasapiCapture` and `WasapiLoopbackCapture` | Maintained, and it wraps the APIs this needs |
| Container | AAC in MP4 through Media Foundation | Same codec the macOS app already writes |
| Transcription | sherpa-onnx with Parakeet TDT 0.6B v2, int8 | Same model family as macOS, and it returns token timings |
| UI | WPF with a tray icon | WinUI 3 has no first-class tray icon |
| Config | `%USERPROFILE%\.config\patchthrough\config.json` | The CLI reads that path on every platform. Two paths would split the state of one machine |
| Launch at login | `HKCU\...\CurrentVersion\Run` | Per user, no administrator, and visible in Task Manager |
| Install | Inno Setup, per user, plus a plain zip | No administrator, and no MSIX identity to fight |

## Milestones

1. **A session the CLI can read.** Console only, no window. Two-track capture,
   transcription, and a valid session directory. Ships as a zip.
2. **The tray app.** Start and stop, recording state, a sessions window, and
   settings.
3. **Handoffs.** Agents through Windows Terminal, the clipboard, chat sites,
   and deep links.
4. **Distribution.** Installer, Authenticode signature, and self-exclusion from
   the loopback capture.

## Risks to design for, not to discover

**Loopback capture goes silent.** WASAPI delivers no buffer at all while
nothing plays. A recorder that only writes the buffers it receives produces a
system track shorter than the microphone track, and every timestamp after the
first silence is wrong. Pad the gaps against the wall clock. Test it: record
two minutes, and play audio only in the middle minute.

**The transcription models are large.** They are about 600 MB and download
once. Verify them against a recorded hash, the way `packaging/verify-models.sh`
does for macOS.

**Windows N editions have no AAC encoder.** Report it in the doctor check, and
fall back to PCM in WAV. The `files` map makes that legal.

**Echo cancellation is off by default on macOS.** Match that. The handoff
prompt already warns that a `me` or `them` label can be wrong.

**A device change kills a stream.** A Bluetooth headset that connects mid
meeting ends the capture. Handle it, or say so in the doctor check.

## Shared prose

The handoff prompts exist twice today, in `Sources/patchthrough/Handoff.swift`
and in `cli/src/patchthrough.js`. Both files carry a comment that says to keep
them in step. A Windows recorder that grows handoffs makes a third copy. Update
all three comments when that happens.
