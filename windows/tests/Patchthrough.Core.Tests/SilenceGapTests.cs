using Patchthrough.Core;

namespace Patchthrough.Core.Tests;

/// <summary>
/// The silence padding decides whether the two tracks of a meeting stay on one
/// clock. A wrong answer here does not crash: it produces a transcript whose
/// timestamps drift for the rest of the recording, which is far harder to
/// notice. So these tests pin the arithmetic.
///
/// The format below is 48 kHz stereo 32-bit float, which is what a WASAPI
/// endpoint usually hands over: 384000 bytes per second, 8 bytes per frame.
/// </summary>
public sealed class SilenceGapTests
{
    private const int BytesPerSecond = 384_000;
    private const int BlockAlign = 8;

    private static long Missing(double elapsedSeconds, long bytesWritten) =>
        SilenceGap.MissingBytes(elapsedSeconds, bytesWritten, BytesPerSecond, BlockAlign);

    [Fact]
    public void ContinuousAudioNeedsNoPadding()
    {
        // Two seconds elapsed, two seconds written.
        Assert.Equal(0, Missing(2.0, 2 * BytesPerSecond));
    }

    [Fact]
    public void NormalJitterNeverInterruptsContinuousAudio()
    {
        // A callback that lands 50 ms late must not push silence into the middle
        // of speech. The tolerance is one tenth of a second.
        Assert.Equal(0, Missing(2.05, 2 * BytesPerSecond));
        Assert.Equal(0, Missing(2.09, 2 * BytesPerSecond));
    }

    [Fact]
    public void ASilentGapIsPaddedToTheWallClock()
    {
        // Nothing played for three seconds after the first second of audio, so
        // WASAPI delivered nothing at all in that window.
        Assert.Equal(3 * BytesPerSecond, Missing(4.0, 1 * BytesPerSecond));
    }

    [Fact]
    public void PaddingIsAlwaysAWholeNumberOfFrames()
    {
        // 0.5001 s of a 384000 byte-per-second stream is 192038.4 bytes, and a
        // partial frame would shift every later sample and ruin the track.
        var missing = Missing(0.5001, 0);
        Assert.Equal(0, missing % BlockAlign);
        Assert.Equal(192_032, missing);
    }

    [Fact]
    public void ATrackThatIsAheadOfTheClockIsLeftAlone()
    {
        // The device delivered more than the wall clock accounts for. Trimming
        // is not this function's job, and a negative count must never reach the
        // writer as a length.
        Assert.Equal(0, Missing(1.0, 2 * BytesPerSecond));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    public void NoTimeHasPassedSoNothingIsMissing(double elapsed) => Assert.Equal(0, Missing(elapsed, 0));

    [Fact]
    public void AnUnusableFormatYieldsNoPaddingRatherThanADivideByZero()
    {
        Assert.Equal(0, SilenceGap.MissingBytes(5, 0, averageBytesPerSecond: 0, blockAlign: 8));
        Assert.Equal(0, SilenceGap.MissingBytes(5, 0, averageBytesPerSecond: BytesPerSecond, blockAlign: 0));
    }

    [Fact]
    public void ALongMeetingStaysExactPastTheRangeOfAnInt()
    {
        // The count has to be long arithmetic. Two hours of this format is
        // 2.76 GB, which overflows a 32-bit count.
        var twoHours = Missing(7200, 0);
        Assert.Equal(7200L * BytesPerSecond, twoHours);
        Assert.True(twoHours > int.MaxValue, "the byte count must not be 32-bit");
    }
}
