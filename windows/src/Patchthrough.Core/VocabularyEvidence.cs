namespace Patchthrough.Core;

public static class VocabularyEvidence
{
    public static IReadOnlyList<string> AcousticallySupported(
        IEnumerable<string> requested,
        IReadOnlyList<EngineWord> words,
        double minimumConfidence = 0.72)
    {
        var normalized = words.Select(word => Normalize(word.Text)).ToList();
        return requested.Where(term =>
        {
            var parts = term.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
                .Select(Normalize).Where(part => part.Length > 0).ToList();
            if (parts.Count == 0 || normalized.Count < parts.Count) return false;
            for (var start = 0; start <= normalized.Count - parts.Count; start++)
            {
                if (!normalized.Skip(start).Take(parts.Count).SequenceEqual(parts)) continue;
                var confidence = words.Skip(start).Take(parts.Count).Select(word => word.Confidence).ToList();
                if (confidence.All(value => value.HasValue)
                    && confidence.Average(value => value!.Value) >= minimumConfidence) return true;
            }
            return false;
        }).ToList();
    }

    private static string Normalize(string value) =>
        new(value.ToLowerInvariant().Where(char.IsLetterOrDigit).ToArray());
}
