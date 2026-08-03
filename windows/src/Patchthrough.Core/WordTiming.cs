namespace Patchthrough.Core;

/// <summary>One word and when it was said, in seconds from the file start.</summary>
public sealed record WordTiming(string Word, double Start, double End);

/// <summary>
/// Groups timed words into readable segments. This is a port of
/// `segments(from:)` in ParakeetEngine.swift, so a Windows transcript breaks
/// its lines the same way a macOS one does.
/// </summary>
public static class Segmentation
{
    /// <summary>A silence this long ends a segment.</summary>
    public const double GapSeconds = 1.0;

    /// <summary>A hard cap, so a speaker who never pauses still wraps.</summary>
    public const int MaxWords = 60;

    public static List<Segment> From(IReadOnlyList<WordTiming> words)
    {
        var output = new List<Segment>();
        var current = new List<WordTiming>();

        void Flush()
        {
            if (current.Count == 0) return;
            output.Add(new Segment(
                "",
                (int)(current[0].Start * 1000),
                (int)(current[^1].End * 1000),
                string.Join(" ", current.Select(w => w.Word))));
            current.Clear();
        }

        foreach (var word in words)
        {
            // A gap ends the previous segment before this word joins one.
            if (current.Count > 0 && word.Start - current[^1].End > GapSeconds) Flush();
            current.Add(word);

            // Parakeet emits punctuation, so a sentence end is a real boundary.
            var endsSentence = word.Word.EndsWith('.') || word.Word.EndsWith('?') || word.Word.EndsWith('!');
            if (endsSentence || current.Count >= MaxWords) Flush();
        }
        Flush();
        return output;
    }

    /// <summary>
    /// Rebuild words from the sub-word tokens a transducer emits. Sentencepiece
    /// marks the start of a word with U+2581, so a token carrying that mark
    /// opens a new word and the rest attach to the current one.
    /// </summary>
    public static List<WordTiming> WordsFromTokens(
        IReadOnlyList<string> tokens,
        IReadOnlyList<float> startSeconds,
        IReadOnlyList<float>? durations = null)
    {
        var words = new List<WordTiming>();
        var text = new System.Text.StringBuilder();
        double start = 0, end = 0;

        void Flush()
        {
            if (text.Length == 0) return;
            words.Add(new WordTiming(text.ToString(), start, end));
            text.Clear();
        }

        for (var i = 0; i < tokens.Count && i < startSeconds.Count; i++)
        {
            var token = tokens[i];
            var tokenStart = startSeconds[i];
            // Without durations, a token ends where the next one starts. The
            // last token falls back to its own start.
            var tokenEnd = durations is not null && i < durations.Count
                ? tokenStart + durations[i]
                : i + 1 < startSeconds.Count ? startSeconds[i + 1] : tokenStart;

            if (token.StartsWith('▁'))
            {
                Flush();
                start = tokenStart;
                text.Append(token.AsSpan(1));
            }
            else
            {
                if (text.Length == 0) start = tokenStart;
                text.Append(token);
            }
            end = Math.Max(tokenEnd, tokenStart);
        }
        Flush();
        return words.Where(w => w.Word.Length > 0).ToList();
    }
}
