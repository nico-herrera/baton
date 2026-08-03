# Windows recorder

This directory is empty. It holds the plan for a Windows recorder, and nothing
is built yet. The macOS app in `Sources/` stays the only recorder today.

Read [`schemas/session-v1.md`](../schemas/session-v1.md) first. That contract is
the whole interface between a recorder and everything downstream.

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
  recoverable marker, then rewrite it on stop.
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
