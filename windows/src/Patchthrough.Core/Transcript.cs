using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Patchthrough.Core;

/// <summary>One line of speech, on the session clock.</summary>
public sealed record Segment(
    string Speaker,
    int StartMs,
    int EndMs,
    string Text,
    double? Confidence = null,
    IReadOnlyList<EngineWord>? Words = null,
    string? SourceTrack = null,
    IReadOnlyList<string>? AppliedVocabulary = null);

/// <summary>
/// The canonical transcript, and the readable rendering of it. The rendering is
/// a contract: the npm CLI finds a spoken line with
/// `^\*\*\[[^\]]+\]\s+[^:]+:\*\*`, so the shape of these lines is not a style
/// choice. See Transcript in TranscriptionCoordinator.swift.
/// </summary>
public sealed class Transcript
{
    public int PipelineVersion { get; init; } = 2;
    public required string Engine { get; init; }
    public required string Model { get; init; }
    public string QualityMode { get; init; } = "standard";
    public required DateTimeOffset CreatedAt { get; init; }
    public required IReadOnlyList<Segment> Segments { get; init; }

    /// <summary>
    /// Merge the per-track results into one timeline. Each track's times shift
    /// by its own start offset, so both tracks share one clock. The sort breaks
    /// ties on the speaker, because two segments that share a start time would
    /// otherwise swap places between runs and make transcripts undiffable.
    /// </summary>
    public static List<Segment> Merge(IEnumerable<(Track Track, IEnumerable<Segment> Segments)> results)
    {
        var merged = new List<Segment>();
        foreach (var (track, segments) in results)
        {
            foreach (var segment in segments)
            {
                merged.Add(segment with
                {
                    Speaker = track.Speaker,
                    SourceTrack = track.Key,
                    StartMs = segment.StartMs + track.OffsetMs,
                    EndMs = segment.EndMs + track.OffsetMs,
                });
            }
        }
        merged.Sort((a, b) => a.StartMs != b.StartMs
            ? a.StartMs.CompareTo(b.StartMs)
            : string.CompareOrdinal(a.Speaker, b.Speaker));
        return merged;
    }

    public string ToJson()
    {
        var segments = new JsonArray();
        foreach (var segment in Segments)
        {
            var appliedVocabulary = new JsonArray();
            foreach (var term in segment.AppliedVocabulary ?? []) appliedVocabulary.Add(term);
            // Alphabetical, matching Swift's sorted keys.
            segments.Add(new JsonObject
            {
                ["applied_vocabulary"] = appliedVocabulary,
                ["confidence"] = segment.Confidence,
                ["end_ms"] = segment.EndMs,
                ["speaker"] = segment.Speaker,
                ["source_track"] = segment.SourceTrack,
                ["start_ms"] = segment.StartMs,
                ["text"] = segment.Text,
            });
        }
        var root = new JsonObject
        {
            ["created_at"] = SessionMeta.Iso8601(CreatedAt),
            ["engine"] = Engine,
            ["model"] = Model,
            ["pipeline_version"] = PipelineVersion,
            ["quality_mode"] = QualityMode,
            ["segments"] = segments,
        };
        return root.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
    }

    /// <summary>
    /// transcript.md. The title is the session directory name, the same as on
    /// macOS, and a blank line follows every spoken line.
    /// </summary>
    public string Render(string title)
    {
        var lines = new List<string> { $"# {title}", "", $"engine: {Engine} ({Model})", "" };
        foreach (var segment in Segments)
        {
            lines.Add($"**[{Clock(segment.StartMs)}] {segment.Speaker}:** {segment.Text}");
            lines.Add("");
        }
        return string.Join("\n", lines);
    }

    /// <summary>
    /// Write transcript.json and transcript.md. The json file is the completion
    /// marker, so it is written last: a reader that sees it must find a
    /// readable transcript beside it.
    /// </summary>
    public void Write(string sessionDirectory)
    {
        var title = new DirectoryInfo(sessionDirectory).Name;
        AtomicFile.WriteText(Path.Combine(sessionDirectory, "transcript.md"), Render(title));
        AtomicFile.WriteText(Path.Combine(sessionDirectory, "transcript.json"), ToJson());
    }

    /// <summary>
    /// `m:ss`, or `h:mm:ss` past an hour. The minutes stay unpadded below an
    /// hour, which is what the macOS app writes.
    /// </summary>
    public static string Clock(int milliseconds)
    {
        var total = milliseconds / 1000;
        int hours = total / 3600, minutes = total % 3600 / 60, seconds = total % 60;
        return hours > 0
            ? string.Format(CultureInfo.InvariantCulture, "{0}:{1:00}:{2:00}", hours, minutes, seconds)
            : string.Format(CultureInfo.InvariantCulture, "{0}:{1:00}", minutes, seconds);
    }
}
