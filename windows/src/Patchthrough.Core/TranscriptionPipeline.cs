namespace Patchthrough.Core;

public sealed class AllTracksFailedException(int attempted) : Exception(
    $"all {attempted} track(s) failed to transcribe. See the lines above for the per-track cause");

/// <summary>
/// Turns a recorded session into a transcript, mirroring
/// TranscriptionCoordinator.swift. The filesystem is the queue: a session with
/// meta.json but no transcript.json is pending, so a crash mid-transcription
/// retries on the next run.
/// </summary>
public sealed class TranscriptionPipeline(ITranscriptionEngine engine, TextWriter? log = null)
{
    private readonly TextWriter _log = log ?? Console.Error;

    /// <summary>
    /// Transcribe one session. Both audio tracks are independent: one bad track
    /// must not cost the other its transcript, so a failing track is logged and
    /// skipped.
    /// </summary>
    public async Task RunAsync(string sessionDirectory, CancellationToken cancellationToken = default)
    {
        var meta = SessionMeta.Read(sessionDirectory);
        await engine.PrepareAsync(cancellationToken);

        var results = new List<(Track, EngineTranscript)>();
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
            Log(sessionDirectory, $"transcribing {track.File} ({engine.Name})");
            try
            {
                var transcript = await engine.TranscribeAsync(
                    audio, TranscriptionContext.Standard, cancellationToken);
                results.Add((track, transcript));
            }
            catch (Exception error)
            {
                Log(sessionDirectory, $"skipping {track.File}: {error.Message}");
            }
        }

        // Every track that was tried failed. Writing transcript.json here would
        // be actively harmful: it is the completion marker, so a valid-looking
        // empty transcript buries the session forever. Throw, so the session
        // stays eligible for a retry.
        if (attempted > 0 && results.Count == 0) throw new AllTracksFailedException(attempted);

        RawTranscript.Write(
            sessionDirectory,
            QualityMode.Standard,
            results.Select(result => new RawTrack(
                result.Item1.Key,
                result.Item1.Speaker,
                result.Item1.OffsetMs,
                result.Item1.File,
                [result.Item2],
                0,
                [])));

        var merged = Transcript.Merge(results.Select(result => (
            result.Item1,
            result.Item2.Segments.Select(segment => new Segment(
                "",
                segment.StartMs,
                segment.EndMs,
                segment.Text,
                segment.Confidence,
                segment.Words)))));
        new Transcript
        {
            Engine = engine.Name,
            Model = engine.Model,
            PipelineVersion = 2,
            QualityMode = "standard",
            CreatedAt = DateTimeOffset.Now,
            Segments = merged,
        }.Write(sessionDirectory);

        try
        {
            HandoffDocument.Write(sessionDirectory, meta.DurationSeconds, meta.CleanStop, meta.Name);
        }
        catch (Exception error)
        {
            // transcript.json is the durable completion marker. A failure to
            // write the secondary handoff file must stay visible, but it must
            // not turn a good transcription into a permanent failure.
            Log(sessionDirectory, $"could not create handoff.md: {error.Message}");
        }
        Log(sessionDirectory, $"done: {merged.Count} segments");
    }

    /// <summary>
    /// Sessions that finished but were never transcribed, oldest first. The
    /// directory names sort chronologically, so this is a name sort.
    /// </summary>
    public static IReadOnlyList<string> Pending(string root)
    {
        if (!Directory.Exists(root)) return [];
        return Directory.GetDirectories(root)
            .Where(dir => File.Exists(Path.Combine(dir, "meta.json"))
                && !File.Exists(Path.Combine(dir, "transcript.json")))
            .OrderBy(dir => new DirectoryInfo(dir).Name, StringComparer.Ordinal)
            .ToList();
    }

    /// <summary>
    /// Sessions with a transcript but no handoff.md. That file joined the
    /// public contract after the first releases, so backfill it and let the
    /// npm CLI read the same document everywhere.
    /// </summary>
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
        try
        {
            File.AppendAllText(Path.Combine(sessionDirectory, "transcribe.log"), line + "\n");
        }
        catch (IOException)
        {
            // The log is a convenience. Losing it must not fail a transcription.
        }
    }
}
