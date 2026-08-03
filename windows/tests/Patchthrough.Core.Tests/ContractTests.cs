using System.Text.Json.Nodes;
using Patchthrough.Core;

namespace Patchthrough.Core.Tests;

/// <summary>
/// The session format is the whole interface to the npm CLI and to the macOS
/// app, so these tests assert the exact bytes rather than "something was
/// written". The expected strings come from TranscriptionCoordinator.swift and
/// Handoff.swift.
/// </summary>
public sealed class ContractTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "pt-core-" + Guid.NewGuid().ToString("N")[..8]);

    public ContractTests() => Directory.CreateDirectory(_root);

    public void Dispose() => Directory.Delete(_root, recursive: true);

    private static Transcript SampleTranscript() => new()
    {
        Engine = "parakeet",
        Model = "parakeet-tdt-0.6b-v2",
        CreatedAt = new DateTimeOffset(2026, 8, 3, 14, 5, 0, TimeSpan.Zero),
        Segments =
        [
            new Segment("me", 1000, 2500, "Ship the Windows recorder."),
            new Segment("them", 5000, 7000, "Agreed, after the CLI lands."),
        ],
    };

    [Fact]
    public void TranscriptMarkdownMatchesTheMacOsRendering()
    {
        // The CLI finds a spoken line with ^\*\*\[[^\]]+\]\s+[^:]+:\*\* and a
        // blank line follows every one of them.
        const string expected =
            "# 2026.08.03-1400\n"
            + "\n"
            + "engine: parakeet (parakeet-tdt-0.6b-v2)\n"
            + "\n"
            + "**[0:01] me:** Ship the Windows recorder.\n"
            + "\n"
            + "**[0:05] them:** Agreed, after the CLI lands.\n";

        Assert.Equal(expected, SampleTranscript().Render("2026.08.03-1400"));
    }

    [Theory]
    [InlineData(0, "0:00")]
    [InlineData(1000, "0:01")]
    [InlineData(65_000, "1:05")]
    [InlineData(3_600_000, "1:00:00")]
    [InlineData(3_725_000, "1:02:05")]
    public void ClockMatchesTheMacOsFormat(int milliseconds, string expected) =>
        Assert.Equal(expected, Transcript.Clock(milliseconds));

    [Fact]
    public void TranscriptJsonCarriesTheCanonicalKeys()
    {
        var root = JsonNode.Parse(SampleTranscript().ToJson())!.AsObject();

        Assert.Equal("parakeet", (string?)root["engine"]);
        Assert.Equal("parakeet-tdt-0.6b-v2", (string?)root["model"]);
        Assert.Equal("2026-08-03T14:05:00Z", (string?)root["created_at"]);
        var first = root["segments"]!.AsArray()[0]!.AsObject();
        Assert.Equal(["end_ms", "speaker", "start_ms", "text"], first.Select(pair => pair.Key));
        Assert.Equal("me", (string?)first["speaker"]);
        Assert.Equal(1000, (int?)first["start_ms"]);
    }

    [Fact]
    public void MergeShiftsEachTrackOntoOneClockAndBreaksTiesOnSpeaker()
    {
        var mic = new Track("mic", "mic.m4a", "me", 0);
        var system = new Track("system", "system.m4a", "them", 200);

        var merged = Transcript.Merge([
            (mic, [new Segment("", 1000, 1500, "mine")]),
            (system, [new Segment("", 800, 900, "theirs"), new Segment("", 1000, 1100, "tie")]),
        ]);

        // The system track started 200 ms late, so its own 800 ms lands at 1000.
        Assert.Equal([1000, 1000, 1200], merged.Select(s => s.StartMs));
        // Two segments now share 1000 ms. "me" sorts before "them", so the
        // order is stable between runs and the transcript stays diffable.
        Assert.Equal(["me", "them", "them"], merged.Select(s => s.Speaker));
        Assert.Equal("mine", merged[0].Text);
    }

    [Fact]
    public void HandoffDocumentMatchesTheMacOsDocument()
    {
        var directory = Path.Combine(_root, "2026.08.03-1400");
        Directory.CreateDirectory(directory);
        var transcript = SampleTranscript().Render("2026.08.03-1400");

        var document = HandoffDocument.Build(directory, transcript, 92, cleanStop: true, name: null);

        Assert.StartsWith("# Meeting handoff: 2026.08.03-1400\n\n## Instructions\n", document);
        Assert.Contains("- Duration: 1m32s\n", document);
        Assert.Contains($"- Source: `{directory}`", document);
        // The title and engine lines of transcript.md are dropped, because this
        // document writes its own header.
        Assert.DoesNotContain("engine: parakeet (parakeet-tdt-0.6b-v2)", document);
        // The verbatim transcript is the last thing in the file.
        Assert.EndsWith("## Transcript\n\n**[0:01] me:** Ship the Windows recorder.\n\n**[0:05] them:** Agreed, after the CLI lands.\n", document);
        // The shared caveat travels inside the instructions.
        Assert.Contains(HandoffDocument.AsrCaveat, document);
    }

    [Fact]
    public void AnUncleanStopIsDisclosedInTheHandoff()
    {
        var document = HandoffDocument.Build(_root, "**[0:01] me:** cut short", 30, cleanStop: false, name: null);
        Assert.Contains("- Duration: 0m30s (recording ended uncleanly, so the transcript may be truncated)", document);
    }

    [Fact]
    public void AMeetingNameBecomesTheHandoffTitleAndTheDirectoryStaysTheIdentity()
    {
        var directory = Path.Combine(_root, "2026.08.03-1400");
        Directory.CreateDirectory(directory);

        var document = HandoffDocument.Build(directory, "**[0:01] me:** hello", 60, true, "Windows port kickoff");

        Assert.StartsWith("# Meeting handoff: Windows port kickoff\n", document);
        Assert.Contains($"- Source: `{directory}`", document);
    }

    [Fact]
    public void ProvisionalMetaMarksTheSessionUncleanUntilItStops()
    {
        var writer = SessionWriter.Create(_root, new DateTimeOffset(2026, 8, 3, 14, 0, 0, TimeSpan.Zero));
        writer.AddTrack("mic", "mic.m4a");
        writer.AddTrack("system", "system.m4a", offsetMs: 12);

        writer.WriteProvisionalMeta(new DateTimeOffset(2026, 8, 3, 14, 0, 5, TimeSpan.Zero));
        var provisional = SessionMeta.Read(writer.Directory);
        // A crash now leaves a session the pipeline still picks up, and the
        // false flag tells the reader the transcript may be truncated.
        Assert.False(provisional.CleanStop);

        writer.WriteFinalMeta(new DateTimeOffset(2026, 8, 3, 14, 1, 32, TimeSpan.Zero));
        var final = SessionMeta.Read(writer.Directory);
        Assert.True(final.CleanStop);
        Assert.Equal(92, final.DurationSeconds);
        Assert.Equal("mic.m4a", final.Files["mic"]);
        Assert.Equal(12, final.StartOffsetMs["system"]);
    }

    [Fact]
    public void TheDirectoryNameIsTheSessionIdentityAndCollisionsGetASuffix()
    {
        var when = new DateTimeOffset(2026, 8, 3, 14, 0, 0, TimeSpan.Zero);

        Assert.Equal("2026.08.03-1400", new DirectoryInfo(SessionWriter.Create(_root, when).Directory).Name);
        // A second recording inside the same minute must not overwrite the first.
        Assert.Equal("2026.08.03-1400-2", new DirectoryInfo(SessionWriter.Create(_root, when).Directory).Name);
        Assert.Equal("2026.08.03-1400-3", new DirectoryInfo(SessionWriter.Create(_root, when).Directory).Name);
    }

    [Fact]
    public void MetaTracksMapMicToMeAndSystemToThem()
    {
        var meta = new SessionMeta
        {
            Started = DateTimeOffset.UnixEpoch,
            DurationSeconds = 1,
            CleanStop = true,
            Files = new() { ["system"] = "system.m4a", ["mic"] = "mic.m4a" },
            StartOffsetMs = new(),
        };

        // The mic comes first regardless of the order in the file, so the merge
        // input order is stable.
        Assert.Equal([("mic.m4a", "me"), ("system.m4a", "them")],
            meta.Tracks().Select(t => (t.File, t.Speaker)));
    }

    [Fact]
    public void AtomicWriteLeavesNoTemporaryFileBehind()
    {
        var target = Path.Combine(_root, "transcript.md");
        AtomicFile.WriteText(target, "first");
        AtomicFile.WriteText(target, "second");

        Assert.Equal("second", File.ReadAllText(target));
        Assert.Empty(Directory.GetFiles(_root, "*.tmp"));
        // No byte order mark: it would land on the first line of transcript.md.
        Assert.Equal((byte)'s', File.ReadAllBytes(target)[0]);
    }
}
