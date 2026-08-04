using Patchthrough.Core;

namespace Patchthrough.Core.Tests;

public sealed class AccuracyPipelineTests
{
    [Fact]
    public void ConsensusUsesCalibratedConfidenceAndKeepsTiming()
    {
        var primary = Hypothesis("parakeet", [
            new EngineWord("Patchthrough", 100, 600, 0.95),
            new EngineWord("ships", 700, 1000, 0.55),
        ]);
        var secondary = Hypothesis("whisper", [
            new EngineWord("patchthrough", 120, 620, 0.70),
            new EngineWord("ships.", 710, 1010, 0.96),
        ]);

        var consensus = TranscriptConsensus.Combine(primary, secondary);

        Assert.Equal("Patchthrough ships.", consensus.Text);
        Assert.Equal(100, consensus.Words[0].StartMs);
        Assert.Equal(1010, consensus.Words[1].EndMs);
        Assert.Equal("rover", consensus.Engine);
    }

    [Fact]
    public void MaxAccuracyCannotEnableConsensusWithoutEvidenceProfile()
    {
        Assert.False(QualityProfile.SafeDefault.ConsensusQualified);
        Assert.Equal(["parakeet"], QualityProfile.SafeDefault.Engines("auto", QualityMode.Standard));
        Assert.Equal(["parakeet"], QualityProfile.SafeDefault.Engines("auto", QualityMode.MaxAccuracy));
    }

    [Fact]
    public void EchoNeedsEightyPercentWordAgreementAndAHigherConfidenceTrack()
    {
        var micWords = Words(["please", "review", "the", "patch", "today"], 0.70);
        var systemWords = Words(["please", "review", "the", "patch", "tomorrow"], 0.95);
        var segments = new[]
        {
            new Segment("me", 0, 2500, "please review the patch today", 0.70, micWords, "mic", []),
            new Segment("them", 50, 2550, "please review the patch tomorrow", 0.95, systemWords, "system", []),
        };

        var filtered = EchoDedup.DropMicEcho(segments);

        Assert.Single(filtered);
        Assert.Equal("them", filtered[0].Speaker);
    }

    [Fact]
    public void ContextAloneNeverChangesConsensusText()
    {
        var hypothesis = Hypothesis("parakeet", [new EngineWord("ordinary", 0, 500, 0.9)]) with
        {
            Context = new EngineContextEvidence(["Patchthrough"], [], []),
        };

        var consensus = TranscriptConsensus.Combine(hypothesis, hypothesis);

        Assert.Equal("ordinary", consensus.Text);
        Assert.Empty(consensus.Context.AppliedTerms);
    }

    [Fact]
    public void ConsensusDoesNotAlignIdenticalWordsAtUnrelatedTimes()
    {
        var early = Hypothesis("parakeet", [new EngineWord("yes", 0, 300, 0.9)]);
        var late = Hypothesis("whisper", [new EngineWord("yes", 8000, 8300, 0.9)]);

        var consensus = TranscriptConsensus.Combine(early, late);

        Assert.Equal(2, consensus.Words.Count);
    }

    [Fact]
    public void SegmentationFormatsPunctuationWithoutRewritingWords()
    {
        var segments = Segmentation.From([
            new WordTiming("Ship", 0, 0.1),
            new WordTiming("it", 0.2, 0.3),
            new WordTiming(",", 0.31, 0.32),
            new WordTiming("now!", 0.4, 0.5),
        ]);

        Assert.Equal("Ship it, now!", segments[0].Text);
    }

    private static EngineTranscript Hypothesis(string engine, IReadOnlyList<EngineWord> words) => new()
    {
        Engine = engine,
        Model = engine + "-model",
        Version = "1",
        Settings = new Dictionary<string, string>(),
        Text = string.Join(" ", words.Select(word => word.Text)),
        Language = "en",
        AudioDurationMs = words.LastOrDefault()?.EndMs ?? 0,
        ProcessingDurationMs = 1,
        Words = words,
        Segments = Segmentation.From(words.Select(word => new WordTiming(
            word.Text, word.StartMs / 1000.0, word.EndMs / 1000.0, word.Confidence)).ToList()),
        Diagnostics = new Dictionary<string, string>(),
        Context = new EngineContextEvidence([], [], []),
    };

    private static IReadOnlyList<EngineWord> Words(IReadOnlyList<string> text, double confidence) =>
        text.Select((word, index) => new EngineWord(word, index * 400, index * 400 + 300, confidence)).ToList();
}
