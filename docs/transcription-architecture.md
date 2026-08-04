# Cross-platform transcription architecture

The Swift `TranscriptionEngine` and C# `ITranscriptionEngine` implementations return
the same `EngineTranscript` JSON shape. One shared fixture and schema catch drift;
the implementations remain native to each platform.

Both microphone (`me`) and system (`them`) tracks remain independent. Audio is decoded
to validated 16 kHz mono samples without replacing the recording. Engines retain their
native long-form/VAD behavior and return timed words, raw confidence, language,
provenance, duration, and diagnostics. `transcript.raw.json` is written before
consensus, echo filtering, or presentation formatting.

macOS candidates are FluidAudio Parakeet v2 with acoustic CTC vocabulary evidence,
Whisper Large v3 Turbo through WhisperKit, and the on-device Apple SpeechTranscriber on
macOS 26+. Windows candidates are sherpa-onnx Parakeet greedy decoding and Whisper
Large v3 Turbo Q5 through Whisper.net, probing Vulkan before CPU fallbacks. Model
artifacts are resumable, pinned in `models/registry.json`, and hash-verified before
loading.

`auto` selection is conservative. A local `~/.config/patchthrough/quality-profile.json`
may select a different Standard engine, calibrations, or two-engine consensus only when
it carries qualifying release evidence. Without that evidence, both quality modes use
the recoverable Parakeet baseline. No LLM rewrites transcript text.

Segmentation uses punctuation, pauses, confidence changes, and a 30-second safety
boundary. Project vocabulary is bounded and derives from explicit glossaries,
manifests, dependencies, filenames, branch names, and declarations. Parakeet can apply
only CTC-acoustically verified substitutions; prompted/contextual engines report an
applied term only when timed-word confidence supports it.

See [`../quality/README.md`](../quality/README.md) for corpus scoring and
[`windows-hardware-acceptance.md`](windows-hardware-acceptance.md) for the draft exit
criteria.
