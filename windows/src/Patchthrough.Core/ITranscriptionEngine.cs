namespace Patchthrough.Core;

public enum QualityMode
{
    Standard,
    MaxAccuracy,
}

public sealed record VocabularyTerm(string Text, string Source, double Weight = 1);

public sealed record TranscriptionContext(
    QualityMode QualityMode,
    IReadOnlyList<VocabularyTerm> Vocabulary)
{
    public static TranscriptionContext Standard { get; } = new(QualityMode.Standard, []);
}

public sealed record EngineContextEvidence(
    IReadOnlyList<string> RequestedTerms,
    IReadOnlyList<string> DetectedTerms,
    IReadOnlyList<string> AppliedTerms);

public sealed record EngineWord(
    string Text,
    int StartMs,
    int EndMs,
    double? Confidence = null);

public sealed record EngineSegment(
    int StartMs,
    int EndMs,
    string Text,
    double? Confidence,
    IReadOnlyList<EngineWord> Words);

/// <summary>The shared, lossless result returned by every local ASR engine.</summary>
public sealed record EngineTranscript
{
    public required string Engine { get; init; }
    public required string Model { get; init; }
    public required string Version { get; init; }
    public required IReadOnlyDictionary<string, string> Settings { get; init; }
    public required string Text { get; init; }
    public string? Language { get; init; }
    public required int AudioDurationMs { get; init; }
    public required int ProcessingDurationMs { get; init; }
    public required IReadOnlyList<EngineWord> Words { get; init; }
    public required IReadOnlyList<EngineSegment> Segments { get; init; }
    public required IReadOnlyDictionary<string, string> Diagnostics { get; init; }
    public required EngineContextEvidence Context { get; init; }
}

/// <summary>
/// One on-device speech-to-text backend. Times in EngineTranscript are relative
/// to the source audio; TranscriptionPipeline shifts them to the session clock.
/// </summary>
public interface ITranscriptionEngine : IAsyncDisposable
{
    string Name { get; }
    string Model { get; }
    Task PrepareAsync(CancellationToken cancellationToken = default);
    Task<EngineTranscript> TranscribeAsync(
        string audioPath,
        TranscriptionContext context,
        CancellationToken cancellationToken = default);
}
