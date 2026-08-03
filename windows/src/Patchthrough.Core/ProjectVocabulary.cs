using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Patchthrough.Core;

public static partial class ProjectVocabulary
{
    private const int MaximumTerms = 256;
    private static readonly string[] Manifests =
        ["package.json", "Package.swift", "Cargo.toml", "pyproject.toml", "requirements.txt", "go.mod", "Gemfile", "Podfile"];
    private static readonly HashSet<string> Ignored =
        new([".git", ".build", "build", "dist", "node_modules", "vendor", "Pods"], StringComparer.OrdinalIgnoreCase);

    public static IReadOnlyList<VocabularyTerm> Collect(string? projectRoot)
    {
        var terms = new Dictionary<string, VocabularyTerm>(StringComparer.OrdinalIgnoreCase);
        void Add(string text, string source, double weight)
        {
            var cleaned = text.Trim();
            if (terms.Count >= MaximumTerms || cleaned.Length is < 3 or > 64 || !cleaned.Any(char.IsLetter)) return;
            if (!terms.TryGetValue(cleaned, out var existing) || existing.Weight < weight)
                terms[cleaned] = new VocabularyTerm(cleaned, source, Math.Clamp(weight, 0, 2));
        }

        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        AddLines(Path.Combine(home, ".config", "patchthrough", "vocabulary.txt"), "personal_glossary", 2);
        if (projectRoot is null || !Directory.Exists(projectRoot)) return Sorted();
        AddLines(Path.Combine(projectRoot, ".patchthrough", "vocabulary.txt"), "project_glossary", 2);

        var glossary = Path.Combine(projectRoot, ".patchthrough", "vocabulary.json");
        try
        {
            var node = JsonNode.Parse(File.ReadAllText(glossary));
            var array = node as JsonArray ?? node?["terms"] as JsonArray;
            foreach (var value in array?.Select(item => item?.GetValue<string>()) ?? [])
                if (value is not null) Add(value, "project_glossary", 2);
        }
        catch (Exception error) when (error is IOException or JsonException) { }

        foreach (var manifest in Manifests)
        {
            var path = Path.Combine(projectRoot, manifest);
            if (!File.Exists(path) || new FileInfo(path).Length > 512_000) continue;
            foreach (Match match in IdentifierRegex().Matches(File.ReadAllText(path)))
                if (IsSpecialized(match.Value)) Add(match.Value, "manifest", 1.4);
        }

        var head = Path.Combine(projectRoot, ".git", "HEAD");
        if (File.Exists(head))
        {
            foreach (var part in File.ReadAllText(head).Split(new[] { '/', '-', '_' }, StringSplitOptions.RemoveEmptyEntries))
                Add(part, "branch", 0.8);
        }

        var count = 0;
        foreach (var path in Enumerate(projectRoot, 0))
        {
            if (++count > 400) break;
            var stem = Path.GetFileNameWithoutExtension(path);
            if (IsSpecialized(stem)) Add(stem, "filename", 0.8);
            if (!new[] { ".swift", ".cs", ".ts", ".tsx", ".js", ".jsx", ".rs", ".go", ".py" }
                .Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase)) continue;
            if (new FileInfo(path).Length > 128_000) continue;
            foreach (Match match in DeclarationRegex().Matches(File.ReadAllText(path)))
                Add(match.Groups[1].Value, "declaration", 1);
        }
        return Sorted();

        void AddLines(string path, string source, double weight)
        {
            if (!File.Exists(path)) return;
            foreach (var line in File.ReadLines(path).Where(line => !line.TrimStart().StartsWith('#')))
                Add(line, source, weight);
        }

        IReadOnlyList<VocabularyTerm> Sorted() => terms.Values
            .OrderByDescending(term => term.Weight).ThenBy(term => term.Text, StringComparer.OrdinalIgnoreCase)
            .Take(MaximumTerms).ToList();
    }

    private static IEnumerable<string> Enumerate(string directory, int depth)
    {
        if (depth > 3) yield break;
        IEnumerable<string> children;
        try { children = Directory.EnumerateFileSystemEntries(directory); }
        catch (UnauthorizedAccessException) { yield break; }
        foreach (var child in children)
        {
            if (Directory.Exists(child))
            {
                if (Ignored.Contains(Path.GetFileName(child))) continue;
                foreach (var nested in Enumerate(child, depth + 1)) yield return nested;
            }
            else yield return child;
        }
    }

    private static bool IsSpecialized(string term) =>
        term.Any(char.IsUpper) || term.Contains('-') || term.Contains('_') || term.Contains('.');

    [GeneratedRegex("[A-Za-z][A-Za-z0-9_.+\\-]{2,63}")]
    private static partial Regex IdentifierRegex();

    [GeneratedRegex("(?:class|struct|enum|protocol|interface|record|func|function)\\s+([A-Za-z][A-Za-z0-9_]{2,63})")]
    private static partial Regex DeclarationRegex();
}
