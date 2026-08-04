namespace Patchthrough.Core;

/// <summary>
/// Every session file is written through here. A reader can arrive at any
/// moment, and `transcript.json` is the completion marker that decides whether
/// a session gets transcribed again, so a half-written file is worse than no
/// file. Write a sibling temporary file, then move it into place.
/// </summary>
public static class AtomicFile
{
    public static void WriteText(string path, string contents)
    {
        var directory = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);

        // The temporary file sits next to the target, because a move across
        // volumes is a copy and stops being atomic.
        var temporary = path + ".tmp";
        // UTF-8 with no byte order mark. The macOS app writes plain UTF-8, and
        // a mark would reach the first line of transcript.md.
        File.WriteAllText(temporary, contents, new System.Text.UTF8Encoding(false));
        File.Move(temporary, path, overwrite: true);
    }
}
