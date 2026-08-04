# Transcription evaluation

`corpus.schema.json` is the one corrected-corpus contract consumed by both
platform runners. Audio stays outside git; paths are relative to the private
manifest. A release corpus must contain at least three corrected hours and all
required categories: headphones, laptop speakers, echo, network degradation,
accents, rapid speech, silence, technical terminology, numbers, and long
recordings. Public meeting, noisy-speech, and proper-noun sets should be added
as separate manifests and scored as robustness gates.

Each runner writes `run.schema.json`. Score a candidate against the current
Parakeet baseline with:

```sh
node quality/score.mjs \
  --manifest /secure/corpus.json \
  --candidate /secure/windows-standard.json \
  --baseline /secure/windows-parakeet-baseline.json \
  --out /secure/windows-standard-score.json
```

For a two-engine Max Accuracy run, also pass `--best-single`. The scorer will
refuse to qualify consensus unless it improves WER by at least 10% and has no
category regression. Its `qualifies` field covers every release threshold,
storage/processing budgets, and the three-hour private-corpus requirement.

Confidence calibration and `quality-profile.json` must be fitted only on a
held-out correction split. The production-safe profile keeps Parakeet and
preserves number forms until a scored profile selects another engine or number
format. Never commit private audio, references, manifests, or scores.

Bootstrap a private draft from existing Patchthrough sessions without copying
audio or treating machine output as ground truth:

```sh
node quality/bootstrap-corpus.mjs \
  --recordings ~/Recordings \
  --out ~/.config/patchthrough/evaluation/corpus.draft.json
```

On macOS, the bootstrap probes every audio file with `afinfo`, records the real
track duration, and omits empty tracks. This prevents a long session with a
stopped microphone from being counted as hours of microphone evidence.

Correct each track independently, change its `reference_status` from `draft` to
`corrected`, replace `needs_labeling`, and cover these exact category ids:
`headphones`, `laptop_speakers`, `echo`, `network_degradation`, `accents`,
`rapid_speech`, `silence`, `technical_terminology`, `numbers`, and
`long_recordings`. The scorer refuses to qualify a run while any reference is
still a draft. Tracks from one meeting share `session_id`, so the three-hour gate
counts meeting time once while processing budgets still include both tracks.

Run a candidate with one model load across the full corpus:

```sh
swift run patchthrough benchmark-corpus \
  --manifest ~/.config/patchthrough/evaluation/corpus.json \
  --engine whisperkit \
  --quality max_accuracy \
  --output ~/.config/patchthrough/evaluation/macos-whisperkit.json
```

Prepare a private, browser-based correction packet after candidate runs finish:

```sh
node quality/prepare-review.mjs \
  --manifest ~/.config/patchthrough/evaluation/corpus.draft.json \
  --run parakeet=~/.config/patchthrough/evaluation/macos-parakeet.json \
  --run apple_speech=~/.config/patchthrough/evaluation/macos-apple-speech.json \
  --run whisperkit=~/.config/patchthrough/evaluation/macos-whisperkit.json \
  --seed parakeet \
  --audio-dir ~/.config/patchthrough/evaluation/review-audio \
  --out ~/.config/patchthrough/evaluation/review.html
```

The packet is a single local HTML file. It plays each source track, keeps edits
in browser storage, compares every supplied hypothesis, and exports a new
manifest. A machine hypothesis is never marked corrected automatically: the
reviewer must verify the audio and check the approval box for that track.
On macOS, `--audio-dir` losslessly repackages the recorder's AAC-in-CAF tracks
as browser-compatible M4A files while leaving every original recording intact.
