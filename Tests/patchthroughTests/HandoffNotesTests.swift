import Foundation
import Testing
@testable import patchthrough

/// A scratch recordings root holding one transcribed session.
private func scratchRoot(notes: String? = nil) throws -> (root: URL, name: String) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("patchthrough-handoff-\(UUID().uuidString)", isDirectory: true)
    let name = "2026.08.06-1500"
    let dir = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    try Data(#"""
    {"started":"2026-08-06T14:59:58Z","audio_start":"2026-08-06T15:00:00.000Z",
     "clean_stop":true,"duration_seconds":600}
    """#.utf8).write(to: dir.appendingPathComponent("meta.json"))

    try Data("""
    # \(name)

    engine: fixture (test)

    **[0:01] me:** morning

    **[2:14] them:** we need the installer before the recorder

    """.utf8).write(to: dir.appendingPathComponent("transcript.md"))

    if let notes {
        try Data(notes.utf8).write(to: dir.appendingPathComponent("notes.json"))
    }
    return (root, name)
}

@Test func aSessionWithoutNotesRendersNoNotesSectionAtAll() throws {
    let (root, name) = try scratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let document = Handoff.handoffDocument(for: try Handoff.resolveSession(named: name, root: root))

    // Absent must produce nothing — no heading, no blank line, no mention in
    // the instructions. This is the same rule the disclosure line follows.
    #expect(!document.contains("## Notes"))
    #expect(!document.contains("notes"))
    // The section the notes would have displaced still butts straight up
    // against the Recording block, exactly as it did before notes existed.
    #expect(document.contains("- Source: `\(root.appendingPathComponent(name).path)`\n\n## Transcript"))
}

@Test func notesRenderAboveTheTranscriptWithTranscriptClockTimestamps() throws {
    let (root, name) = try scratchRoot(notes: #"""
    {"schema_version":1,"notes":[
      {"at":"2026-08-06T15:02:14.500Z","text":"installer before the recorder"},
      {"at":"2026-08-06T15:00:01.000Z","text":"he sounds annoyed about the delay"}
    ]}
    """#)
    defer { try? FileManager.default.removeItem(at: root) }

    let document = Handoff.handoffDocument(for: try Handoff.resolveSession(named: name, root: root))

    // Ordered by position in the recording, not by the order they were typed.
    let notesBlock = try #require(document.range(of: "## Notes"))
    let transcriptBlock = try #require(document.range(of: "## Transcript"))
    #expect(notesBlock.lowerBound < transcriptBlock.lowerBound)

    #expect(document.contains("- **[0:01]** he sounds annoyed about the delay"))
    #expect(document.contains("- **[2:14]** installer before the recorder"))

    // The note's label has to match the transcript line it points at, or the
    // agent is sent to a line that is close but wrong.
    #expect(document.contains("**[2:14] them:** we need the installer before the recorder"))

    // The instructions only mention notes when notes exist.
    #expect(document.contains("Prioritize by the notes"))
}

@Test func anUnanchoredNoteKeepsItsTextAndDropsItsTimestamp() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("patchthrough-handoff-\(UUID().uuidString)", isDirectory: true)
    let name = "2026.08.06-1500"
    let dir = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // No meta.json, so nothing to subtract. resolveSession tolerates this.
    try Data("**[0:01] me:** morning\n".utf8)
        .write(to: dir.appendingPathComponent("transcript.md"))
    try Data(#"""
    {"schema_version":1,"notes":[{"at":"2026-08-06T15:00:08.000Z","text":"no anchor here"}]}
    """#.utf8).write(to: dir.appendingPathComponent("notes.json"))

    let document = Handoff.handoffDocument(for: try Handoff.resolveSession(named: name, root: root))
    #expect(document.contains("- no anchor here"))
    #expect(!document.contains("[0:00]** no anchor here"))
}

@Test func transcriptClockMatchesTheTranscriptRenderingAcrossTheHourBoundary() {
    #expect(TranscriptClock.label(0) == "0:00")
    #expect(TranscriptClock.label(1_000) == "0:01")
    #expect(TranscriptClock.label(134_500) == "2:14")
    // Truncates rather than rounding: 2:14.9 is still 2:14, because the audio
    // has not reached 2:15 yet.
    #expect(TranscriptClock.label(134_999) == "2:14")
    #expect(TranscriptClock.label(3_600_000) == "1:00:00")
    #expect(TranscriptClock.label(3_754_000) == "1:02:34")
    #expect(TranscriptClock.label(-5) == "0:00")
}
