namespace Patchthrough.Core;

/// <summary>
/// One speech-to-text backend, ported from TranscriptionEngine.swift. The
/// times are relative to the start of the file the engine read. The pipeline
/// shifts them onto the session clock.
/// </summary>
public interface ITranscriptionEngine : IAsyncDisposable
{
    /// <summary>Short name recorded in transcript.json, such as "parakeet".</summary>
    string Name { get; }

    /// <summary>The model identifier recorded in transcript.json.</summary>
    string Model { get; }

    /// <summary>
    /// Load models. Called once before the first track, because loading is the
    /// expensive part and every track reuses it.
    /// </summary>
    Task PrepareAsync(CancellationToken cancellationToken = default);

    Task<IReadOnlyList<Segment>> TranscribeAsync(string audioPath, CancellationToken cancellationToken = default);
}
