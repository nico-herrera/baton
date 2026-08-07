# Cross-platform transcription architecture

The Swift `TranscriptionEngine` and C# `ITranscriptionEngine` implementations return
the same `EngineTranscript` JSON shape. One shared fixture and schema catch drift;
the implementations remain native to each platform.

Both microphone (`me`) and system (`them`) tracks remain independent. Audio is decoded
to validated 16 kHz mono samples without replacing the recording. Engines retain their
native long-form/VAD behavior and return timed words, raw confidence, language,
provenance, duration, and diagnostics. `transcript.raw.json` is written before
consensus, echo filtering, or presentation formatting.

The active macOS shortlist is FluidAudio Parakeet v2 with acoustic CTC
vocabulary evidence and the on-device Apple SpeechTranscriber on macOS 26+.
WhisperKit remains an explicit experimental adapter after missing the current
processing and silence budgets. Windows uses sherpa-onnx Parakeet greedy
decoding as its provisional default; Whisper Large v3 Turbo Q5 through
Whisper.net remains experimental and probes Vulkan before CPU fallbacks. Model
artifacts are resumable, pinned in `models/registry.json`, and hash-verified
before loading. See [`engine-selection.md`](engine-selection.md) for the current
evidence and disposition.

`auto` selection is conservative. A local `~/.config/patchthrough/quality-profile.json`
may select a different Standard engine, calibrations, or two-engine consensus only when
it carries qualifying release evidence. Without that evidence, both quality modes use
the recoverable Parakeet baseline. No LLM rewrites transcript text.

Nothing rewrites it, in fact. The notes a user types during a meeting are stored and
rendered separately, in their own words, and never merge into `transcript.md` or
`transcript.json`. They share the transcript's clock so a note can point at a line. See
[`notes-and-the-recording-clock.md`](notes-and-the-recording-clock.md).

Segmentation uses punctuation, pauses, confidence changes, and a 30-second safety
boundary. Project vocabulary is bounded and derives from explicit glossaries,
manifests, dependencies, filenames, branch names, and declarations. Parakeet can apply
only CTC-acoustically verified substitutions; prompted/contextual engines report an
applied term only when timed-word confidence supports it.

See [`../quality/README.md`](../quality/README.md) for corpus scoring and
[`windows-hardware-acceptance.md`](windows-hardware-acceptance.md) for the draft exit
criteria.
