using NAudio.CoreAudioApi;
using Patchthrough.Core;
using Patchthrough.Windows;
using Patchthrough.Windows.Transcription;
using System.Text.Json;

// The first Windows milestone is a console recorder. It writes the session
// format, and the npm CLI does the handoff. The tray application comes later.
//
//   Patchthrough rec [--out <dir>] [--name <title>]
//   Patchthrough transcribe [--out <dir>]
//   Patchthrough doctor [--out <dir>]

return await RunAsync(args);

static async Task<int> RunAsync(string[] args)
{
    var verb = args.FirstOrDefault() ?? "help";
    var options = ParseOptions(args.Skip(1));
    var config = Config.Load();
    var root = config.ResolveRecordingsRoot(options.GetValueOrDefault("out"));

    switch (verb)
    {
        case "rec":
            var directory = Record(root, options.GetValueOrDefault("name"));
            if (!config.TranscriptionEnabled)
            {
                Console.Error.WriteLine("transcription is disabled in the config");
            }
            else
            {
                await TranscribeAsync([directory], config, options.GetValueOrDefault("project"));
            }
            Console.WriteLine(directory);
            return 0;

        case "transcribe":
            // Anything recorded but never transcribed, oldest first. A crash
            // mid-transcription therefore costs nothing but a rerun.
            var pending = TranscriptionPipeline.Pending(root);
            if (pending.Count == 0)
            {
                Console.Error.WriteLine($"nothing pending in {root}");
                return 0;
            }
            Console.Error.WriteLine($"{pending.Count} session(s) to transcribe");
            return await TranscribeAsync(pending, config, options.GetValueOrDefault("project"));

        case "doctor":
            return Doctor(root, config);

        case "benchmark":
            return await BenchmarkAsync(options);

        default:
            Console.WriteLine("""
            Patchthrough for Windows

              Patchthrough rec [--out <dir>] [--name <title>] [--project <dir>]   record a meeting
              Patchthrough transcribe [--out <dir>] [--project <dir>]             transcribe what is pending
              Patchthrough doctor [--out <dir>]                 check this machine
              Patchthrough benchmark --audio <file> [--engine parakeet|whisper]

            Recording writes a session that the npm CLI hands to an agent:

              npm i -g patchthrough
              patchthrough hand claude
            """);
            return 0;
    }
}

static async Task<int> BenchmarkAsync(IReadOnlyDictionary<string, string> options)
{
    if (!options.TryGetValue("audio", out var audio) || string.IsNullOrWhiteSpace(audio))
        throw new ArgumentException("benchmark requires --audio <file>");
    if (!File.Exists(audio)) throw new FileNotFoundException("benchmark audio does not exist", audio);
    var name = options.GetValueOrDefault("engine", "parakeet").ToLowerInvariant();
    ITranscriptionEngine engine = name switch
    {
        "parakeet" => new ParakeetEngine(),
        "whisper" => new WhisperEngine(),
        _ => throw new ArgumentException("engine must be parakeet or whisper"),
    };
    var quality = options.GetValueOrDefault("quality", "standard") switch
    {
        "standard" => QualityMode.Standard,
        "max_accuracy" => QualityMode.MaxAccuracy,
        _ => throw new ArgumentException("quality must be standard or max_accuracy"),
    };
    try
    {
        await engine.PrepareAsync();
        var context = new TranscriptionContext(
            quality,
            ProjectVocabulary.Collect(options.GetValueOrDefault("project")));
        var transcript = await engine.TranscribeAsync(Path.GetFullPath(audio), context);
        var json = JsonSerializer.Serialize(transcript, new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
            WriteIndented = true,
        }) + Environment.NewLine;
        if (options.TryGetValue("output", out var output) && !string.IsNullOrWhiteSpace(output))
            await File.WriteAllTextAsync(output, json);
        else
            Console.Write(json);
        return 0;
    }
    finally
    {
        await engine.DisposeAsync();
    }
}

