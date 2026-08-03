using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace Patchthrough.Windows.Transcription;

internal static class AudioNormalizer
{
    public const int SampleRate = 16_000;

    /// <summary>Decode to validated 16 kHz mono float without modifying the recording.</summary>
    public static float[] ReadMono16k(string path)
    {
        using var reader = new MediaFoundationReader(path);
        ISampleProvider provider = reader.ToSampleProvider();
        if (provider.WaveFormat.Channels == 2) provider = new StereoToMonoSampleProvider(provider);
        else if (provider.WaveFormat.Channels > 2) provider = new MultiplexingSampleProvider([provider], 1);
        if (provider.WaveFormat.SampleRate != SampleRate)
            provider = new WdlResamplingSampleProvider(provider, SampleRate);

        var samples = new List<float>();
        var buffer = new float[SampleRate];
        int read;
        while ((read = provider.Read(buffer, 0, buffer.Length)) > 0)
        {
            for (var index = 0; index < read; index++)
                samples.Add(float.IsFinite(buffer[index]) ? Math.Clamp(buffer[index], -1, 1) : 0);
        }
        return samples.ToArray();
    }
}
