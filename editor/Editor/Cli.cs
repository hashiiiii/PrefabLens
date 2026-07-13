using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Runtime.InteropServices;
using UnityEditor;

namespace PrefabLens
{
    /// Locate, download, and run the prefablens CLI. All git logic lives in the CLI.
    public static class Cli
    {
        /// Version of the CLI to download (kept in sync with the GitHub Releases tag v{Version}).
        public const string Version = "0.6.0";
        public const string CliPathPref = "PrefabLens.CliPath";

        /// Upper bound on CLI execution. Set longer than the CLI's internal git timeout (60s) so that on a git hang
        /// the CLI surfaces its own specific error first. This is the last-resort safety net against freezing the Unity main thread.
        public const int RunTimeoutMs = 90_000;

        // ---- Pure functions (EditMode test targets) ----

        public static string ReleaseAssetName(bool isWindows, bool isMac, bool isArm64)
        {
            if (isWindows)
                return "prefablens-windows-x64.zip";
            if (isMac)
                return isArm64 ? "prefablens-macos-arm64.zip" : "prefablens-macos-x64.zip";
            return "prefablens-linux-x64.zip";
        }

        public static string DownloadUrl(string version, string assetName) =>
            $"https://github.com/hashiiiii/PrefabLens/releases/download/v{version}/{assetName}";

        public static string[] BuildArgs(string assetPath) => new[] { "HEAD", assetPath, "--json" };

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

            try
            {
                EditorUtility.DisplayProgressBar("PrefabLens", $"Downloading {asset}…", 0.3f);
                using var http = new HttpClient();
                var bytes = http.GetByteArrayAsync(url).Result;
                using var zip = new ZipArchive(new MemoryStream(bytes));
                foreach (var entry in zip.Entries)
                {
                    // ZipFileExtensions (ExtractToFile) isn't referenceable under netstandard, so copy manually
                    var dest = Path.Combine(dir, entry.Name);
                    using var src = entry.Open();
                    using var dst = File.Create(dest);
                    src.CopyTo(dst);
                }
            }
            finally
            {
                EditorUtility.ClearProgressBar();
            }

            if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
                RunProcess("chmod", "+x \"" + DefaultPath + "\"", ".", RunTimeoutMs);
            return DefaultPath;
        }

        public struct Result
        {
            public int ExitCode;
            public string Stdout;
            public string Stderr;
            public bool TimedOut;
        }

        /// Run the CLI with the project root as cwd (git refs are resolved against the repository in cwd).
        public static Result Run(string cliPath, string assetPath)
        {
            return RunProcess(cliPath, QuoteArgs(BuildArgs(assetPath)), Directory.GetCurrentDirectory(), RunTimeoutMs);
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
