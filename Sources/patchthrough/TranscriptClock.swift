import Foundation

/// The one place a millisecond offset becomes a `[m:ss]` label.
///
/// Two documents print this format: `transcript.md`, for every spoken segment,
/// and the notes block in `handoff.md`. They have to agree exactly. A note that
/// says `[2:14]` is an instruction to go and read the line the transcript
/// labels `[2:14]`, so a second renderer that rounded instead of truncating, or
/// dropped the hour once a meeting ran long, would send the reader to a line
/// that is nearby but wrong — the hardest kind of error to notice.
enum TranscriptClock {
    /// `m:ss`, or `h:mm:ss` once a recording passes an hour. Truncates rather
    /// than rounds, so a label never claims a second the audio has not reached.
    static func label(_ ms: Int) -> String {
        let total = max(0, ms) / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
