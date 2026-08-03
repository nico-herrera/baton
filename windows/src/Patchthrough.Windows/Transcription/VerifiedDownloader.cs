using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;

namespace Patchthrough.Windows.Transcription;

internal static class VerifiedDownloader
{
    private static readonly HttpClient Client = new() { Timeout = Timeout.InfiniteTimeSpan };

    public static async Task<string> EnsureFileAsync(
        string directory,
        string fileName,
        Uri source,
        long expectedBytes,
        string expectedSha256,
        CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(directory);
        var destination = Path.Combine(directory, fileName);
        if (await IsValidAsync(destination, expectedBytes, expectedSha256, cancellationToken)) return destination;
        if (File.Exists(destination)) File.Delete(destination);

        var partial = destination + ".partial";
        var existing = File.Exists(partial) ? new FileInfo(partial).Length : 0;
        if (existing > expectedBytes)
        {
            File.Delete(partial);
            existing = 0;
        }
        using var request = new HttpRequestMessage(HttpMethod.Get, source);
        if (existing > 0) request.Headers.Range = new RangeHeaderValue(existing, null);
        using var response = await Client.SendAsync(
            request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        response.EnsureSuccessStatusCode();

        var append = existing > 0 && response.StatusCode == HttpStatusCode.PartialContent;
        await using (var output = new FileStream(
            partial,
            append ? FileMode.Append : FileMode.Create,
            FileAccess.Write,
            FileShare.None,
            1024 * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan))
        await using (var input = await response.Content.ReadAsStreamAsync(cancellationToken))
        {
            await input.CopyToAsync(output, cancellationToken);
        }

        if (!await IsValidAsync(partial, expectedBytes, expectedSha256, cancellationToken))
            throw new InvalidDataException($"downloaded model failed SHA-256 or size verification: {fileName}");
        File.Move(partial, destination, overwrite: true);
        return destination;
    }

    private static async Task<bool> IsValidAsync(
        string path,
        long expectedBytes,
        string expectedSha256,
        CancellationToken cancellationToken)
    {
        if (!File.Exists(path) || new FileInfo(path).Length != expectedBytes) return false;
        await using var stream = new FileStream(
            path, FileMode.Open, FileAccess.Read, FileShare.Read,
            1024 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
        var actual = await SHA256.HashDataAsync(stream, cancellationToken);
        return CryptographicOperations.FixedTimeEquals(actual, Convert.FromHexString(expectedSha256));
    }
}
