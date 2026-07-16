using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using UnityEditor;

namespace PrefabLens
{
    /// Locate, download, and run the prefablens CLI. All git logic lives in the CLI.
    public static class Cli
    {
        /// Version of the CLI to download (kept in sync with the GitHub Releases tag v{Version}).
        public const string Version = "0.7.1";
        public const string CliPathPref = "PrefabLens.CliPath";

        /// Upper bound on CLI execution. Set longer than the CLI's internal git timeout (60s) so that on a git hang
        /// the CLI surfaces its own specific error first. This is the last-resort safety net against freezing the Unity main thread.
        public const int RunTimeoutMs = 90_000;

        // ---- Pure functions (EditMode test targets) ----

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

        /// Bare invocation = bulk mode: HEAD vs working tree, all changed Unity files,
        /// as a [{path, diff}] JSON array.
        public static string[] BuildBulkArgs() => new[] { "--json" };

        /// Run bulk mode off the main thread. The callback is posted back through the
        /// caller's SynchronizationContext (Unity's main thread when called from the window).
        public static void RunBulkAsync(string cliPath, Action<Result> onDone) =>
            RunAsync(cliPath, QuoteArgs(BuildBulkArgs()), onDone, SynchronizationContext.Current);

        public static void RunAsync(string file, string arguments, Action<Result> onDone, SynchronizationContext ctx)
        {
            var workDir = Directory.GetCurrentDirectory();
            Task.Run(() =>
            {
                Result res;
                try
                {
                    res = RunProcess(file, arguments, workDir, RunTimeoutMs);
                }
                catch (Exception e)
                {
                    // Process.Start failures (missing binary, permissions) become a Result
                    // so every failure reaches the window through one path.
                    res = new Result
                    {
                        ExitCode = -1,
                        Stdout = "",
                        Stderr = e.Message,
                    };
                }
                if (ctx != null)
                    ctx.Post(_ => onDone(res), null);
                else
                    onDone(res);
            });
        }

        /// Minimal quoting for ProcessStartInfo.Arguments (handles asset paths with spaces).
        public static string QuoteArgs(string[] args)
        {
            var quoted = new string[args.Length];
            for (var i = 0; i < args.Length; i++)
                quoted[i] = "\"" + args[i].Replace("\"", "\\\"") + "\"";
            return string.Join(" ", quoted);
        }

        // ---- Editor integration ----

        public static string BinaryName =>
            RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "prefablens.exe" : "prefablens";

        /// Default install location. Under Library, relative to cwd (= Unity project root).
        public static string DefaultPath => Path.Combine("Library", "PrefabLens", Version, BinaryName);

        /// A manual EditorPrefs override takes precedence. Otherwise the default location. If neither exists, null.
        public static string Find()
        {
            var manual = EditorPrefs.GetString(CliPathPref, "");
            if (!string.IsNullOrEmpty(manual) && File.Exists(manual))
                return manual;
            return File.Exists(DefaultPath) ? DefaultPath : null;
        }

        /// Fetch from GitHub Releases and extract under Library. Returns the executable path on success, throws on failure.
        /// Synchronous and free of Unity API calls so it can run on a worker thread (see DownloadAsync).
        public static string Download()
        {
            var asset = ReleaseAssetName(
                RuntimeInformation.IsOSPlatform(OSPlatform.Windows),
                RuntimeInformation.IsOSPlatform(OSPlatform.OSX),
                RuntimeInformation.ProcessArchitecture == Architecture.Arm64
            );
            var url = DownloadUrl(Version, asset);
            var dir = Path.GetDirectoryName(DefaultPath);
            Directory.CreateDirectory(dir);

            using var http = new HttpClient();
            // GetAwaiter().GetResult() unwraps AggregateException so onDone sees the HttpRequestException message.
            var bytes = http.GetByteArrayAsync(url).GetAwaiter().GetResult();
            ExtractTo(bytes, dir);

            if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
                RunProcess("chmod", "+x \"" + DefaultPath + "\"", ".", RunTimeoutMs);
            DeleteStaleVersions(Path.GetDirectoryName(dir), Version);
            return DefaultPath;
        }

        /// Run Download() off the main thread. The outcome is posted back through the caller's
        /// SynchronizationContext (Unity's main thread when called from the window).
        /// Exactly one of (path, error) is non-null.
        public static void DownloadAsync(Action<string, string> onDone)
        {
            var ctx = SynchronizationContext.Current;
            Task.Run(() =>
            {
                string path = null;
                string error = null;
                try
                {
                    path = Download();
                }
                catch (Exception e)
                {
                    error = e.Message;
                }
                if (ctx != null)
                    ctx.Post(_ => onDone(path, error), null);
                else
                    onDone(path, error);
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
            using var dst = new MemoryStream();
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
            foreach (var entry in zip.Entries)
            {
                // ZipFileExtensions (ExtractToFile) isn't referenceable under netstandard, so copy manually
                var dest = Path.Combine(dir, entry.Name);
                using var src = entry.Open();
                using var dst = File.Create(dest);
                src.CopyTo(dst);
            }
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
                if (Path.GetFileName(dir) == keep)
                    continue;
                try
                {
                    Directory.Delete(dir, recursive: true);
                }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
        }

        public struct Result
        {
            public int ExitCode;
            public string Stdout;
            public string Stderr;
            public bool TimedOut;
        }

        public static Result RunProcess(string file, string arguments, string workDir, int timeoutMs)
        {
            var psi = new ProcessStartInfo(file, arguments)
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                WorkingDirectory = workDir,
            };
            using var p = Process.Start(psi);
            // Avoid a two-way ReadToEnd deadlock: read one side asynchronously
            var stdout = p.StandardOutput.ReadToEndAsync();
            var stderr = p.StandardError.ReadToEndAsync();
            if (!p.WaitForExit(timeoutMs))
            {
                // Protect the Unity main thread from a hung CLI. If a grandchild process that holds stdio
                // survives the Kill, the Read tasks never complete, so don't wait for the remaining output.
                try
                {
                    p.Kill();
                }
                catch (InvalidOperationException)
                { /* race between timeout and exit */
                }
                catch (System.ComponentModel.Win32Exception)
                { /* already terminating */
                }
                return new Result
                {
                    ExitCode = -1,
                    Stdout = "",
                    Stderr = $"prefablens timed out after {timeoutMs / 1000}s and was killed",
                    TimedOut = true,
                };
            }
            return new Result
            {
                ExitCode = p.ExitCode,
                Stdout = stdout.Result,
                Stderr = stderr.Result,
            };
        }
    }
}
