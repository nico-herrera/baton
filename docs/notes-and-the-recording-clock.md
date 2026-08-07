# Notes and the recording clock

Notes the user types during a meeting land in `notes.json` and are rendered into
`handoff.md` above the transcript. Nothing generates or rewrites them. The value of a
note is that a human decided it mattered, and that survives only if the note reaches the
agent in the words it was typed in.

The rest of this document is about the timestamps, because that is the part with a trap
in it.

## A session has two zero points, not one

```
startedAt ──────────────► earliest ──────────────► first spoken word
    │                        │
    │                        └─ transcript.md [m:ss] is measured from here
    └─ store.elapsed / the menu bar ticker are measured from here
```

`RecordingSession.startedAt` is stamped when the object is allocated — before the
session folder exists, before the process tap is created, before the aggregate device is
built, before `AudioDeviceStart`, and before `AVAudioEngine.start()`.

`earliest` is `min(mic.firstBufferAt, system.firstBufferAt)`: the wall-clock instant of
the first audio buffer of whichever track delivered one first. Every transcript timestamp
is measured from it, because `start_offset_ms` in `meta.json` shifts each track onto that
shared zero before the segments are merged.

The gap between them is device startup latency. It is not fixed, it is not small enough
to ignore, and until `audio_start` was persisted it was **computed and thrown away** —
`meta.json` recorded `started` and the inter-track offsets, but nothing that let a
wall-clock instant be converted into transcript time.

A note keyed off `store.elapsed` therefore **overshoots** by that latency. `started` is
the earlier instant, so subtracting it yields a larger offset, and the note is labelled
further into the transcript than the moment it was reacting to. It would look right, the
number is plausible and the note is real, and it would point at the wrong line.

Measured on an M5, 2026-08-07, across two recordings minutes apart: **1.640 s** and
**0.194 s**. That spread is the point. The latency is not a constant that could be
corrected with a fixed offset, because it depends on how long the process tap, the
aggregate device and `AVAudioEngine` happen to take on that launch. It has to be
measured per session and written down, which is what `audio_start` is for. At 1.64 s it
moved a label a full second at 0:48 and two seconds at 1:01, which in a dense
conversation is a different sentence.

End-to-end check on the same day: a note committed immediately after the spoken phrase
"Flag this exact line." (transcript `[0:30]`) resolved to `0:32`, landing on that line.

## Why notes store an instant, not an offset

`notes.json` records `at`, an absolute ISO 8601 timestamp with milliseconds. The offset
is computed at render time by subtracting `audio_start`.

This is not stylistic. The transcript's zero **moves during recording**:

- `MicRecorder.fallBackToRaw` tears down the voice-processing engine about a second in if
  it delivers digital silence, sets `firstBufferAt = nil`, and deletes the partial file.
  If mic was the earliest track, `earliest` jumps forward — after notes may already exist.
- A track that never delivers a buffer at all falls back to `startedAt`, which silently
  redefines the zero from "first audio sample" to "session start".

An offset computed while recording bakes in whichever zero happened to be current. An
instant re-resolves against the final anchor, however many times that anchor moves.

## Rules the renderers share

Both `Handoff.swift` and `cli/src/patchthrough.js` render the notes section, and both
must agree:

- **Clamp at zero.** The window is live before the audio devices finish opening, so a
  note genuinely can predate the first buffer. It belongs at the start of the transcript,
  not before it.
- **No anchor means no timestamp.** A note with nothing to subtract keeps its text and
  loses its position. Rendering it at `0:00` would send a reader to the opening line of a
  meeting it has nothing to do with.
- **Truncate, never round.** `TranscriptClock.label` and the CLI's `transcriptClock` both
  floor to the second, because `transcript.md` does. A renderer that rounded would point
  one line off — the hardest kind of error to notice, because the note still looks right.
- **Absent notes render nothing at all.** No heading, no blank line, no mention in the
  instructions. Same rule the `- Disclosure:` line follows.

## Known inaccuracies

- **AAC encoder priming delay** is unaccounted for on both tracks. This is pre-existing
  and affects `transcript.md` itself; notes inherit it. Believed sub-100 ms and below the
  resolution anyone reads a `[m:ss]` label at, but unmeasured, so treat these timestamps
  as not frame-accurate. This is a separate effect from the 1.6 s device startup latency
  above, which `audio_start` does cancel.
- **Sessions written before `audio_start` existed** fall back to `started`, which
  overshoots by the device startup latency: their notes read later than the moment they
  refer to. Documented in `schemas/session-v1.md` as approximate.
- **`firstBufferAt` is an unsynchronized cross-thread `Date?`** — written on the audio
  render thread and the tap queue, read on the main actor. Pre-existing; `audio_start`
  inherits it. The Windows sibling locks; the Swift side does not.
- **Everything is wall clock.** There is no monotonic source in the record path, so an
  NTP step or a manual clock change mid-recording corrupts both anchors together.

## Platforms

The macOS app writes notes; the app and the npm CLI both render them. The Windows
recorder does neither — it has no notes surface yet, so a Windows-recorded session has
nothing to render. That is a gap in what the Windows recorder *produces*, not a
divergence in the format. When it grows a notes surface,
`windows/src/Patchthrough.Core/HandoffDocument.cs` needs the section and a clock helper
alongside it. See `windows/README.md`, "Shared prose".
