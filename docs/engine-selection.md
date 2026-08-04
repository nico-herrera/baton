# Transcription engine selection

Status: provisional shortlist, 2026-08-04. This is not a release-qualified
quality profile; human-corrected WER and the published release gates still
decide the shipped engine.

## macOS

The active shortlist is FluidAudio Parakeet v2 and Apple's on-device
SpeechTranscriber on macOS 26+. WhisperKit remains an explicit benchmark
adapter, but it is not a product-selection candidate in the current round.

| Engine | Processing minutes per recorded hour | Hallucinated words per silence minute | Current disposition |
| --- | ---: | ---: | --- |
| Parakeet | 0.206 | 0.031 | Provisional Standard default |
| Apple Speech | 0.751 | 0.126 | Accuracy challenger; improve silence rejection |
| WhisperKit | 5.300 | 3.366 | Experimental; outside both current budgets |

These are aggregate pre-correction diagnostics from 15 private tracks totaling
3.15 unique recording hours. They measure processing and silence behavior, not
WER. Listening review also preferred Apple Speech to WhisperKit, so the next
human-correction pass compares Apple Speech directly with Parakeet.

Max Accuracy may use Apple Speech plus Parakeet only if timestamped consensus
beats the best single engine by at least 10% WER without regressing a major
audio category. Otherwise it uses the best single engine's highest-quality
settings.

## Windows

sherpa-onnx Parakeet v2 is the provisional Standard engine and the safe `auto`
fallback. The Whisper.net adapter remains available for explicit experiments,
but it is not selected by an unqualified profile. Real Windows microphone,
loopback, runtime, and model-loading acceptance remains required before release.

Platform selection is intentionally independent. Apple Speech winning on a Mac
does not require Windows to use the same engine family.

