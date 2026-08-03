using System.Text.Json;
using System.Text.Json.Nodes;

namespace Patchthrough.Core;

/// <summary>One audio track of a session, and who it represents.</summary>
public sealed record Track(string Key, string File, string Speaker, int OffsetMs);

/// <summary>
/// meta.json. The macOS app writes the same keys from RecordingSession.swift,
/// and `files` is what names the audio, so a Windows recorder can write any
/// container. See schemas/session-v1.md.
/// </summary>
public sealed class SessionMeta
{
    public required DateTimeOffset Started { get; init; }
    public DateTimeOffset? Ended { get; init; }
    public required int DurationSeconds { get; init; }
    public required bool CleanStop { get; init; }
    public required Dictionary<string, string> Files { get; init; }
    public required Dictionary<string, int> StartOffsetMs { get; init; }
    public string? Name { get; init; }

    /// <summary>
    /// The tracks in the order the coordinator transcribes them. The mic is
    /// `me` and the system track is `them`, exactly as on macOS.
    /// </summary>
    public IEnumerable<Track> Tracks()
    {
        if (Files.TryGetValue("mic", out var mic))
        {
            yield return new Track("mic", mic, "me", StartOffsetMs.GetValueOrDefault("mic"));
        }
        if (Files.TryGetValue("system", out var system))
        {
            yield return new Track("system", system, "them", StartOffsetMs.GetValueOrDefault("system"));
        }
    }

    /// <summary>
    /// Serialize with sorted keys and two-space indentation, which is what
    /// Swift's `[.prettyPrinted, .sortedKeys]` produces. The order costs
    /// nothing and keeps a Windows session diffable against a macOS one.
    /// </summary>
    public string ToJson()
    {
        var files = new JsonObject();
        foreach (var pair in Files.OrderBy(p => p.Key, StringComparer.Ordinal)) files[pair.Key] = pair.Value;

        var offsets = new JsonObject();
        foreach (var pair in StartOffsetMs.OrderBy(p => p.Key, StringComparer.Ordinal)) offsets[pair.Key] = pair.Value;

        // Added in alphabetical order, because System.Text.Json writes
        // properties in insertion order and has no sorting option.
        var root = new JsonObject
        {
            ["clean_stop"] = CleanStop,
            ["duration_seconds"] = DurationSeconds,
        };
        if (Ended is not null) root["ended"] = Iso8601(Ended.Value);
        root["files"] = files;
        if (!string.IsNullOrWhiteSpace(Name)) root["name"] = Name;
        root["start_offset_ms"] = offsets;
        root["started"] = Iso8601(Started);

        return root.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
    }

    public void Write(string sessionDirectory) =>
        AtomicFile.WriteText(Path.Combine(sessionDirectory, "meta.json"), ToJson());

    public static SessionMeta Read(string sessionDirectory)
    {
        var path = Path.Combine(sessionDirectory, "meta.json");
        if (JsonNode.Parse(File.ReadAllText(path)) is not JsonObject root)
        {
            throw new JsonException($"can't parse {path}");
        }

        var files = new Dictionary<string, string>();
        if (root["files"] is JsonObject fileMap)
        {
            foreach (var pair in fileMap)
            {
                if (pair.Value is JsonValue value && value.TryGetValue(out string? track) && track is not null)
                {
                    files[pair.Key] = track;
                }
            }
        }
        if (files.Count == 0) throw new JsonException($"can't parse {path}: no \"files\" map");

        // Sessions recorded before offsets existed default to zero. The tracks
        // start within tens of milliseconds of each other anyway.
        var offsets = new Dictionary<string, int>();
        if (root["start_offset_ms"] is JsonObject offsetMap)
        {
            foreach (var pair in offsetMap)
            {
                if (pair.Value is JsonValue value && value.TryGetValue(out int ms)) offsets[pair.Key] = ms;
            }
        }

        var name = root["name"] is JsonValue nameValue && nameValue.TryGetValue(out string? title)
            ? title?.Trim()
            : null;

        return new SessionMeta
        {
            Started = ReadDate(root["started"]) ?? DateTimeOffset.UnixEpoch,
            Ended = ReadDate(root["ended"]),
            DurationSeconds = root["duration_seconds"] is JsonValue d && d.TryGetValue(out int secs) ? secs : 0,
            CleanStop = root["clean_stop"] is not JsonValue c || !c.TryGetValue(out bool clean) || clean,
            Files = files,
            StartOffsetMs = offsets,
            Name = string.IsNullOrEmpty(name) ? null : name,
        };
    }

    private static DateTimeOffset? ReadDate(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue(out string? text)
            && DateTimeOffset.TryParse(text, out var parsed)
            ? parsed
            : null;

    /// <summary>
    /// Second precision in UTC, which is what Swift's ISO8601DateFormatter
    /// writes by default.
    /// </summary>
    internal static string Iso8601(DateTimeOffset value) =>
        value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", System.Globalization.CultureInfo.InvariantCulture);
}
