using SharpCompress.Archives;
using SharpCompress.Common;
using System.Security.Cryptography;
using System.Text.Json;

namespace Patchthrough.Windows.Transcription;

/// <summary>Resumable, hash-verified Parakeet model installation.</summary>
public sealed class ModelStore(string directory)
{
    public const string ModelName = "parakeet-tdt-0.6b-v2-int8";
    private const long ArchiveBytes = 482_468_385;
    private const string ArchiveSha256 = "157c157bc51155e03e37d2466522a3a737dd9c72bb25f36eb18912964161e1ad";
    private static readonly Uri Source = new(
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2");

    public string Directory { get; } = directory;
    public static ModelStore Default => new(Path.Combine(ModelRoot, ModelName));
    public static string ModelRoot => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "patchthrough", "models");

    public string Encoder => Path.Combine(Directory, "encoder.int8.onnx");
    public string Decoder => Path.Combine(Directory, "decoder.int8.onnx");
    public string Joiner => Path.Combine(Directory, "joiner.int8.onnx");
    public string Tokens => Path.Combine(Directory, "tokens.txt");
    private string InstallManifestPath => Path.Combine(Directory, "verified-install.json");

    public IReadOnlyList<string> Missing() =>
        new[] { Encoder, Decoder, Joiner, Tokens }.Where(path => !File.Exists(path)).ToList();

    public async Task EnsureAsync(CancellationToken cancellationToken = default)
    {
        if (Missing().Count == 0 && await InstalledFilesAreValidAsync(cancellationToken)) return;
        if (System.IO.Directory.Exists(Directory))
            System.IO.Directory.Delete(Directory, recursive: true);
        var archive = await VerifiedDownloader.EnsureFileAsync(
            ModelRoot,
            ModelName + ".tar.bz2",
            Source,
            ArchiveBytes,
            ArchiveSha256,
            cancellationToken);
        var staging = Path.Combine(ModelRoot, ".extract-" + Guid.NewGuid().ToString("N"));
        System.IO.Directory.CreateDirectory(staging);
        try
        {
            using var opened = ArchiveFactory.OpenArchive(archive);
            foreach (var entry in opened.Entries.Where(entry => !entry.IsDirectory))
            {
                var key = entry.Key ?? throw new InvalidDataException("model archive contains an unnamed entry");
                var relative = key.Replace("/", Path.DirectorySeparatorChar.ToString(), StringComparison.Ordinal);
                var destination = Path.GetFullPath(Path.Combine(staging, relative));
                if (!destination.StartsWith(Path.GetFullPath(staging) + Path.DirectorySeparatorChar, StringComparison.Ordinal))
                    throw new InvalidDataException("model archive contains an unsafe path");
                System.IO.Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                entry.WriteToFile(destination, new ExtractionOptions { Overwrite = true });
            }
            var encoder = System.IO.Directory.GetFiles(staging, "encoder.int8.onnx", SearchOption.AllDirectories).SingleOrDefault()
                ?? throw new InvalidDataException("Parakeet archive has no encoder.int8.onnx");
            var sourceDirectory = Path.GetDirectoryName(encoder)!;
            System.IO.Directory.CreateDirectory(Directory);
            foreach (var file in System.IO.Directory.GetFiles(sourceDirectory))
                File.Move(file, Path.Combine(Directory, Path.GetFileName(file)), overwrite: true);
            Require();
            await WriteInstallManifestAsync(cancellationToken);
            if (!await InstalledFilesAreValidAsync(cancellationToken))
                throw new InvalidDataException("installed Parakeet files failed verification");
        }
        finally
        {
            if (System.IO.Directory.Exists(staging)) System.IO.Directory.Delete(staging, recursive: true);
        }
    }

    public void Require()
    {
        var missing = Missing();
        if (missing.Count == 0) return;
        throw new FileNotFoundException(
            $"the transcription model is incomplete in {Directory}. Missing: "
            + string.Join(", ", missing.Select(Path.GetFileName)));
    }

    private async Task WriteInstallManifestAsync(CancellationToken cancellationToken)
    {
        var files = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var path in new[] { Encoder, Decoder, Joiner, Tokens })
            files[Path.GetFileName(path)] = await HashAsync(path, cancellationToken);
        var manifest = new InstalledManifest(ArchiveSha256, files);
        await File.WriteAllTextAsync(
            InstallManifestPath,
            JsonSerializer.Serialize(manifest, new JsonSerializerOptions { WriteIndented = true }),
            cancellationToken);
    }

    private async Task<bool> InstalledFilesAreValidAsync(CancellationToken cancellationToken)
    {
        if (!File.Exists(InstallManifestPath)) return false;
        try
        {
            var manifest = JsonSerializer.Deserialize<InstalledManifest>(
                await File.ReadAllTextAsync(InstallManifestPath, cancellationToken));
            if (manifest is null || !string.Equals(manifest.ArchiveSha256, ArchiveSha256, StringComparison.Ordinal))
                return false;
            foreach (var path in new[] { Encoder, Decoder, Joiner, Tokens })
            {
                if (!File.Exists(path) || !manifest.Files.TryGetValue(Path.GetFileName(path), out var expected))
                    return false;
                var actual = await HashAsync(path, cancellationToken);
                if (!CryptographicOperations.FixedTimeEquals(
                    Convert.FromHexString(actual), Convert.FromHexString(expected))) return false;
            }
            return true;
        }
        catch (Exception error) when (error is IOException or JsonException or FormatException)
        {
            return false;
        }
    }

    private static async Task<string> HashAsync(string path, CancellationToken cancellationToken)
    {
        await using var stream = new FileStream(
            path, FileMode.Open, FileAccess.Read, FileShare.Read,
            1024 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
        return Convert.ToHexString(await SHA256.HashDataAsync(stream, cancellationToken)).ToLowerInvariant();
    }

    private sealed record InstalledManifest(
        string ArchiveSha256,
        IReadOnlyDictionary<string, string> Files);
}

public sealed class WhisperModelStore(string directory)
{
    public const string ModelName = "whisper-large-v3-turbo-q5_0";
    private const string FileName = "ggml-large-v3-turbo-q5_0.bin";
    private const long Bytes = 574_041_195;
    private const string Sha256 = "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2";
    private static readonly Uri Source = new(
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin");

    public string Directory { get; } = directory;
    public string Path => System.IO.Path.Combine(Directory, FileName);
    public static WhisperModelStore Default => new(System.IO.Path.Combine(ModelStore.ModelRoot, ModelName));

    public Task<string> EnsureAsync(CancellationToken cancellationToken = default) =>
        VerifiedDownloader.EnsureFileAsync(Directory, FileName, Source, Bytes, Sha256, cancellationToken);
}
