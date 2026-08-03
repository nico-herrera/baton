using Patchthrough.Core;

// Writes one complete session through the real Patchthrough.Core code path,
// with a stub engine in place of speech-to-text. The point is the file format,
// not the audio: this produces a session that the npm CLI and the macOS app
// must both accept. `verify-contract.sh` runs it and then hands the result to
// the published CLI.
//
// This tool builds and runs on any platform, so the session contract stays
// verifiable without a Windows machine.

var root = args.Length > 0 ? args[0] : Path.Combine(Path.GetTempPath(), "patchthrough-fixture");
Directory.CreateDirectory(root);

var startedAt = new DateTimeOffset(2026, 8, 3, 14, 0, 0, TimeSpan.Zero);
var session = SessionWriter.Create(root, startedAt);

// A real recorder writes audio here. The tracks stay empty on purpose: nothing
// downstream of the recorder opens them, which is why the container is free.
session.AddTrack("mic", "mic.m4a");
session.AddTrack("system", "system.m4a", offsetMs: 240);
File.WriteAllBytes(session.PathFor("mic.m4a"), []);
File.WriteAllBytes(session.PathFor("system.m4a"), []);

session.WriteProvisionalMeta(startedAt);
session.WriteFinalMeta(startedAt.AddSeconds(92));

await using var engine = new StubEngine();
await new TranscriptionPipeline(engine, TextWriter.Null).RunAsync(session.Directory);

Console.WriteLine(session.Directory);

/// <summary>
/// Stands in for the speech-to-text engine. The times are per track and
/// relative to that track's own start, because the pipeline owns the shift onto
/// the session clock.
/// </summary>
internal sealed class StubEngine : ITranscriptionEngine
{
    public string Name => "stub";

    public string Model => "fixture";

    public Task PrepareAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;

    public Task<IReadOnlyList<Segment>> TranscribeAsync(string audioPath, CancellationToken cancellationToken = default)
    {
        IReadOnlyList<Segment> segments = Path.GetFileName(audioPath) == "mic.m4a"
            ? [
                new Segment("", 1_000, 4_200, "We should ship the Windows recorder before the installer."),
                new Segment("", 9_000, 12_000, "I'll take the audio capture."),
            ]
            : [
                new Segment("", 4_760, 8_500, "Agreed. Keep the session format exactly as it is."),
                new Segment("", 61_000, 64_000, "Let's review it on Friday."),
            ];
        return Task.FromResult(segments);
    }

    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
