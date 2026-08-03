using NAudio.Wave;
using NAudio.Wave.SampleProviders;
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
    private const int SampleRate = 16_000;

    private readonly ModelStore _models = models ?? ModelStore.Default;
    private OfflineRecognizer? _recognizer;

    public string Name => "parakeet";

    public string Model => ModelStore.ModelName;

    public Task PrepareAsync(CancellationToken cancellationToken = default)
    {
        if (_recognizer is not null) return Task.CompletedTask;
        _models.Require();

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
        return Task.CompletedTask;
    }

    public Task<IReadOnlyList<Segment>> TranscribeAsync(
        string audioPath,
        CancellationToken cancellationToken = default)
    {
        if (_recognizer is null) throw new InvalidOperationException("the parakeet engine was used before PrepareAsync");

        var samples = ReadMono16k(audioPath);
        // An empty track means the recorder died before its first buffer. The
        // pipeline logs a skipped track, which is better than a zero-segment
        // transcript that looks complete.
        if (samples.Length == 0) throw new InvalidDataException($"no audio in {Path.GetFileName(audioPath)}");

        using var stream = _recognizer.CreateStream();
        stream.AcceptWaveform(SampleRate, samples);
        _recognizer.Decode(stream);
        var result = stream.Result;

        var words = Segmentation.WordsFromTokens(result.Tokens, result.Timestamps, result.Durations);
        if (words.Count == 0)
        {
            var text = (result.Text ?? "").Trim();
            IReadOnlyList<Segment> whole = text.Length == 0
                ? []
                : [new Segment("", 0, (int)(samples.Length * 1000.0 / SampleRate), text)];
            return Task.FromResult(whole);
        }
        return Task.FromResult<IReadOnlyList<Segment>>(Segmentation.From(words));
    }

    /// <summary>
    /// Decode any container the recorder wrote, then hand back 16 kHz mono
    /// float, which is what the model expects. Media Foundation reads both the
    /// MP4 and the WAV fallback.
    /// </summary>
    private static float[] ReadMono16k(string path)
    {
        using var reader = new MediaFoundationReader(path);
        ISampleProvider provider = reader.ToSampleProvider();

        if (provider.WaveFormat.Channels == 2)
        {
            provider = new StereoToMonoSampleProvider(provider);
        }
        else if (provider.WaveFormat.Channels > 2)
        {
            // Keep the first channel. A meeting device with more than two
            // channels is unusual, and a wrong downmix is worse than one channel.
            provider = new MultiplexingSampleProvider([provider], 1);
        }
        if (provider.WaveFormat.SampleRate != SampleRate)
        {
            provider = new WdlResamplingSampleProvider(provider, SampleRate);
        }

        var all = new List<float>();
        var buffer = new float[SampleRate];
        int read;
        while ((read = provider.Read(buffer, 0, buffer.Length)) > 0)
        {
            all.AddRange(buffer.Take(read));
        }
        return all.ToArray();
    }

    public ValueTask DisposeAsync()
    {
        _recognizer?.Dispose();
        _recognizer = null;
        return ValueTask.CompletedTask;
    }
}
