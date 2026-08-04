using System.Text.Json;

namespace Patchthrough.Core;

public sealed record RawTrack(
    string SourceTrack,
    string Speaker,
    int OffsetMs,
    string AudioFile,
    IReadOnlyList<EngineTranscript> Hypotheses,
    int SelectedHypothesis,
    IReadOnlyList<string> OptionalStageFailures);

/// <summary>
/// Lossless engine output, written before consensus, echo filtering, or
/// formatting. If any optional stage fails, this remains recoverable.
/// </summary>
public static class RawTranscript
{
    public static void Write(
        string sessionDirectory,
        QualityMode qualityMode,
        IEnumerable<RawTrack> tracks)
    {
        var document = new
        {
            SchemaVersion = 1,
            PipelineVersion = 2,
            QualityMode = qualityMode == QualityMode.MaxAccuracy ? "max_accuracy" : "standard",
            CreatedAt = SessionMeta.Iso8601(DateTimeOffset.Now),
            Tracks = tracks.ToList(),
        };
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
            WriteIndented = true,
        };
        AtomicFile.WriteText(
            Path.Combine(sessionDirectory, "transcript.raw.json"),
            JsonSerializer.Serialize(document, options));
    }
}