/// <summary>
/// Transcribe each session. A session that fails keeps its audio and its
/// meta.json, so `transcribe` picks it up again later.
/// </summary>
static async Task<int> TranscribeAsync(
    IReadOnlyList<string> sessions,
    Config config,
    string? projectOverride)
{
    var profile = QualityProfile.Load();
    var mode = config.TranscriptionQualityMode;
    var engines = profile.Engines(config.TranscriptionEngine, mode).Select(name =>
        name.ToLowerInvariant() switch
        {
            "parakeet" => (ITranscriptionEngine)new ParakeetEngine(),
            "whisper" => new WhisperEngine(),
            _ => throw new InvalidOperationException($"unknown transcription engine: {name}"),
        }).ToList();
    var project = !string.IsNullOrWhiteSpace(projectOverride)
        ? Config.ExpandHome(projectOverride)
        : config.TranscriptionProjectDirectory;
    var context = new TranscriptionContext(mode, ProjectVocabulary.Collect(project));
    var pipeline = new TranscriptionPipeline(
        engines, mode, profile, context, config.DedupMicEcho);
    try
    {
        var failed = 0;
        foreach (var session in sessions)
        {
            try { await pipeline.RunAsync(session); }
            catch (Exception error)
            {
                failed++;
                Console.Error.WriteLine($"{Path.GetFileName(session)}: {error.Message}");
            }
        }
        return failed == 0 ? 0 : 1;
    }
    finally
    {
        foreach (var engine in engines) await engine.DisposeAsync();
    }
}

static string Record(string root, string? name)
{
    Directory.CreateDirectory(root);
    using var recorder = new Recorder(root);

    // Ctrl+C has to stop the recording rather than kill the process, or the
    // audio stays on disk with a provisional meta.json and no transcript.
    var stopping = new ManualResetEventSlim(false);
    Console.CancelKeyPress += (_, e) =>
    {
        e.Cancel = true;
        stopping.Set();
    };

    recorder.Start();
    Console.Error.WriteLine($"recording to {recorder.Directory}");
    Console.Error.WriteLine("press Ctrl+C or Enter to stop");

    var reader = Task.Run(() => Console.ReadLine());
    WaitHandle.WaitAny([stopping.WaitHandle, ((IAsyncResult)reader).AsyncWaitHandle]);
    recorder.Stop(name);
    Console.Error.WriteLine("stopped");
    return recorder.Directory;
}

static int Doctor(string root, Config config)
{
    var ok = true;

    Console.WriteLine($"{Mark(Directory.Exists(root))} recordings  {root}");
    Console.WriteLine($"{Mark(true)} config      {Config.DefaultPath}");

    // A capture device is the microphone. Windows gates microphone access for
    // desktop applications behind one privacy setting, and a denied device
    // reports as absent here.
    var devices = new MMDeviceEnumerator();
    var capture = Count(devices, DataFlow.Capture);
    ok &= Report(capture > 0, $"microphone  {capture} capture device(s)",
        "no capture device. Check Settings, Privacy & security, Microphone");

    // Loopback needs no permission on Windows. It needs something to play into.
    var render = Count(devices, DataFlow.Render);
    ok &= Report(render > 0, $"system audio {render} playback device(s)",
        "no playback device, so there is nothing to capture");

    if (!config.TranscriptionEnabled)
    {
        Console.WriteLine($"{Mark(true)} transcription disabled in the config");
    }
    else
    {
        var names = QualityProfile.Load().Engines(config.TranscriptionEngine, config.TranscriptionQualityMode);
        Console.WriteLine($"{Mark(true)} transcription {string.Join(" + ", names)} ({config.TranscriptionQualityMode})");
        var missing = ModelStore.Default.Missing();
        if (names.Contains("parakeet") && missing.Count > 0)
            Console.WriteLine($"○ model       Parakeet will download and verify on first use ({ModelStore.Default.Directory})");
        if (names.Contains("whisper") && !File.Exists(WhisperModelStore.Default.Path))
            Console.WriteLine($"○ model       Whisper will download and verify on first use ({WhisperModelStore.Default.Directory})");
    }

    // A pending session is one the CLI cannot hand off yet.
    var pending = TranscriptionPipeline.Pending(root).Count;
    if (pending > 0) Console.WriteLine($"○ pending     {pending} session(s) not transcribed. Run: Patchthrough transcribe");

    return ok ? 0 : 1;

    static int Count(MMDeviceEnumerator devices, DataFlow flow)
    {
        try
        {
            return devices.EnumerateAudioEndPoints(flow, DeviceState.Active).Count;
        }
        catch (Exception)
        {
            return 0;
        }
    }

    static bool Report(bool good, string line, string remedy)
    {
        Console.WriteLine($"{Mark(good)} {line}");
        if (!good) Console.WriteLine($"  {remedy}");
        return good;
    }
}

static string Mark(bool good) => good ? "✓" : "○";

static Dictionary<string, string> ParseOptions(IEnumerable<string> args)
{
    var options = new Dictionary<string, string>(StringComparer.Ordinal);
    string? pending = null;
    foreach (var arg in args)
    {
        if (arg.StartsWith("--", StringComparison.Ordinal))
        {
            pending = arg[2..];
            options[pending] = "";
        }
        else if (pending is not null)
        {
            options[pending] = arg;
            pending = null;
        }
    }
    return options;
}
