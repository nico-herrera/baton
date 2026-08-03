using NAudio.CoreAudioApi;
using Patchthrough.Core;
using Patchthrough.Windows;
using Patchthrough.Windows.Transcription;

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
                await TranscribeAsync([directory]);
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
            return await TranscribeAsync(pending);

        case "doctor":
            return Doctor(root, config);

        default:
            Console.WriteLine("""
            Patchthrough for Windows

              Patchthrough rec [--out <dir>] [--name <title>]   record a meeting
              Patchthrough transcribe [--out <dir>]             transcribe what is pending
              Patchthrough doctor [--out <dir>]                 check this machine

            Recording writes a session that the npm CLI hands to an agent:

              npm i -g patchthrough
              patchthrough hand claude
            """);
            return 0;
    }
}

/// <summary>
/// Transcribe each session. A session that fails keeps its audio and its
/// meta.json, so `transcribe` picks it up again later.
/// </summary>
static async Task<int> TranscribeAsync(IReadOnlyList<string> sessions)
{
    await using var engine = new ParakeetEngine();
    var pipeline = new TranscriptionPipeline(engine);
    var failed = 0;
    foreach (var session in sessions)
    {
        try
        {
            await pipeline.RunAsync(session);
        }
        catch (Exception error)
        {
            failed++;
            Console.Error.WriteLine($"{Path.GetFileName(session)}: {error.Message}");
        }
    }
    return failed == 0 ? 0 : 1;
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
        var models = ModelStore.Default;
        var missing = models.Missing();
        ok &= Report(missing.Count == 0,
            $"transcription {config.TranscriptionEngine}, {models.Directory}",
            $"missing {string.Join(", ", missing.Select(Path.GetFileName))} in {models.Directory}");
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
