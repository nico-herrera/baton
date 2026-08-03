using System.Text.Json;
using System.Text.Json.Nodes;

namespace Patchthrough.Core;

/// <summary>
/// The user config, mirroring Config.swift. The path is deliberately the same
/// on every platform: the npm CLI reads
/// `~/.config/patchthrough/config.json` from the home directory with no
/// platform branch, so a second location would split the state of one machine.
/// </summary>
public sealed class Config
{
    private readonly JsonObject _root;

    public static string DefaultPath => Path.Combine(Home, ".config", "patchthrough", "config.json");

    public static string DefaultRecordingsRoot => Path.Combine(Home, "Recordings");

    private static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    private Config(JsonObject root) => _root = root;

    /// <summary>
    /// Read the config. A malformed file is reported and then ignored, the way
    /// the macOS app reports it. A recording that lands somewhere unexpected is
    /// worse than a warning.
    /// </summary>
    public static Config Load(string? path = null, TextWriter? warnings = null)
    {
        path ??= DefaultPath;
        if (!File.Exists(path)) return new Config(new JsonObject());
        try
        {
            var node = JsonNode.Parse(File.ReadAllText(path));
            if (node is JsonObject obj) return new Config(obj);
            throw new JsonException("the config file is not a JSON object");
        }
        catch (Exception)
        {
            (warnings ?? Console.Error).WriteLine($"warning: {path} is not valid JSON. Ignoring config");
            return new Config(new JsonObject());
        }
    }

    /// <summary>
    /// Resolution order matches the macOS app: the command line wins, then the
    /// config file, then the default.
    /// </summary>
    public string ResolveRecordingsRoot(string? commandLineOverride = null)
    {
        if (!string.IsNullOrEmpty(commandLineOverride)) return ExpandHome(commandLineOverride);
        var configured = String("recordings_dir");
        return configured is null ? DefaultRecordingsRoot : ExpandHome(configured);
    }

    public bool TranscriptionEnabled => NestedBool("transcription", "enabled") ?? true;

    public string TranscriptionEngine => NestedString("transcription", "engine") ?? "auto";

    public QualityMode TranscriptionQualityMode =>
        string.Equals(NestedString("transcription", "quality_mode"), "max_accuracy", StringComparison.Ordinal)
            ? QualityMode.MaxAccuracy
            : QualityMode.Standard;

    public string? TranscriptionProjectDirectory
    {
        get
        {
            var configured = NestedString("transcription", "project_dir");
            return configured is null ? null : ExpandHome(configured);
        }
    }

    public bool MicVoiceProcessing => Bool("mic_voice_processing") ?? false;

    public string? OnStop => String("on_stop");

    /// <summary>
    /// `~` and `~/` are accepted on Windows too, because the same config file
    /// can come from a Mac.
    /// </summary>
    public static string ExpandHome(string value)
    {
        if (value == "~") return Home;
        if (value.StartsWith("~/", StringComparison.Ordinal) || value.StartsWith("~\\", StringComparison.Ordinal))
        {
            return Path.Combine(Home, value[2..]);
        }
        return Path.GetFullPath(value);
    }

    private string? String(string key) =>
        _root[key] is JsonValue value && value.TryGetValue(out string? text) && !string.IsNullOrEmpty(text)
            ? text
            : null;

    private bool? Bool(string key) =>
        _root[key] is JsonValue value && value.TryGetValue(out bool flag) ? flag : null;

    private string? NestedString(string parent, string key) =>
        _root[parent] is JsonObject obj && obj[key] is JsonValue value
            && value.TryGetValue(out string? text) && !string.IsNullOrEmpty(text)
            ? text
            : null;

    private bool? NestedBool(string parent, string key) =>
        _root[parent] is JsonObject obj && obj[key] is JsonValue value
            && value.TryGetValue(out bool flag)
            ? flag
            : null;
}
