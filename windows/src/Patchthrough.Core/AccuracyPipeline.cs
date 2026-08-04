using System.Text.Json;

namespace Patchthrough.Core;

public sealed record ConfidenceCalibration(double Scale, double Offset)
{
    public double? Apply(double? confidence) => confidence is null
        ? null
        : Math.Clamp(confidence.Value * Scale + Offset, 0, 1);
}

public sealed record QualityProfile
{
    public sealed record EvidenceRecord
    {
        public required bool ReleaseQualified { get; init; }
        public double? DualEngineRelativeWerImprovement { get; init; }
        public bool? ConsensusNoCategoryRegression { get; init; }
    }

    public required string StandardEngine { get; init; }
    public required IReadOnlyList<string> MaxAccuracyEngines { get; init; }
    public required bool ConsensusQualified { get; init; }
    public required IReadOnlyDictionary<string, ConfidenceCalibration> Calibration { get; init; }
    public EvidenceRecord? Evidence { get; init; }

    public static QualityProfile SafeDefault { get; } = new()
    {
        StandardEngine = "parakeet",
        MaxAccuracyEngines = ["parakeet"],
        ConsensusQualified = false,
        Calibration = new Dictionary<string, ConfidenceCalibration>(),
    };

    public static QualityProfile Load(string? path = null)
    {
        path ??= Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".config", "patchthrough", "quality-profile.json");
        if (!File.Exists(path)) return SafeDefault;
        try
        {
            return JsonSerializer.Deserialize<QualityProfile>(
                File.ReadAllText(path),
                new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower })
                ?? SafeDefault;
        }
        catch (JsonException)
        {
            return SafeDefault;
        }
    }

    public IReadOnlyList<string> Engines(string configured, QualityMode mode)
    {
        if (!string.Equals(configured, "auto", StringComparison.OrdinalIgnoreCase)) return [configured];
        if (Evidence?.ReleaseQualified != true) return ["parakeet"];
        if (mode == QualityMode.MaxAccuracy && CanRunConsensus && MaxAccuracyEngines.Count >= 2)
            return MaxAccuracyEngines.Take(2).ToList();
        return [mode == QualityMode.Standard ? StandardEngine : MaxAccuracyEngines.FirstOrDefault() ?? StandardEngine];
    }


    public bool CanRunConsensus => ConsensusQualified
        && Evidence?.DualEngineRelativeWerImprovement >= 0.10
        && Evidence?.ConsensusNoCategoryRegression == true;
}

public static class TranscriptConsensus
{
    private enum Direction { Both, Left, Right }
    private sealed record Step(Direction Direction, int Left, int Right);

    public static EngineTranscript Combine(
        EngineTranscript primary,
        EngineTranscript secondary,
        IReadOnlyDictionary<string, ConfidenceCalibration>? calibration = null)
    {
        calibration ??= new Dictionary<string, ConfidenceCalibration>();
        var words = new List<EngineWord>();
        foreach (var step in Align(primary.Words, secondary.Words))
        {
            if (step.Direction == Direction.Both)
            {
                var left = primary.Words[step.Left];
                var right = secondary.Words[step.Right];
                var leftScore = Score(primary.Engine, left.Confidence, calibration) ?? 0.5;
                var rightScore = Score(secondary.Engine, right.Confidence, calibration) ?? 0.5;
                var selected = leftScore >= rightScore ? left : right;
                words.Add(selected with { Confidence = Math.Max(leftScore, rightScore) });
            }
            else if (step.Direction == Direction.Left)
            {
                var word = primary.Words[step.Left];
                var score = Score(primary.Engine, word.Confidence, calibration);
                if (score is null || score >= 0.65) words.Add(word with { Confidence = score });
            }
            else
            {
                var word = secondary.Words[step.Right];
                var score = Score(secondary.Engine, word.Confidence, calibration);
                if (score >= 0.75) words.Add(word with { Confidence = score });
            }
        }
        words.Sort((a, b) => a.StartMs != b.StartMs
            ? a.StartMs.CompareTo(b.StartMs)
            : a.EndMs.CompareTo(b.EndMs));
        var text = Segmentation.Normalize(string.Join(" ", words.Select(word => word.Text)));
        var requested = OrderedUnion(primary.Context.RequestedTerms, secondary.Context.RequestedTerms);
        var applied = VocabularyEvidence.AcousticallySupported(requested, words);
        return new EngineTranscript
        {
            Engine = "rover",
            Model = primary.Model + "+" + secondary.Model,
            Version = "1",
            Settings = new Dictionary<string, string>
            {
                ["alignment"] = "timestamped-word-dp",
                ["engines"] = primary.Engine + "," + secondary.Engine,
            },
            Text = text,
            Language = primary.Language ?? secondary.Language,
            AudioDurationMs = Math.Max(primary.AudioDurationMs, secondary.AudioDurationMs),
            ProcessingDurationMs = primary.ProcessingDurationMs + secondary.ProcessingDurationMs,
            Words = words,
            Segments = Segmentation.From(words.Select(word => new WordTiming(
                word.Text, word.StartMs / 1000.0, word.EndMs / 1000.0, word.Confidence)).ToList()),
            Diagnostics = new Dictionary<string, string> { ["hypotheses"] = "2" },
            Context = new EngineContextEvidence(
                requested,
                OrderedUnion(primary.Context.DetectedTerms, secondary.Context.DetectedTerms),
                applied),
        };
    }

