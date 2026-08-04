using System.Globalization;

namespace Patchthrough.Core;

/// <summary>
/// Owns the session directory and its meta.json, and knows nothing about
/// audio. The recorder hands it the track filenames. This mirrors the
/// directory naming and the meta lifecycle of RecordingSession.swift.
/// </summary>
public sealed class SessionWriter
{
    public string Directory { get; }
    public DateTimeOffset StartedAt { get; }

    private readonly Dictionary<string, string> _files = new();
    private readonly Dictionary<string, int> _offsets = new();

    private SessionWriter(string directory, DateTimeOffset startedAt)
    {
        Directory = directory;
        StartedAt = startedAt;
    }

    /// <summary>
    /// Create the folder as `yyyy.MM.dd-HHmm`, suffixed on a collision, so two
    /// recordings inside one minute cannot overwrite each other.
    /// </summary>
    public static SessionWriter Create(string root, DateTimeOffset? startedAt = null)
    {
        var started = startedAt ?? DateTimeOffset.Now;
        var stem = started.ToString("yyyy.MM.dd-HHmm", CultureInfo.InvariantCulture);
        var candidate = Path.Combine(root, stem);
        for (var n = 2; System.IO.Directory.Exists(candidate) || File.Exists(candidate); n++)
        {
            candidate = Path.Combine(root, $"{stem}-{n}");
        }
        System.IO.Directory.CreateDirectory(candidate);
        return new SessionWriter(candidate, started);
    }

    /// <summary>
    /// Register a track. The key is `mic` or `system`, which is what decides
    /// the speaker label. The offset is how far this track started behind the
    /// earliest one, so both tracks share one clock.
    /// </summary>
    public void AddTrack(string key, string fileName, int offsetMs = 0)
    {
        _files[key] = fileName;
        _offsets[key] = offsetMs;
    }

    public string PathFor(string fileName) => Path.Combine(Directory, fileName);

    /// <summary>
    /// Write meta.json as soon as capture starts. The transcription pipeline
    /// treats meta.json as the marker of a session worth picking up, so without
    /// this file a crash or a power loss orphans the audio on disk forever.
    /// `clean_stop` is false until a real stop rewrites it.
    /// </summary>
    public void WriteProvisionalMeta(DateTimeOffset? now = null) => Write(null, now, null);

    /// <summary>Rewrite meta.json with the real end time and the offsets.</summary>
    public void WriteFinalMeta(DateTimeOffset? endedAt = null, string? name = null) =>
        Write(endedAt ?? DateTimeOffset.Now, null, name);

    private void Write(DateTimeOffset? ended, DateTimeOffset? now, string? name)
    {
        var end = ended ?? now ?? DateTimeOffset.Now;
        new SessionMeta
        {
            Started = StartedAt,
            Ended = end,
            DurationSeconds = (int)(end - StartedAt).TotalSeconds,
            CleanStop = ended is not null,
            Files = new Dictionary<string, string>(_files),
            StartOffsetMs = new Dictionary<string, int>(_offsets),
            Name = name,
        }.Write(Directory);
    }
}
