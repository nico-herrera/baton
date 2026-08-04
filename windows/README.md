# Windows recorder

Read [`schemas/session-v1.md`](../schemas/session-v1.md) first. That contract is
the whole interface between a recorder and everything downstream.

## State

Milestone 1 is partly built. Be careful about what is verified here.

| Part | State | Verified how |
|---|---|---|
| Session format: meta.json, transcript.raw.json, transcript.json, transcript.md, handoff.md | done | unit tests and `verify-contract.sh` read a generated session with the real npm CLI |
| Silence padding arithmetic | done | unit tests, including a two-hour gap |
| Transcript line breaks | done | unit tests against the rules in ParakeetEngine.swift |
| Audio capture through WASAPI | written | **compiles only.** It has never run |
| AAC encoding through Media Foundation | written | **compiles only.** It has never run |
| Parakeet through sherpa-onnx | written | compiles and model-free tests pass; hardware/model smoke is scheduled/manual |
| Whisper Large v3 Turbo Q5 through Whisper.net | written | compiles; probes Vulkan, CPU, then CPU-no-AVX; hardware/model smoke pending |
| Model download | done in code | resumable and pinned SHA-256 verification; real Windows download/load pending |
| Portable ZIP and per-user installer | done in code | Windows CI builds the self-contained x64 executable, installs it, runs it, uninstalls it, and verifies SHA-256 files |
| Authenticode signature | wired, not credentialed | release script signs the app and installer when given a certificate thumbprint; no public certificate is configured yet |
| Tray application | not started | milestone 2 |

The hardware rows remain the risk. A cross-compiled Windows binary and model-free
tests prove APIs and contracts, not capture, codecs, GPU selection, or inference on a
real Windows device. A public Windows release stays a preview until
[`../docs/windows-hardware-acceptance.md`](../docs/windows-hardware-acceptance.md)
is complete.

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

## Build the Windows packages

On Windows, install Inno Setup 6 or 7 and run:

```powershell
windows\packaging\build-release.ps1 -Version 1.4.0
windows\packaging\verify-release.ps1 -ExpectedVersion 1.4.0
```

The release build uses locked NuGet dependency graphs and produces a self-contained
single-file executable. A user does not need to install .NET. The output is:

```text
dist\Patchthrough-windows-x64.zip
dist\Patchthrough-windows-x64.zip.sha256
dist\Patchthrough-windows-x64-setup.exe
dist\Patchthrough-windows-x64-setup.exe.sha256
```

The installer is x64, per-user, and does not ask for administrator access. It installs
under the current user's Programs directory, registers `Patchthrough.exe`, and offers
to add the install directory to the user's `PATH`. The verifier exercises the portable
executable plus the full install/run/uninstall path on Windows CI. The packaged build
requires an x64-compatible Windows 10 version 1809 or later, or Windows 11.

CI artifacts are unsigned previews. For a public build, import the Authenticode
certificate into the current user's certificate store and pass its thumbprint:

```powershell
windows\packaging\build-release.ps1 -Version 1.4.0 `
  -CertificateThumbprint $env:PATCHTHROUGH_CERTIFICATE_THUMBPRINT
```

The script signs and verifies both `Patchthrough.exe` and the installer with SHA-256
and a trusted timestamp. Do not publish those artifacts as supported Windows builds
until the physical-hardware checklist also passes.

## Use

```
Patchthrough rec [--out <dir>] [--name <title>]   record a meeting
Patchthrough transcribe [--out <dir>]             transcribe what is pending
Patchthrough doctor [--out <dir>]                 check this machine
Patchthrough benchmark --audio <file> --engine parakeet|whisper [--quality standard|max_accuracy]
```

`rec` records until Ctrl+C or Enter, then transcribes. A failed transcription
leaves the audio and meta.json in place, so `transcribe` retries it.

Set `transcription.quality_mode` in the shared config to `standard` or
`max_accuracy`. Windows keeps both modes on the recoverable Parakeet path unless
`~/.config/patchthrough/quality-profile.json` contains release-qualified evidence
from a corrected corpus for another engine. An unqualified profile cannot silently enable
Whisper or dual-engine consensus; see
[`../docs/engine-selection.md`](../docs/engine-selection.md).

The explicitly selected model downloads on first use into
`%LOCALAPPDATA%\patchthrough\models`. Partial files resume. Patchthrough checks the
registered byte length and SHA-256 before installing/loading, securely extracts the
Parakeet archive, and revalidates installed files on later launches. `doctor` reports
what will download without treating a not-yet-cached model as a broken machine.

## What is left in milestone 1

Every remaining item needs a physical Windows machine with real audio hardware.

1. Run `Patchthrough doctor`. It should find the devices and the model.
2. Record a meeting. Confirm both tracks hold audio.
3. Record three minutes and play audio only in the middle minute. Confirm the
   two tracks stay aligned, which is what the silence padding exists for. This
   is the failure most likely to survive into a release, because it produces a
   plausible transcript with wrong times rather than an error.
4. Confirm `patchthrough hand claude` on the same machine hands the session off.

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
4. **Distribution.** The portable ZIP and per-user installer are implemented.
   Authenticode credentials, public release publication, and self-exclusion from the
   loopback capture remain.

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
