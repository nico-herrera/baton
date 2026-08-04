using System.Globalization;

namespace Patchthrough.Core;

/// <summary>
/// The self-contained handoff document, `handoff.md`. It holds the
/// instructions, the recording context, and the verbatim transcript, so a
/// dragged or attached file tells the receiving agent what to do with it.
/// This mirrors Handoff.handoffDocument in Handoff.swift.
/// </summary>
public static class HandoffDocument
{
    /// <summary>
    /// One wording of the speech-to-text caveat, shared by every prompt. The
    /// macOS app carries it in Handoff.swift (`asrCaveat`) and the CLI carries
    /// it in cli/src/patchthrough.js (`ASR_CAVEAT`). These three strings are
    /// the handoff contract in prose: keep them in step.
    /// </summary>
    public const string AsrCaveat =
        "It's speech-to-text, so it's messy: unreliable punctuation, garbled "
        + "technical terms, and 'me'/'them' labels that can be wrong. Read for "
        + "intent, not literal wording.";

    /// <summary>
    /// Instructions that travel inside every handoff document. Keep in step
    /// with `taskInstructions` in Handoff.swift and in the CLI.
    /// </summary>
    public static string TaskInstructions =>
        "Read the transcript below and work out what this meeting asks of me. "
        + "Before changing anything, give me:\n"
        + "\n"
        + "1. Concrete work items it implies, ordered by what should happen first.\n"
        + "2. Anything stated as a decision or constraint I shouldn't relitigate.\n"
        + "3. Anything ambiguous or contradictory, and anything that reads like a transcription error. Ask me rather than guess.\n"
        + "4. Anything discussed that the current project may already do or contradict.\n"
        + "\n"
        + AsrCaveat + " Don't edit anything until we've agreed the list.";

    /// <summary>
    /// Build the document. `transcriptMarkdown` is the content of
    /// transcript.md, whose own title and engine lines get dropped: this
    /// document writes its own header.
    /// </summary>
    public static string Build(
        string sessionDirectory,
        string transcriptMarkdown,
        int durationSeconds,
        bool cleanStop,
        string? name)
    {
        var displayName = string.IsNullOrWhiteSpace(name)
            ? new DirectoryInfo(sessionDirectory).Name
            : name;

        var body = string.Join("\n", transcriptMarkdown
            .Split('\n')
            .Select(line => line.TrimEnd('\r'))
            .SkipWhile(line => !line.StartsWith("**[", StringComparison.Ordinal)));

        var truncation = cleanStop
            ? ""
            : " (recording ended uncleanly, so the transcript may be truncated)";

        // "the audio this machine played" rather than "the audio the Mac
        // played". The macOS copies name the Mac, which is false on Windows.
        // The sentence defines what the speaker labels mean, so it has to be
        // true on the machine that wrote the file.
        var document = $"""
        # Meeting handoff: {displayName}

        ## Instructions

        {TaskInstructions}

        ## Recording

        - Duration: {Duration(durationSeconds)}{truncation}
        - Speakers: `me` is this machine's microphone. `them` is the audio this machine played, which is the other side of the call. These are channels, not verified identities: echo can put the wrong label on a line.
        - Transcribed on-device. **Expect transcription errors**, especially in proper nouns, identifiers and technical terms. If a term looks wrong but is phonetically close to something plausible, it probably is that.
        - Source: `{sessionDirectory}`

        ## Transcript

        {body}
        """;
        // Raw multiline strings follow the checkout line endings. Git commonly
        // checks this file out as CRLF on Windows, but handoff.md is a shared
        // byte-level contract with the macOS app and npm CLI, so pin LF here.
        return document.Replace("\r\n", "\n", StringComparison.Ordinal);
    }

    public static void Write(
        string sessionDirectory,
        int durationSeconds,
        bool cleanStop,
        string? name)
    {
        var transcript = File.ReadAllText(Path.Combine(sessionDirectory, "transcript.md"));
        var document = Build(sessionDirectory, transcript, durationSeconds, cleanStop, name);
        AtomicFile.WriteText(Path.Combine(sessionDirectory, "handoff.md"), document);
    }

    /// <summary>
    /// `1m32s`. Minutes are not wrapped into hours, which is what the macOS app
    /// puts in this document.
    /// </summary>
    public static string Duration(int seconds) =>
        string.Format(CultureInfo.InvariantCulture, "{0}m{1:00}s", seconds / 60, seconds % 60);
}