    private static IEnumerable<Step> Align(IReadOnlyList<EngineWord> left, IReadOnlyList<EngineWord> right)
    {
        var cost = new int[left.Count + 1, right.Count + 1];
        for (var i = 0; i <= left.Count; i++) cost[i, 0] = i;
        for (var j = 0; j <= right.Count; j++) cost[0, j] = j;
        for (var i = 1; i <= left.Count; i++)
        for (var j = 1; j <= right.Count; j++)
        {
            var substitution = cost[i - 1, j - 1] + PairCost(left[i - 1], right[j - 1]);
            cost[i, j] = Math.Min(substitution, Math.Min(cost[i - 1, j] + 1, cost[i, j - 1] + 1));
        }

        var steps = new List<Step>();
        var x = left.Count;
        var y = right.Count;
        while (x > 0 || y > 0)
        {
            if (x > 0 && y > 0)
            {
                var substitution = PairCost(left[x - 1], right[y - 1]);
                if (substitution < 2 && cost[x, y] == cost[x - 1, y - 1] + substitution)
                {
                    steps.Add(new Step(Direction.Both, --x, --y));
                    continue;
                }
            }
            if (x > 0 && cost[x, y] == cost[x - 1, y] + 1)
                steps.Add(new Step(Direction.Left, --x, -1));
            else
                steps.Add(new Step(Direction.Right, -1, --y));
        }
        steps.Reverse();
        return steps;
    }

    private static double? Score(
        string engine,
        double? confidence,
        IReadOnlyDictionary<string, ConfidenceCalibration> calibration) =>
        calibration.TryGetValue(engine, out var curve) ? curve.Apply(confidence) : confidence;

    private static bool Same(string left, string right) => Normalize(left) == Normalize(right);
    private static int PairCost(EngineWord left, EngineWord right)
    {
        var centers = Math.Abs((left.StartMs + left.EndMs) / 2 - (right.StartMs + right.EndMs) / 2);
        var separated = left.EndMs + 500 < right.StartMs || right.EndMs + 500 < left.StartMs;
        if (centers > 1_500 && separated) return 2;
        return Same(left.Text, right.Text) ? 0 : 1;
    }
    private static string Normalize(string word) => new(word.ToLowerInvariant().Where(char.IsLetterOrDigit).ToArray());

    private static List<string> OrderedUnion(IEnumerable<string> first, IEnumerable<string> second)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        return first.Concat(second).Where(seen.Add).ToList();
    }
}

public static class EchoDedup
{
    private const int WindowMs = 1_500;

    public static List<Segment> DropMicEcho(IEnumerable<Segment> segments)
    {
        var all = segments.ToList();
        var system = all.Where(segment => segment.SourceTrack == "system").ToList();
        if (system.Count == 0) return all;
        return all.Where(mic =>
        {
            if (mic.SourceTrack != "mic" || mic.Words is null || mic.Words.Count < 3) return true;
            var nearby = system.Where(candidate =>
                candidate.EndMs + WindowMs >= mic.StartMs && candidate.StartMs - WindowMs <= mic.EndMs).ToList();
            var candidates = nearby.SelectMany(candidate => candidate.Words ?? []).ToList();
            var used = new HashSet<int>();
            var matches = 0;
            foreach (var word in mic.Words)
            {
                var index = -1;
                for (var candidateIndex = 0; candidateIndex < candidates.Count; candidateIndex++)
                {
                    var candidate = candidates[candidateIndex];
                    if (!used.Contains(candidateIndex)
                        && Math.Abs(candidate.StartMs - word.StartMs) <= WindowMs
                        && Same(candidate.Text, word.Text))
                    {
                        index = candidateIndex;
                        break;
                    }
                }
                if (index < 0) continue;
                used.Add(index);
                matches++;
            }
            var ratio = matches / (double)mic.Words.Count;
            var micConfidence = Mean(mic.Words.Select(word => word.Confidence)) ?? mic.Confidence ?? 0;
            var systemConfidence = Mean(used.Select(index => candidates[index].Confidence))
                ?? Mean(nearby.Select(segment => segment.Confidence)) ?? 0;
            return !(ratio >= 0.8 && systemConfidence >= micConfidence);
        }).ToList();
    }

    private static bool Same(string left, string right) => Normalize(left) == Normalize(right);
    private static string Normalize(string word) => new(word.ToLowerInvariant().Where(char.IsLetterOrDigit).ToArray());
    private static double? Mean(IEnumerable<double?> values)
    {
        var present = values.Where(value => value.HasValue).Select(value => value!.Value).ToList();
        return present.Count == 0 ? null : present.Average();
    }
}

public static class TranscriptCalibration
{
    public static EngineTranscript Apply(
        EngineTranscript transcript,
        IReadOnlyDictionary<string, ConfidenceCalibration> calibration)
    {
        if (!calibration.TryGetValue(transcript.Engine, out var curve)) return transcript;
        var diagnostics = transcript.Diagnostics.ToDictionary(pair => pair.Key, pair => pair.Value);
        diagnostics["confidence_calibration"] = "held-out-linear-v1";
        return transcript with
        {
            Words = transcript.Words.Select(word => word with { Confidence = curve.Apply(word.Confidence) }).ToList(),
            Segments = transcript.Segments.Select(segment => segment with
            {
                Confidence = curve.Apply(segment.Confidence),
                Words = segment.Words.Select(word => word with { Confidence = curve.Apply(word.Confidence) }).ToList(),
            }).ToList(),
            Diagnostics = diagnostics,
        };
    }
}
