using Patchthrough.Core;

namespace Patchthrough.Core.Tests;

/// <summary>
/// The line breaks of a transcript are a port of `segments(from:)` in
/// ParakeetEngine.swift. A Windows transcript has to read like a macOS one, so
/// these tests pin the natural boundaries both platforms use: punctuation,
/// pauses, confidence changes, and a duration guard.
/// </summary>
public sealed class SegmentationTests
{
    private static WordTiming W(string word, double start, double end) => new(word, start, end);

    [Fact]
    public void ASentenceEndClosesASegment()
    {
        var segments = Segmentation.From([
            W("Ship", 0.0, 0.4), W("it.", 0.4, 0.8),
            W("Then", 0.9, 1.2), W("review.", 1.2, 1.6),
        ]);

        Assert.Equal(["Ship it.", "Then review."], segments.Select(s => s.Text));
        Assert.Equal(0, segments[0].StartMs);
        Assert.Equal(800, segments[0].EndMs);
        Assert.Equal(900, segments[1].StartMs);
    }

    [Fact]
    public void QuestionAndExclamationMarksCloseASegmentToo()
    {
        var segments = Segmentation.From([
            W("Ready?", 0.0, 0.5), W("Go!", 0.6, 0.9), W("now", 1.0, 1.2),
        ]);
        Assert.Equal(["Ready?", "Go!", "now"], segments.Select(s => s.Text));
    }

    [Fact]
    public void ASilenceLongerThanPointEightSecondsBreaksASegment()
    {
        // No punctuation anywhere, so only the gap can break these.
        var segments = Segmentation.From([
            W("one", 0.0, 0.5), W("two", 0.6, 1.0),
            W("three", 2.5, 3.0),
        ]);

        Assert.Equal(["one two", "three"], segments.Select(s => s.Text));
    }

    [Fact]
    public void AGapAtTheThresholdDoesNotBreakASegment()
    {
        // Exactly 0.8 seconds is not "longer than" the threshold. The macOS engine
        // uses a strict comparison, and a transcript that splits differently
        // between platforms would be a real difference in output.
        var segments = Segmentation.From([W("one", 0.0, 1.0), W("two", 1.8, 2.5)]);
        Assert.Single(segments);
        Assert.Equal("one two", segments[0].Text);
    }

    [Fact]
    public void AWordCountAloneNeverWraps()
    {
        var words = Enumerable.Range(0, 130)
            .Select(i => W($"w{i}", i * 0.1, i * 0.1 + 0.05))
            .ToList();

        var segments = Segmentation.From(words);

        Assert.Single(segments);
        Assert.Equal(130, segments[0].Text.Split(' ').Length);
    }

    [Fact]
    public void ARunOnSpeakerWrapsAtTheDurationGuard()
    {
        var words = Enumerable.Range(0, 650)
            .Select(i => W($"w{i}", i * 0.1, i * 0.1 + 0.05))
            .ToList();

        var segments = Segmentation.From(words);

        Assert.Equal([300, 300, 50], segments.Select(segment => segment.Words.Count));
    }

    [Fact]
    public void AConfidenceCliffCreatesAReadableBoundary()
    {
        var segments = Segmentation.From([
            new WordTiming("one", 0, 0.1, 0.95),
            new WordTiming("two", 0.2, 0.3, 0.94),
            new WordTiming("three", 0.4, 0.5, 0.93),
            new WordTiming("four", 0.6, 0.7, 0.92),
            new WordTiming("uncertain", 0.8, 1.0, 0.4),
        ]);

        Assert.Equal(["one two three four", "uncertain"], segments.Select(segment => segment.Text));
    }

    [Fact]
    public void NoWordsMeansNoSegments() => Assert.Empty(Segmentation.From([]));

    [Fact]
    public void SubWordTokensRebuildIntoWords()
    {
        // What a sentencepiece transducer emits: U+2581 opens a word, and the
        // rest of the pieces attach to it.
        var segments = Segmentation.From(Segmentation.WordsFromTokens(
            ["▁Patch", "through", "▁ships", "▁Windows."],
            [0.0f, 0.20f, 0.50f, 0.80f],
            [0.20f, 0.25f, 0.25f, 0.40f]));

        Assert.Single(segments);
        Assert.Equal("Patchthrough ships Windows.", segments[0].Text);
        Assert.Equal(0, segments[0].StartMs);
        // The last token ends at 0.80 + 0.40.
        Assert.Equal(1200, segments[0].EndMs);
    }

    [Fact]
    public void WithoutDurationsATokenEndsWhereTheNextBegins()
    {
        var words = Segmentation.WordsFromTokens(["▁one", "▁two"], [0.0f, 0.75f]);

        Assert.Equal(["one", "two"], words.Select(w => w.Word));
        Assert.Equal(0.75, words[0].End, precision: 3);
        // Nothing follows the last token, so it ends where it started.
        Assert.Equal(0.75, words[1].End, precision: 3);
    }

    [Fact]
    public void TokensWithNoTimestampsAreIgnoredRatherThanGuessed()
    {
        // A shorter timestamp array than the token array would otherwise read
        // past the end and invent times.
        var words = Segmentation.WordsFromTokens(["▁one", "▁two", "▁three"], [0.0f, 0.5f]);
        Assert.Equal(["one", "two"], words.Select(w => w.Word));
    }
}
