using System.Diagnostics;
using Patchthrough.Core;
using Whisper.net;
using Whisper.net.LibraryLoader;

namespace Patchthrough.Windows.Transcription;

public sealed class WhisperEngine(WhisperModelStore? models = null) : ITranscriptionEngine
{
    private readonly WhisperModelStore _models = models ?? WhisperModelStore.Default;
    private WhisperFactory? _factory;

    public string Name => "whisper";
    public string Model => WhisperModelStore.ModelName;

    public async Task PrepareAsync(CancellationToken cancellationToken = default)
    {
        if (_factory is not null) return;
        var path = await _models.EnsureAsync(cancellationToken);
        RuntimeOptions.RuntimeLibraryOrder =
            [RuntimeLibrary.Vulkan, RuntimeLibrary.Cpu, RuntimeLibrary.CpuNoAvx];
        _factory = WhisperFactory.FromPath(path);
    }

    public async Task<EngineTranscript> TranscribeAsync(
        string audioPath,
        TranscriptionContext context,
        CancellationToken cancellationToken = default)
    {
        if (_factory is null) throw new InvalidOperationException("Whisper was used before PrepareAsync");
        var samples = AudioNormalizer.ReadMono16k(audioPath);
        if (samples.Length == 0) throw new InvalidDataException($"no audio in {Path.GetFileName(audioPath)}");

        var builder = _factory.CreateBuilder()
            .WithLanguageDetection()
            .WithTokenTimestamps()
            .WithProbabilities()
            .WithEntropyThreshold(2.4f)
            .WithLogProbThreshold(-1f)
            .WithNoSpeechThreshold(0.6f);
        var requested = context.Vocabulary.Take(64).Select(term => term.Text).ToList();
        if (requested.Count > 0)
            builder.WithPrompt(("Vocabulary: " + string.Join(", ", requested) + ".")[..Math.Min(1000, ("Vocabulary: " + string.Join(", ", requested) + ".").Length)]);

        using var processor = builder.Build();
        var clock = Stopwatch.StartNew();
        var accepted = new List<SegmentData>();
        await foreach (var segment in processor.ProcessAsync(samples, cancellationToken))
        {
            if (string.IsNullOrWhiteSpace(segment.Text)) continue;
            if (segment.NoSpeechProbability >= 0.6f && segment.Probability < 0.37f) continue;
            accepted.Add(segment);
        }
        clock.Stop();

        var tokenText = new List<string>();
        var starts = new List<float>();
        var durations = new List<float>();
        var confidences = new List<float>();
        foreach (var token in accepted.SelectMany(segment => segment.Tokens))
        {
            if (string.IsNullOrWhiteSpace(token.Text) || token.Text.StartsWith("<|", StringComparison.Ordinal)) continue;
            tokenText.Add(token.Text);
            starts.Add(token.Start / 100f);
            durations.Add(Math.Max(0, token.End - token.Start) / 100f);
            confidences.Add(token.Probability);
        }
        var timed = Segmentation.WordsFromTokens(tokenText, starts, durations, confidences);
        IReadOnlyList<EngineSegment> segments = timed.Count > 0
            ? Segmentation.From(timed)
            : accepted.Select(segment => new EngineSegment(
                (int)segment.Start.TotalMilliseconds,
                (int)segment.End.TotalMilliseconds,
                segment.Text.Trim(),
                segment.Probability,
                [])).ToList();
        var words = segments.SelectMany(segment => segment.Words).ToList();
        var text = Segmentation.Normalize(string.Join(" ", accepted.Select(segment => segment.Text.Trim())));
        var detected = requested.Where(term => text.Contains(term, StringComparison.OrdinalIgnoreCase)).ToList();
        var applied = VocabularyEvidence.AcousticallySupported(requested, words);
        return new EngineTranscript
        {
            Engine = Name,
            Model = Model,
            Version = "Whisper.net-1.9.1/whisper.cpp-1.8.3",
            Settings = new Dictionary<string, string>
            {
                ["entropy_threshold"] = "2.4",
                ["log_probability_threshold"] = "-1.0",
                ["no_speech_threshold"] = "0.6",
                ["prompt_terms"] = requested.Count.ToString(System.Globalization.CultureInfo.InvariantCulture),
                ["sample_rate_hz"] = AudioNormalizer.SampleRate.ToString(System.Globalization.CultureInfo.InvariantCulture),
            },
            Text = text,
            Language = accepted.FirstOrDefault()?.Language,
            AudioDurationMs = (int)(samples.Length * 1000.0 / AudioNormalizer.SampleRate),
            ProcessingDurationMs = (int)clock.ElapsedMilliseconds,
            Words = words,
            Segments = segments,
            Diagnostics = new Dictionary<string, string>
            {
                ["runtime"] = RuntimeOptions.LoadedLibrary?.ToString() ?? "unknown",
                ["rejected_no_speech_segments"] = "enabled",
            },
            Context = new EngineContextEvidence(requested, detected, applied),
        };
    }

    public ValueTask DisposeAsync()
    {
        _factory?.Dispose();
        _factory = null;
        return ValueTask.CompletedTask;
    }
}
