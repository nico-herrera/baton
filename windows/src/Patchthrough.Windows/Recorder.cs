using NAudio.CoreAudioApi;
using NAudio.Wave;
using Patchthrough.Core;
using Patchthrough.Windows.Audio;

namespace Patchthrough.Windows;

/// <summary>
/// One meeting: the microphone and everything the machine plays, as two
/// independent tracks. Two tracks are deliberate. Speech models do better on
/// clean single-source audio, and two tracks give two-party diarization with no
/// speaker-identification model.
/// </summary>
public sealed class Recorder : IDisposable
{
    private readonly SessionWriter _session;
    private readonly TrackRecorder _mic;
    private readonly TrackRecorder _system;
    private bool _stopped;

    public string Directory => _session.Directory;

    public Recorder(string recordingsRoot)
    {
        _session = SessionWriter.Create(recordingsRoot);
        // The default devices. A device that changes mid-meeting ends its
        // stream, which Doctor reports and a later milestone handles.
        _mic = new TrackRecorder(new WasapiCapture());
        _system = new TrackRecorder(new WasapiLoopbackCapture());
    }

    /// <summary>
    /// Start both tracks. If the microphone fails after the loopback started,
    /// the loopback is stopped too: half a session recorded silently is worse
    /// than a clear failure.
    /// </summary>
    public void Start()
    {
        _system.Start(_session.PathFor("system.wav"));
        try
        {
            _mic.Start(_session.PathFor("mic.wav"));
        }
        catch
        {
            _system.Stop();
            throw;
        }

        // Register the tracks and write meta.json before any audio arrives. The
        // pipeline treats meta.json as the marker of a session worth picking
        // up, so without this file a crash orphans the audio forever.
        _session.AddTrack("mic", "mic.wav");
        _session.AddTrack("system", "system.wav");
        _session.WriteProvisionalMeta();
    }

    /// <summary>
    /// Stop both tracks, encode them, and write the final meta.json with the
    /// offsets. The offsets are what put both tracks on one clock.
    /// </summary>
    public void Stop(string? name = null)
    {
        if (_stopped) return;
        _stopped = true;

        _mic.Stop();
        _system.Stop();
        Report(_mic, "mic");
        Report(_system, "system");

        // The earliest first buffer is time zero for the session.
        var micStart = _mic.FirstBufferAt ?? _session.StartedAt;
        var systemStart = _system.FirstBufferAt ?? _session.StartedAt;
        var earliest = micStart < systemStart ? micStart : systemStart;

        _session.AddTrack("mic", Encode(_mic), Offset(micStart, earliest));
        _session.AddTrack("system", Encode(_system), Offset(systemStart, earliest));
        _session.WriteFinalMeta(name: name);
    }

    private static int Offset(DateTimeOffset track, DateTimeOffset earliest) =>
        (int)(track - earliest).TotalMilliseconds;

    private static string Encode(TrackRecorder track) =>
        track.Path is null
            ? throw new InvalidOperationException("the track never started")
            : AacTranscoder.ToM4aOrKeepWav(track.Path);

    private static void Report(TrackRecorder track, string label)
    {
        if (track.Failure is not null)
        {
            Console.Error.WriteLine($"warning: the {label} track stopped early: {track.Failure.Message}");
        }
    }

    public void Dispose()
    {
        _mic.Dispose();
        _system.Dispose();
    }
}
