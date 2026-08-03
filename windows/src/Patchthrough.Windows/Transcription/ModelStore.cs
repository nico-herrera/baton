namespace Patchthrough.Windows.Transcription;

/// <summary>
/// Where the speech models live, and whether they are all there.
///
/// The macOS app downloads its models through FluidAudio. This does not
/// download anything. An unattended fetch of 600 MB whose checksum nobody has
/// verified is worse than a clear instruction, so a missing model is an error
/// that says exactly which file is absent and where the set comes from.
/// Downloading with a recorded hash belongs in a later milestone.
/// </summary>
public sealed class ModelStore(string directory)
{
    public const string ModelName = "parakeet-tdt-0.6b-v2-int8";

    private const string Source =
        "https://github.com/k2-fsa/sherpa-onnx/releases (sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8)";

    public string Directory { get; } = directory;

    public static ModelStore Default => new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "patchthrough",
        "models",
        ModelName));

    public string Encoder => Path.Combine(Directory, "encoder.int8.onnx");
    public string Decoder => Path.Combine(Directory, "decoder.int8.onnx");
    public string Joiner => Path.Combine(Directory, "joiner.int8.onnx");
    public string Tokens => Path.Combine(Directory, "tokens.txt");

    public IReadOnlyList<string> Missing() =>
        new[] { Encoder, Decoder, Joiner, Tokens }.Where(path => !File.Exists(path)).ToList();

    /// <summary>Throw with something the reader can act on.</summary>
    public void Require()
    {
        var missing = Missing();
        if (missing.Count == 0) return;
        throw new FileNotFoundException(
            $"the transcription model is incomplete in {Directory}. "
            + $"Missing: {string.Join(", ", missing.Select(Path.GetFileName))}. "
            + $"Download {ModelName} from {Source} and unpack it there");
    }
}
