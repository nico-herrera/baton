using NAudio.Wave;
using Patchthrough.Core;

namespace Patchthrough.Windows.Audio;

/// <summary>
/// Captures one WASAPI source to a WAV file at the device format. Converting
/// happens later, so the capture callback stays as short as possible.
///
/// The important part is the silence padding. WASAPI loopback delivers no
/// buffer at all while nothing plays, so a recorder that writes only the
/// buffers it receives produces a system track shorter than the microphone
/// track. Every timestamp after the first silence is then wrong, and the two
/// tracks drift apart for the rest of the meeting. This class measures the gap
/// against the wall clock and writes the missing silence.
/// </summary>
public sealed class TrackRecorder : IDisposable
{
    private readonly IWaveIn _capture;
    private readonly Func<DateTimeOffset> _clock;
    private readonly object _gate = new();

    private WaveFileWriter? _writer;
    private DateTimeOffset? _firstBufferAt;
    private long _bytesWritten;

    /// <summary>When the first buffer arrived, for the session start offset.</summary>
    public DateTimeOffset? FirstBufferAt
    {
        get { lock (_gate) return _firstBufferAt; }
    }

    public string? Path { get; private set; }

    public Exception? Failure { get; private set; }

    public TrackRecorder(IWaveIn capture, Func<DateTimeOffset>? clock = null)
    {
        _capture = capture;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
        _capture.DataAvailable += OnDataAvailable;
        _capture.RecordingStopped += OnRecordingStopped;
    }

    public void Start(string path)
    {
        Path = path;
        _writer = new WaveFileWriter(path, _capture.WaveFormat);
        _capture.StartRecording();
    }

    public void Stop()
    {
        _capture.StopRecording();
        lock (_gate)
        {
            // Pad the tail too. A meeting that ends in silence otherwise leaves
            // a track shorter than the recording, and the duration in meta.json
            // stops matching the audio.
            PadTo(_clock(), _writer);
            _writer?.Flush();
            _writer?.Dispose();
            _writer = null;
        }
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        lock (_gate)
        {
            if (_writer is null) return;
            var now = _clock();
            if (_firstBufferAt is null)
            {
                _firstBufferAt = now;
            }
            else
            {
                PadTo(now, _writer);
            }
            _writer.Write(e.Buffer, 0, e.BytesRecorded);
            _bytesWritten += e.BytesRecorded;
        }
    }

    private void OnRecordingStopped(object? sender, StoppedEventArgs e) => Failure ??= e.Exception;

    /// <summary>
    /// Write silence up to where the wall clock says this track should be.
    /// Called with the lock held.
    /// </summary>
    private void PadTo(DateTimeOffset now, WaveFileWriter? writer)
    {
        if (writer is null || _firstBufferAt is null) return;

        var missing = SilenceGap.MissingBytes(
            (now - _firstBufferAt.Value).TotalSeconds,
            _bytesWritten,
            _capture.WaveFormat.AverageBytesPerSecond,
            _capture.WaveFormat.BlockAlign);
        if (missing <= 0) return;

        var silence = new byte[Math.Min(missing, 64 * 1024)];
        for (var remaining = missing; remaining > 0;)
        {
            var chunk = (int)Math.Min(remaining, silence.Length);
            writer.Write(silence, 0, chunk);
            remaining -= chunk;
        }
        _bytesWritten += missing;
    }

    public void Dispose()
    {
        _capture.DataAvailable -= OnDataAvailable;
        _capture.RecordingStopped -= OnRecordingStopped;
        _writer?.Dispose();
        _capture.Dispose();
    }
}
