# Patchthrough session format v1

A Patchthrough recording is a directory. The basename of the directory is the
stable session identifier. Current app versions use `yyyy.MM.dd-HHmm`.

```text
<recordings root>/<session id>/
├── meta.json
├── mic.caf
├── system.caf
├── transcript.json
├── transcript.md
└── handoff.md
```

Audio files and `transcript.json` belong to the recorder and transcription
engine. Integrations must use the following public contract:

- `meta.json` contains `duration_seconds` and `clean_stop`. Ignore unknown
  keys.
- `transcript.md` is the readable transcript. Spoken segments begin with
  `**[timestamp] speaker:**`.
- `handoff.md` is a self-contained agent handoff. It holds the instructions,
  the recording context, and the verbatim transcript. Prefer `handoff.md` over
  a reconstruction of the instructions from `transcript.md`.

Patchthrough writes these files atomically. The presence of `transcript.json`
marks a completed transcription. Patchthrough generates `handoff.md`
immediately after `transcript.json`. Older sessions can lack `handoff.md`, so
keep a fallback that wraps `transcript.md`.

The recordings root defaults to `~/Recordings`. Both the app and the CLI honor
`recordings_dir` in `~/.config/patchthrough/config.json`.
