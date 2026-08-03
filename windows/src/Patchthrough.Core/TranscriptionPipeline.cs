namespace Patchthrough.Core;

public sealed class AllTracksFailedException(int attempted) : Exception(
    $"all {attempted} track(s) failed to transcribe. See the lines above for the per-track cause");

/// <summary>
/// Cross-platform post-recording pipeline. Engines run sequentially, every raw
/// hypothesis is persisted before optional stages, and each track can recover
/// independently when an engine fails.
/// </summary>
public sealed class TranscriptionPipeline
{
    private readonly IReadOnlyList<ITranscriptionEngine> _engines;
    private readonly TextWriter _log;
    private readonly QualityMode _qualityMode;
    private readonly QualityProfile _profile;
    private readonly TranscriptionContext _context;
    private readonly bool _dedupMicEcho;

    public TranscriptionPipeline(ITranscriptionEngine engine, TextWriter? log = null)
        : this([engine], QualityMode.Standard, QualityProfile.SafeDefault, TranscriptionContext.Standard, true, log) { }

    public TranscriptionPipeline(
        IReadOnlyList<ITranscriptionEngine> engines,
        QualityMode qualityMode,
        QualityProfile profile,
        TranscriptionContext context,
        bool dedupMicEcho = true,
        TextWriter? log = null)
    {
        _engines = engines;
        _qualityMode = qualityMode;
        _profile = profile;
        _context = context;
        _dedupMicEcho = dedupMicEcho;
        _log = log ?? Console.Error;
    }

    public async Task RunAsync(string sessionDirectory, CancellationToken cancellationToken = default)
    {
        var meta = SessionMeta.Read(sessionDirectory);
        var active = new List<ITranscriptionEngine>();
        foreach (var engine in _engines)
        {
            try
            {
                await engine.PrepareAsync(cancellationToken);
                active.Add(engine);
            }
            catch (Exception error)
            {
                Log(sessionDirectory, $"optional engine {engine.Name} failed to prepare: {error.Message}");
            }
        }
        if (active.Count == 0) throw new InvalidOperationException("no transcription engine could be prepared");

        var selectedResults = new List<(Track, EngineTranscript)>();
        var rawTracks = new List<RawTrack>();
        var attempted = 0;
        foreach (var track in meta.Tracks())
        {
            var audio = Path.Combine(sessionDirectory, track.File);
            if (!File.Exists(audio))
            {
                Log(sessionDirectory, $"skipping missing track {track.File}");
                continue;
            }
            attempted++;
            var hypotheses = new List<EngineTranscript>();
            var failures = new List<string>();
            foreach (var engine in active)
            {
                Log(sessionDirectory, $"transcribing {track.File} ({engine.Name})");
                try
                {
                    hypotheses.Add(await engine.TranscribeAsync(audio, _context, cancellationToken));
                }
                catch (Exception error)
                {
                    var failure = $"{engine.Name}: {error.Message}";
                    failures.Add(failure);
                    Log(sessionDirectory, $"optional engine failed for {track.File}: {failure}");
                }
            }
            if (hypotheses.Count == 0) continue;

            EngineTranscript rawSelection;
            if (_profile.CanRunConsensus && hypotheses.Count >= 2)
            {
                rawSelection = TranscriptConsensus.Combine(hypotheses[0], hypotheses[1], _profile.Calibration);
                hypotheses.Add(rawSelection);
            }
            else rawSelection = hypotheses[0];
            var selected = TranscriptCalibration.Apply(rawSelection, _profile.Calibration);
            selectedResults.Add((track, selected));
            rawTracks.Add(new RawTrack(
                track.Key, track.Speaker, track.OffsetMs, track.File,
                hypotheses, hypotheses.Count - 1, failures));
        }

        if (attempted > 0 && selectedResults.Count == 0) throw new AllTracksFailedException(attempted);

        // Durable raw output is first. Everything below this line can be
        // repeated or bypassed without losing a single engine hypothesis.
        RawTranscript.Write(sessionDirectory, _qualityMode, rawTracks);
        var merged = Transcript.Merge(selectedResults.Select(result => (
            result.Item1,
            result.Item2.Segments.Select(segment => new Segment(
                "",
                segment.StartMs,
                segment.EndMs,
                segment.Text,
                segment.Confidence,
                segment.Words,
                AppliedVocabulary: result.Item2.Context.AppliedTerms)))));
        if (_dedupMicEcho) merged = EchoDedup.DropMicEcho(merged);

        var selectedEngines = selectedResults.Select(result => result.Item2.Engine).Distinct(StringComparer.Ordinal);
        var selectedModels = selectedResults.Select(result => result.Item2.Model).Distinct(StringComparer.Ordinal);
        new Transcript
        {
            Engine = string.Join("+", selectedEngines),
            Model = string.Join("+", selectedModels),
            PipelineVersion = 2,
            QualityMode = _qualityMode == QualityMode.MaxAccuracy ? "max_accuracy" : "standard",
            CreatedAt = DateTimeOffset.Now,
            Segments = merged,
        }.Write(sessionDirectory);

        try
        {
            HandoffDocument.Write(sessionDirectory, meta.DurationSeconds, meta.CleanStop, meta.Name);
        }
        catch (Exception error)
        {
            Log(sessionDirectory, $"could not create handoff.md: {error.Message}");
        }
        Log(sessionDirectory, $"done: {merged.Count} segments");
    }

    public static IReadOnlyList<string> Pending(string root)
    {
        if (!Directory.Exists(root)) return [];
        return Directory.GetDirectories(root)
            .Where(dir => File.Exists(Path.Combine(dir, "meta.json"))
                && !File.Exists(Path.Combine(dir, "transcript.json")))
            .OrderBy(dir => new DirectoryInfo(dir).Name, StringComparer.Ordinal)
            .ToList();
    }

    public static IReadOnlyList<string> MissingHandoffs(string root)
    {
        if (!Directory.Exists(root)) return [];
        return Directory.GetDirectories(root)
            .Where(dir => File.Exists(Path.Combine(dir, "transcript.md"))
                && !File.Exists(Path.Combine(dir, "handoff.md")))
            .OrderBy(dir => new DirectoryInfo(dir).Name, StringComparer.Ordinal)
            .ToList();
    }

    private void Log(string sessionDirectory, string message)
    {
        var line = $"{SessionMeta.Iso8601(DateTimeOffset.Now)} {message}";
        _log.WriteLine(line);
        try { File.AppendAllText(Path.Combine(sessionDirectory, "transcribe.log"), line + "\n"); }
        catch (IOException) { }
    }
}
