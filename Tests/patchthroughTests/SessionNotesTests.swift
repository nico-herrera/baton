import Foundation
import Testing
@testable import patchthrough

/// A scratch session directory. Never `~/Recordings` — that is user data.
private func scratchSession(
    audioStart: String? = "2026-08-06T15:00:00.000Z",
    started: String = "2026-08-06T14:59:58Z"
) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("patchthrough-notes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    var meta = #"{"started":"\#(started)","clean_stop":true,"duration_seconds":600"#
    if let audioStart { meta += #","audio_start":"\#(audioStart)""# }
    meta += "}"
    try Data(meta.utf8).write(to: dir.appendingPathComponent("meta.json"))
    return dir
}

private func writeNotes(_ json: String, to dir: URL) throws {
    try Data(json.utf8).write(to: dir.appendingPathComponent("notes.json"))
}

@Test func notesResolveAgainstTheAudioClockNotTheSessionStart() throws {
    let dir = try scratchSession()
    defer { try? FileManager.default.removeItem(at: dir) }

    // audio_start is 15:00:00.000. A note at 15:02:14.500 is 134.5s in.
    // `started` is two seconds earlier; resolving against it would report
    // 136500 and land the note on the wrong line.
    try writeNotes(#"""
    {"schema_version":1,"notes":[
      {"at":"2026-08-06T15:02:14.500Z","text":"installer before the recorder"}
    ]}
    """#, to: dir)

    let resolved = SessionNotes.resolved(in: dir)
    #expect(resolved.count == 1)
    #expect(resolved.first?.offsetMs == 134_500)
    #expect(resolved.first?.text == "installer before the recorder")
}

@Test func aNoteTypedBeforeTheFirstAudioBufferClampsToZero() throws {
    let dir = try scratchSession()
    defer { try? FileManager.default.removeItem(at: dir) }

    // The window is live before the audio devices finish opening, so this is
    // reachable in normal use, not a corrupt file.
    try writeNotes(#"""
    {"schema_version":1,"notes":[
      {"at":"2026-08-06T14:59:59.000Z","text":"typed while the tap was still opening"}
    ]}
    """#, to: dir)

    #expect(SessionNotes.resolved(in: dir).first?.offsetMs == 0)
}

@Test func sessionsWithoutAudioStartFallBackToTheSessionStart() throws {
    let dir = try scratchSession(audioStart: nil)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Every session recorded before audio_start existed. Early by the device
    // startup latency, which is the documented cost of the fallback.
    try writeNotes(#"""
    {"schema_version":1,"notes":[
      {"at":"2026-08-06T15:00:08.000Z","text":"older session"}
    ]}
    """#, to: dir)

    #expect(SessionNotes.resolved(in: dir).first?.offsetMs == 10_000)
}

@Test func notesWithNoAnchorRenderWithoutATimestampRatherThanAtZero() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("patchthrough-notes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // No meta.json at all. A note claiming 0:00 would point an agent at the
    // opening line of a meeting it has nothing to do with.
    try writeNotes(#"""
    {"schema_version":1,"notes":[{"at":"2026-08-06T15:00:08.000Z","text":"unanchored"}]}
    """#, to: dir)

    let resolved = SessionNotes.resolved(in: dir)
    #expect(resolved.count == 1)
    #expect(resolved.first?.offsetMs == nil)
    #expect(resolved.first?.text == "unanchored")
}

@Test func notesAreOrderedByPositionInTheRecording() throws {
    let dir = try scratchSession()
    defer { try? FileManager.default.removeItem(at: dir) }

    try writeNotes(#"""
    {"schema_version":1,"notes":[
      {"at":"2026-08-06T15:05:00.000Z","text":"second"},
      {"at":"2026-08-06T15:01:00.000Z","text":"first"}
    ]}
    """#, to: dir)

    #expect(SessionNotes.resolved(in: dir).map(\.text) == ["first", "second"])
}

@Test func anAbsentOrUnreadableNotesFileYieldsNothingInsteadOfThrowing() throws {
    let dir = try scratchSession()
    defer { try? FileManager.default.removeItem(at: dir) }

    // Absent is the normal state for most sessions.
    #expect(SessionNotes.read(from: dir) == nil)
    #expect(SessionNotes.resolved(in: dir).isEmpty)

    // Corrupt must degrade the same way. Losing the handoff because a side file
    // got truncated would be a worse failure than losing the notes.
    try writeNotes("{ this is not json", to: dir)
    #expect(SessionNotes.read(from: dir) == nil)
    #expect(SessionNotes.resolved(in: dir).isEmpty)
}

@MainActor
@Test func appendPreservesMillisecondsThroughARoundTrip() throws {
    let dir = try scratchSession()
    defer { try? FileManager.default.removeItem(at: dir) }

    let anchor = ISO8601DateFormatter().date(from: "2026-08-06T15:00:00Z")!
    try SessionNotes.append("first", at: anchor.addingTimeInterval(12.345), to: dir)
    try SessionNotes.append("second", at: anchor.addingTimeInterval(30.500), to: dir)

    // Second-precision serialization would collapse these to 12000 and 30000.
    #expect(SessionNotes.resolved(in: dir).map(\.offsetMs) == [12_345, 30_500])

    // Appending is read-modify-write, so the first note has to survive.
    #expect(SessionNotes.read(from: dir)?.notes.count == 2)
}

@MainActor
@Test func appendIgnoresWhitespaceOnlyNotesAndTrimsTheRest() throws {
    let dir = try scratchSession()
    defer { try? FileManager.default.removeItem(at: dir) }

    try SessionNotes.append("   \n  ", to: dir)
    #expect(SessionNotes.read(from: dir) == nil)

    try SessionNotes.append("  needs trimming  ", to: dir)
    #expect(SessionNotes.read(from: dir)?.notes.first?.text == "needs trimming")
}

@Test func sharedNotesFixtureDecodes() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("patchthrough-notes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let fixture = try Data(contentsOf: root.appendingPathComponent("schemas/fixtures/notes-v1.json"))
    try fixture.write(to: dir.appendingPathComponent("notes.json"))

    let notes = try #require(SessionNotes.read(from: dir))
    #expect(notes.notes.count == 2)
    #expect(notes.notes.first?.text == "he wants the installer before the recorder")
}

/// A recording with no speech in it transcribes fine and produces a transcript
/// with zero segments. That is finished work. It used to read as `.pending`,
/// whose subtitle is "Transcribing…", so a completed session sat there
/// indefinitely with nothing running behind it.
@MainActor
@Test func aRecordingWithNoSpeechReadsAsEmptyRatherThanForeverTranscribing() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("patchthrough-empty-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let silent = root.appendingPathComponent("2026.08.07-1000", isDirectory: true)
    try FileManager.default.createDirectory(at: silent, withIntermediateDirectories: true)
    try Data(#"{"clean_stop":true,"duration_seconds":42}"#.utf8)
        .write(to: silent.appendingPathComponent("meta.json"))
    // What the pipeline actually writes for a silent recording: the header, and
    // not one `**[` segment line.
    try Data("# 2026.08.07-1000\n\nengine: parakeet (test)\n".utf8)
        .write(to: silent.appendingPathComponent("transcript.md"))
    try Data(#"{"schema_version":2,"segments":[]}"#.utf8)
        .write(to: silent.appendingPathComponent("transcript.json"))

    // Same shape minus the completion marker: this one really is still queued.
    let queued = root.appendingPathComponent("2026.08.07-0900", isDirectory: true)
    try FileManager.default.createDirectory(at: queued, withIntermediateDirectories: true)
    try Data(#"{"clean_stop":true,"duration_seconds":42}"#.utf8)
        .write(to: queued.appendingPathComponent("meta.json"))

    let store = SessionStore(root: root)
    store.refresh()

    #expect(store.items.first { $0.id == "2026.08.07-1000" }?.status == .empty)
    #expect(store.items.first { $0.id == "2026.08.07-1000" }?.subtitle == "No speech found")
    // The distinction is transcript.json, so a genuinely queued session must
    // still report as pending.
    #expect(store.items.first { $0.id == "2026.08.07-0900" }?.status == .pending)
}
