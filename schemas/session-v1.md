# Patchthrough session format v1

A Patchthrough recording is a directory. Its basename is the stable session
identifier; current app versions use `yyyy.MM.dd-HHmm`.

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
engine. Integrations should use the following public contract:

- `meta.json` contains `duration_seconds` and `clean_stop`. Unknown keys must
  be ignored.
- `transcript.md` is the readable transcript. Spoken segments begin with
  `**[timestamp] speaker:**`.
- `handoff.md` is a self-contained agent handoff: instructions, recording
  context, and the verbatim transcript. Consumers should prefer it over
  reconstructing instructions from `transcript.md`.

Files are written atomically. The presence of `transcript.json` marks a
completed transcription; `handoff.md` is generated immediately afterward.
Older sessions may not contain `handoff.md`, so clients should retain a
fallback that wraps `transcript.md`.

The recordings root defaults to `~/Recordings`. Both the app and CLI honor
`recordings_dir` in `~/.config/patchthrough/config.json`.
