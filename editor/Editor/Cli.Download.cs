using System;
using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace PrefabLens
{
    // Fetch, verify, extract, and clean up the pinned CLI release.
    public static partial class Cli
    {
        /// A 120 s deadline covers SHA256SUMS and the ZIP, including stalled body reads.
        /// Slow connections have time to finish, and the window offers Cancel.
        public const int DownloadTimeoutMs = 120_000;

        public static string ReleaseAssetName(bool isWindows, bool isMac, bool isArm64)
        {
            if (isWindows)
                return isArm64 ? "prefablens-windows-arm64.zip" : "prefablens-windows-x64.zip";
            if (isMac)
                return isArm64 ? "prefablens-macos-arm64.zip" : "prefablens-macos-x64.zip";
            return isArm64 ? "prefablens-linux-arm64.zip" : "prefablens-linux-x64.zip";
        }

        public static string DownloadUrl(string version, string assetName) =>
            $"https://github.com/hashiiiii/PrefabLens/releases/download/v{version}/{assetName}";

        /// Hex digest for assetName from `shasum -a 256` output (the release's SHA256SUMS); null when absent.
        public static string ExpectedSha256(string sha256Sums, string assetName)
        {
            foreach (var line in sha256Sums.Split('\n'))
            {
                var parts = line.Trim().Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
                if (parts.Length == 2 && parts[1] == assetName)
                    return parts[0];
            }
            return null;
        }

        public static string Sha256Hex(byte[] bytes)
        {
            using var sha = SHA256.Create();
            var hash = sha.ComputeHash(bytes);
            var sb = new StringBuilder(hash.Length * 2);
            foreach (var b in hash)
                sb.Append(b.ToString("x2"));
            return sb.ToString();
        }

        /// Reject a tampered or corrupted release asset before it reaches ExtractTo.
        public static void VerifySha256(byte[] bytes, string sha256Sums, string assetName)
        {
            var expected = ExpectedSha256(sha256Sums, assetName);
            if (expected == null)
                throw new InvalidOperationException($"SHA256SUMS has no entry for {assetName}");
            var actual = Sha256Hex(bytes);
            if (!string.Equals(actual, expected, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException(
                    $"SHA256 mismatch for {assetName}: expected {expected}, got {actual}"
                );
        }

        /// Downloads from GitHub Releases, verifies SHA256SUMS, and installs under Library.
        /// Returns the executable path or throws on failure.
        /// Throws TimeoutException after DownloadTimeoutMs, or OperationCanceledException when ct is canceled.
        /// No Unity API calls are made, so DownloadAsync can run this on a worker thread.
        public static string Download(Action<long, long> onProgress = null, CancellationToken ct = default)
        {
            var asset = ReleaseAssetName(
                RuntimeInformation.IsOSPlatform(OSPlatform.Windows),
                RuntimeInformation.IsOSPlatform(OSPlatform.OSX),
                RuntimeInformation.ProcessArchitecture == Architecture.Arm64
            );
            var dir = Path.GetDirectoryName(DefaultPath);

            using var http = new HttpClient();
            // With a streamed response, HttpClient.Timeout covers only headers. The shared deadline must also cover body reads.
            http.Timeout = Timeout.InfiniteTimeSpan;
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(DownloadTimeoutMs);
            byte[] bytes;
            string sums;
            try
            {
                // Fetching SHA256SUMS first avoids downloading a large ZIP for an incomplete release.
                sums = Encoding.UTF8.GetString(FetchBytes(http, DownloadUrl(Version, "SHA256SUMS"), null, cts.Token));
                bytes = FetchBytes(http, DownloadUrl(Version, asset), onProgress, cts.Token);
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                throw new TimeoutException($"download timed out after {DownloadTimeoutMs / 1000}s");
            }
            VerifySha256(bytes, sums, asset);
            var installed = InstallArchive(bytes, dir, Version);
            DeleteStaleVersions(Path.GetDirectoryName(dir), Version);
            return installed;
        }

        /// Download runs on a worker thread. Progress and completion return through the caller's SynchronizationContext.
        /// For window callers, that is Unity's main thread. Exactly one of path or error is non-null.
        public static void DownloadAsync(
            Action<string, string> onDone,
            Action<long, long> onProgress = null,
            CancellationToken ct = default
        )
        {
            var ctx = SynchronizationContext.Current;
            // Network chunks can be small. Coalescing callbacks avoids thousands of main-thread posts for changes the UI cannot display.
            Action<long, long> progress = null;
            if (onProgress != null)
            {
                long lastStep = -1;
                progress = (read, total) =>
                {
                    var step = total > 0 ? read * 100 / total : read >> 18;
                    if (step == lastStep)
                        return;
                    lastStep = step;
                    Post(ctx, () => onProgress(read, total));
                };
            }
            Task.Run(() =>
            {
                string path = null;
                string error = null;
                try
                {
                    path = Download(progress, ct);
                }
                catch (Exception e)
                {
                    error = e.Message;
                }
                Post(ctx, () => onDone(path, error));
            });
        }

        /// GET url into memory, reporting (bytesSoFar, contentLengthOrMinusOne) after each chunk.
        /// Blocking by design: Download() runs on a worker thread (see DownloadAsync).
        public static byte[] FetchBytes(
            HttpClient http,
            string url,
            Action<long, long> onProgress,
            CancellationToken ct
        )
        {
            // GetAwaiter().GetResult() unwraps AggregateException so callers see the original message.
            using var res = http.SendAsync(
                    new HttpRequestMessage(HttpMethod.Get, url),
                    HttpCompletionOption.ResponseHeadersRead,
                    ct
                )
                .GetAwaiter()
                .GetResult();
            res.EnsureSuccessStatusCode();
            var total = res.Content.Headers.ContentLength ?? -1;
            using var src = res.Content.ReadAsStreamAsync().GetAwaiter().GetResult();
            // Sized up front so a multi-MB body doesn't go through doubling reallocations.
            using var dst = new MemoryStream(total > 0 && total <= int.MaxValue ? (int)total : 0);
            var buf = new byte[64 * 1024];
            int n;
            while ((n = src.ReadAsync(buf, 0, buf.Length, ct).GetAwaiter().GetResult()) > 0)
            {
                dst.Write(buf, 0, n);
                onProgress?.Invoke(dst.Length, total);
            }
            return dst.ToArray();
        }

        public static void ExtractTo(byte[] zipBytes, string dir)
        {
            using var zip = new ZipArchive(new MemoryStream(zipBytes));
            var entry = zip.GetEntry(BinaryName);
            if (entry == null)
                throw new InvalidOperationException($"The release archive does not contain {BinaryName}.");

            // ZipFileExtensions is not available under netstandard, so copy the entry manually.
            var dest = Path.Combine(dir, BinaryName);
            using var src = entry.Open();
            using var dst = File.Create(dest);
            src.CopyTo(dst);
        }

        public static string InstallArchive(byte[] zipBytes, string finalDirectory, string requiredVersion)
        {
            var fullFinalDirectory = Path.GetFullPath(finalDirectory);
            var root = Path.GetDirectoryName(fullFinalDirectory);
            Directory.CreateDirectory(root);
            var name = Path.GetFileName(fullFinalDirectory);
            var token = Guid.NewGuid().ToString("N");
            var stagingDirectory = Path.Combine(root, $".{name}.staging-{token}");
            var backupDirectory = Path.Combine(root, $".{name}.backup-{token}");
            try
            {
                Directory.CreateDirectory(stagingDirectory);
                ExtractTo(zipBytes, stagingDirectory);
                var stagedCliPath = Path.Combine(stagingDirectory, BinaryName);
                MarkExecutable(stagedCliPath);
                var error = ValidateCli(stagedCliPath, requiredVersion);
                if (error != null)
                    throw new InvalidOperationException(error);

                ReplaceDirectory(stagingDirectory, fullFinalDirectory, backupDirectory);
                return Path.Combine(finalDirectory, BinaryName);
            }
            finally
            {
                DeleteDirectoryBestEffort(stagingDirectory);
            }
        }

        static void ReplaceDirectory(string stagingDirectory, string finalDirectory, string backupDirectory)
        {
            var hadPrevious = Directory.Exists(finalDirectory);
            if (hadPrevious)
                Directory.Move(finalDirectory, backupDirectory);
            try
            {
                Directory.Move(stagingDirectory, finalDirectory);
            }
            catch
            {
                if (hadPrevious && !Directory.Exists(finalDirectory))
                    Directory.Move(backupDirectory, finalDirectory);
                throw;
            }
            DeleteDirectoryBestEffort(backupDirectory);
        }

        static void DeleteDirectoryBestEffort(string path)
        {
            if (!Directory.Exists(path))
                return;
            try
            {
                Directory.Delete(path, recursive: true);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }

        /// A failed chmod must stop installation before the first CLI run.
        public static void MarkExecutable(string cliPath)
        {
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
                return;
            var res = RunProcess("chmod", QuoteArgs(new[] { "+x", cliPath }), ".", RunTimeoutMs);
            if (res.ExitCode != 0)
                throw new InvalidOperationException(
                    $"chmod +x failed for {cliPath}: "
                        + (string.IsNullOrEmpty(res.Stderr) ? $"exit {res.ExitCode}" : res.Stderr.Trim())
                );
        }

        /// Drop cached binaries of other versions once the pinned one is in place.
        /// Best-effort: a locked directory (e.g. an old prefablens.exe still running
        /// on Windows) must not fail the download that just succeeded.
        public static void DeleteStaleVersions(string root, string keep)
        {
            if (!Directory.Exists(root))
                return;
            foreach (var dir in Directory.GetDirectories(root))
            {
                if (Path.GetFileName(dir) != keep)
                    DeleteDirectoryBestEffort(dir);
            }
        }
    }
}
