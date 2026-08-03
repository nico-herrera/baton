namespace Patchthrough.Core;

/// <summary>
/// How much silence a captured track is missing. This is arithmetic on purpose,
/// separate from the capture plumbing, because it is the part that goes wrong
/// and the part worth testing.
///
/// WASAPI loopback delivers no buffer at all while nothing plays. A recorder
/// that writes only the buffers it receives ends up with a system track shorter
/// than the microphone track, and then every timestamp after the first silence
/// is wrong for the rest of the meeting.
/// </summary>
public static class SilenceGap
{
    /// <summary>
    /// Bytes of silence to insert before the next buffer, so the track matches
    /// the wall clock. Always a whole number of frames.
    /// </summary>
    /// <param name="elapsedSeconds">Since the first buffer of this track.</param>
    /// <param name="bytesWritten">Audio and padding already written.</param>
    /// <param name="averageBytesPerSecond">From the capture format.</param>
    /// <param name="blockAlign">Bytes per frame, from the capture format.</param>
    public static long MissingBytes(
        double elapsedSeconds,
        long bytesWritten,
        int averageBytesPerSecond,
        int blockAlign)
    {
        if (elapsedSeconds <= 0 || averageBytesPerSecond <= 0 || blockAlign <= 0) return 0;

        var expected = (long)(elapsedSeconds * averageBytesPerSecond);
        var missing = expected - bytesWritten;

        // One tenth of a second of tolerance. Normal callback jitter must not
        // insert silence into the middle of continuous audio: only a real gap
        // in playback exceeds this.
        if (missing <= averageBytesPerSecond / 10) return 0;

        // Whole frames only. A partial frame shifts every later sample by a
        // byte and turns the rest of the track into noise.
        return missing - missing % blockAlign;
    }
}
