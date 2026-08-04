using Patchthrough.Core;
using SherpaOnnx;

namespace Patchthrough.Windows.Transcription;

/// <summary>
/// Parakeet TDT 0.6B v2 through sherpa-onnx and ONNX Runtime, on the machine.
/// The macOS app runs the same model family through Core ML, so the two
/// platforms produce comparable transcripts and the handoff prompt can keep one
/// wording about what to expect from the text.
///
/// Expect this to be slower than the macOS app. The Neural Engine transcribes
/// an hour of audio in about 20 seconds. Int8 on a CPU is minutes, not seconds.
/// </summary>
public sealed class ParakeetEngine(ModelStore? models = null, int threads = 0) : ITranscriptionEngine
{
    private const int SampleRate = AudioNormalizer.SampleRate;

    private readonly ModelStore _models = models ?? ModelStore.Default;
    private OfflineRecognizer? _recognizer;

    public string Name => "parakeet";

    public string Model => ModelStore.ModelName;

    public async Task PrepareAsync(CancellationToken cancellationToken = default)
    {
        if (_recognizer is not null) return;
        await _models.EnsureAsync(cancellationToken);

        var config = new OfflineRecognizerConfig();
        config.FeatConfig.SampleRate = SampleRate;
        config.FeatConfig.FeatureDim = 80;
        config.ModelConfig.Transducer.Encoder = _models.Encoder;
        config.ModelConfig.Transducer.Decoder = _models.Decoder;
        config.ModelConfig.Transducer.Joiner = _models.Joiner;
        config.ModelConfig.Tokens = _models.Tokens;
        // The NeMo transducer layout. Parakeet is a NeMo export, and the wrong
        // value here fails at load rather than transcribing badly.
        config.ModelConfig.ModelType = "nemo_transducer";
        config.ModelConfig.NumThreads = threads > 0 ? threads : Math.Max(1, Environment.ProcessorCount / 2);
        config.ModelConfig.Debug = 0;
        config.DecodingMethod = "greedy_search";

        _recognizer = new OfflineRecognizer(config);
    }

    public Task<EngineTranscript> TranscribeAsync(
        string audioPath,
        TranscriptionContext context,
        CancellationToken cancellationToken = default)
    {
        if (_recognizer is null) throw new InvalidOperationException("the parakeet engine was used before PrepareAsync");

        var started = System.Diagnostics.Stopwatch.StartNew();
        var samples = AudioNormalizer.ReadMono16k(audioPath);
        // An empty track means the recorder died before its first buffer. The
        // pipeline logs a skipped track, which is better than a zero-segment
        // transcript that looks complete.
        if (samples.Length == 0) throw new InvalidDataException($"no audio in {Path.GetFileName(audioPath)}");

        using var stream = _recognizer.CreateStream();
        stream.AcceptWaveform(SampleRate, samples);
        _recognizer.Decode(stream);
        var result = stream.Result;

        var words = Segmentation.WordsFromTokens(result.Tokens, result.Timestamps, result.Durations);
        var text = string.Join(" ", (result.Text ?? "").Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        IReadOnlyList<EngineSegment> segments = words.Count == 0
            ? text.Length == 0 ? [] : [new EngineSegment(0, (int)(samples.Length * 1000.0 / SampleRate), text, null, [])]
            : Segmentation.From(words);
        started.Stop();
        var requested = context.Vocabulary.Select(term => term.Text).ToList();
        var detected = requested.Where(term => text.Contains(term, StringComparison.OrdinalIgnoreCase)).ToList();
        var transcript = new EngineTranscript
        {
            Engine = Name,
            Model = Model,
            Version = "sherpa-onnx-1.13.4",
            Settings = new Dictionary<string, string>
            {
                ["decoder"] = "greedy_search",
                ["sample_rate_hz"] = SampleRate.ToString(System.Globalization.CultureInfo.InvariantCulture),
                ["quality_mode"] = context.QualityMode == QualityMode.MaxAccuracy ? "max_accuracy" : "standard",
            },
            Text = text,
            Language = "en",
            AudioDurationMs = (int)(samples.Length * 1000.0 / SampleRate),
            ProcessingDurationMs = (int)started.ElapsedMilliseconds,
            Words = segments.SelectMany(segment => segment.Words).ToList(),
            Segments = segments,
            Diagnostics = new Dictionary<string, string> { ["runtime"] = "sherpa-onnx-cpu" },
            Context = new EngineContextEvidence(requested, detected, []),
        };
        return Task.FromResult(transcript);
    }

    public ValueTask DisposeAsync()
    {
        _recognizer?.Dispose();
        _recognizer = null;
        return ValueTask.CompletedTask;
    }
}
