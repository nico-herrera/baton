using NAudio.MediaFoundation;
using NAudio.Wave;

namespace Patchthrough.Windows.Audio;

/// <summary>
/// Turns the captured WAV into AAC in an MP4 container, which is the codec the
/// macOS app already writes. Capture stays uncompressed, because encoding
/// inside the capture callback risks dropping buffers.
/// </summary>
public static class AacTranscoder
{
    /// <summary>
    /// Encode `wavPath` beside itself as `.m4a` and delete the WAV. Returns the
    /// filename that belongs in the `files` map of meta.json.
    ///
    /// Windows N editions ship without the Media Feature Pack, so the AAC
    /// encoder can be absent. The session contract names no extension, so the
    /// honest fallback is to keep the WAV and report it.
    /// </summary>
    public static string ToM4aOrKeepWav(string wavPath, TextWriter? warnings = null)
    {
        var m4aPath = System.IO.Path.ChangeExtension(wavPath, ".m4a");
        try
        {
            MediaFoundationApi.Startup();
            using (var reader = new WaveFileReader(wavPath))
            {
                // 96 kbps mono speech is transparent enough for a transcript and
                // keeps an hour of audio around 40 MB per track.
                MediaFoundationEncoder.EncodeToAac(reader, m4aPath, 96_000);
            }
            File.Delete(wavPath);
            return System.IO.Path.GetFileName(m4aPath);
        }
        catch (Exception error)
        {
            (warnings ?? Console.Error).WriteLine(
                $"warning: cannot encode AAC ({error.Message}). Keeping {System.IO.Path.GetFileName(wavPath)}");
            if (File.Exists(m4aPath)) File.Delete(m4aPath);
            return System.IO.Path.GetFileName(wavPath);
        }
    }
}
