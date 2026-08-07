# Patchthrough session format v1

A Patchthrough recording is a directory. The basename of the directory is the
stable session identifier. Current app versions use `yyyy.MM.dd-HHmm`.

```text
<recordings root>/<session id>/
├── meta.json
├── mic.caf          # container depends on the recorder
├── system.caf       # container depends on the recorder
├── transcript.json
├── transcript.md
├── notes.json       # optional; present only when the user typed notes
└── handoff.md
```

Audio files and `transcript.json` belong to the recorder and transcription
engine. Integrations must use the following public contract:

- `meta.json` contains `duration_seconds` and `clean_stop`. Ignore unknown
  keys.
- `meta.json` can also contain `audio_start`, the instant every transcript
  timestamp is measured from: the first audio buffer of whichever track
  delivered one first, in ISO 8601 with milliseconds. Treat it as optional. It
  is absent from every session written before this key existed. It is **not**
  the same instant as `started`, which is stamped before the audio devices are
  opened; the gap between them is device startup latency and is not otherwise
  recoverable. A consumer converting a wall-clock instant into transcript time
  must subtract `audio_start`. Falling back to `started` when it is absent is
  correct but overshoots by that latency, placing the note later in the
  transcript than the moment it refers to (measured at 1.6 s on one machine), so
  treat a converted timestamp as approximate whenever the key is missing.
- `meta.json` can also contain `name`, the title the user gave the meeting.
  Treat it as optional: most sessions have no name. Prefer it over the
  directory name for anything a person or an agent reads. Keep using the
  directory name as the identifier, because a name is not unique and can
  change.
- `transcript.md` is the readable transcript. Spoken segments begin with
  `**[timestamp] speaker:**`.
- `notes.json` holds notes the user typed while the meeting recorded. Treat it
  as optional: it is absent from every session written before this file existed,
  and from every session where the user typed nothing. Absent means the user
  wrote nothing, never that the notes were lost. Schema:
  [`notes-v1.schema.json`](notes-v1.schema.json).

  ```json
  {
    "schema_version": 1,
    "notes": [
      {"at": "2026-08-06T15:04:22.317Z", "text": "he wants the installer first"}
    ]
  }
  ```

  These are the user's own words. Nothing generates, rewrites, or summarizes
  them, and a consumer must not either — a note is evidence of what a human
  thought mattered, and it stops being that the moment it is paraphrased.

  `at` is an absolute instant, not an offset, and it is deliberately not stored
  as one. The transcript's zero moves: a track that fails over during the first
  second changes which buffer is earliest, so an offset computed while recording
  can be wrong by the time the recording stops. Subtract `audio_start` to place
  a note on the transcript's clock, and clamp the result at zero — a note typed
  before the first audio buffer arrived belongs at the start of the transcript,
  not before it.
- `handoff.md` is a self-contained agent handoff. It holds the instructions,
  the recording context, and the verbatim transcript. Prefer `handoff.md` over
  a reconstruction of the instructions from `transcript.md`.

The audio container depends on the recorder. The macOS app writes CAF, because
that is what Core Audio encodes into. Another recorder writes another
container. A tool that needs the audio must read the filenames from the `files`
map in `meta.json`. Never build an audio filename from an assumed extension.

Patchthrough writes these files atomically. The presence of `transcript.json`
marks a completed transcription. Patchthrough generates `handoff.md`
immediately after `transcript.json`. Older sessions can lack `handoff.md`, so
keep a fallback that wraps `transcript.md`.

The recordings root defaults to `~/Recordings`. Both the app and the CLI honor
`recordings_dir` in `~/.config/patchthrough/config.json`. Both paths sit under
the home directory of the user on every platform, so one machine has one
recordings root and one config file.
