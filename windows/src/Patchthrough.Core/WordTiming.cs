using System.Text.RegularExpressions;

namespace Patchthrough.Core;

/// <summary>One word and its engine-native confidence on the source clock.</summary>
public sealed record WordTiming(string Word, double Start, double End, double? Confidence = null);

public static class Segmentation
{
    public const double GapSeconds = 0.8;
    public const double MaxDurationSeconds = 30;
    public const double ConfidenceChange = 0.35;

    public static List<EngineSegment> From(IReadOnlyList<WordTiming> words)
    {
        var output = new List<EngineSegment>();
        var current = new List<WordTiming>();

        void Flush()
        {
            if (current.Count == 0) return;
            var scores = current.Where(w => w.Confidence.HasValue).Select(w => w.Confidence!.Value).ToList();
            output.Add(new EngineSegment(
                (int)(current[0].Start * 1000),
                (int)(current[^1].End * 1000),
                Normalize(string.Join(" ", current.Select(w => w.Word))),
                scores.Count == 0 ? null : scores.Average(),
                current.Select(w => new EngineWord(
                    w.Word,
                    (int)(w.Start * 1000),
                    (int)(w.End * 1000),
                    w.Confidence)).ToList()));
            current.Clear();
        }

        foreach (var word in words.Where(w => !string.IsNullOrWhiteSpace(w.Word)))
        {
            if (current.Count > 0)
            {
                var last = current[^1];
                var confidenceShift = current.Count >= 4
                    && last.Confidence.HasValue && word.Confidence.HasValue
                    && Math.Abs(last.Confidence.Value - word.Confidence.Value) >= ConfidenceChange;
                if (word.Start - last.End > GapSeconds
                    || word.End - current[0].Start > MaxDurationSeconds
                    || confidenceShift) Flush();
            }
            current.Add(word);
            if (word.Word.EndsWith('.') || word.Word.EndsWith('?') || word.Word.EndsWith('!')) Flush();
        }
        Flush();
        return output;
    }

    public static List<WordTiming> WordsFromTokens(
        IReadOnlyList<string> tokens,
        IReadOnlyList<float> startSeconds,
        IReadOnlyList<float>? durations = null,
        IReadOnlyList<float>? confidences = null)
    {
        var words = new List<WordTiming>();
        var text = new System.Text.StringBuilder();
        var wordScores = new List<double>();
        double start = 0, end = 0;

        void Flush()
        {
            if (text.Length == 0) return;
            words.Add(new WordTiming(
                text.ToString(), start, end,
                wordScores.Count == 0 ? null : wordScores.Average()));
            text.Clear();
            wordScores.Clear();
        }

        for (var i = 0; i < tokens.Count && i < startSeconds.Count; i++)
        {
            var token = tokens[i];
            var tokenStart = startSeconds[i];
            var tokenEnd = durations is not null && i < durations.Count
                ? tokenStart + durations[i]
                : i + 1 < startSeconds.Count ? startSeconds[i + 1] : tokenStart;

            var startsWord = token.StartsWith('▁') || token.StartsWith(' ');
            if (startsWord)
            {
                Flush();
                start = tokenStart;
                text.Append(token.TrimStart('▁', ' '));
            }
            else
            {
                if (text.Length == 0) start = tokenStart;
                text.Append(token);
            }
            if (confidences is not null && i < confidences.Count)
                wordScores.Add(Math.Clamp(confidences[i], 0, 1));
            end = Math.Max(tokenEnd, tokenStart);
        }
        Flush();
        return words.Where(w => w.Word.Length > 0).ToList();
    }

    public static string Normalize(string text)
    {
        var clean = string.Join(" ", text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        clean = Regex.Replace(clean, "\\s+([,.;:!?])", "$1", RegexOptions.CultureInvariant);
        clean = Regex.Replace(clean, "([\\[(])\\s+", "$1", RegexOptions.CultureInvariant);
        clean = Regex.Replace(clean, "\\s+\\)", ")", RegexOptions.CultureInvariant);
        return Regex.Replace(clean, "\\s+\\]", "]", RegexOptions.CultureInvariant);
    }
}
