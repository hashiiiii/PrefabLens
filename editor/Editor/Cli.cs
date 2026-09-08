using System;
using System.IO;
using System.Runtime.InteropServices;
using UnityEditor;

namespace PrefabLens
{
    /// Locate, download, and run the prefablens CLI. All git logic lives in the CLI.
    /// Split by concern: Cli.cs (constants + locate), Cli.Download.cs, Cli.Run.cs.
    public static partial class Cli
    {
        /// Version of the CLI to download (kept in sync with the GitHub Releases tag v{Version}).
        public const string Version = "0.10.0";
        public const string CliPathPref = "PrefabLens.CliPath";

        public static string BinaryName =>
            RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "prefablens.exe" : "prefablens";

        /// Default install location. Under Library, relative to cwd (= Unity project root).
        public static string DefaultPath => Path.Combine("Library", "PrefabLens", Version, BinaryName);

        const int VersionTimeoutMs = 5_000;

        /// A validation error, or null when the binary reports a compatible version.
        static string ValidateCli(string cliPath, string requiredVersion)
        {
            if (!File.Exists(cliPath))
                return $"{BinaryName} was not found at '{cliPath}'.";

            Result result;
            try
            {
                var fullPath = Path.GetFullPath(cliPath);
                result = RunProcess(fullPath, "--version", Path.GetDirectoryName(fullPath), VersionTimeoutMs);
            }
            catch (Exception e)
            {
                return $"prefablens at '{cliPath}' did not start: {e.Message}";
            }
            if (result.ExitCode != 0)
            {
                var detail = string.IsNullOrWhiteSpace(result.Stderr)
                    ? $"exit {result.ExitCode}"
                    : result.Stderr.Trim();
                return $"prefablens at '{cliPath}' failed for --version: {detail}";
            }

            var output = result.Stdout.Trim();
            const string prefix = "prefablens ";
            if (!output.StartsWith(prefix, StringComparison.Ordinal))
                return $"prefablens at '{cliPath}' returned an invalid --version value: '{output}'.";
            var version = output.Substring(prefix.Length);
            if (version.Length == 0 || version.IndexOfAny(new[] { ' ', '\t', '\r', '\n' }) >= 0)
                return $"prefablens at '{cliPath}' returned an invalid --version value: '{output}'.";
            if (requiredVersion != null && version != requiredVersion)
                return $"The CLI version is {version}, but PrefabLens requires {requiredVersion}.";
            return null;
        }

        /// Result of the CLI lookup. OverrideError is non-null when the EditorPrefs override is invalid.
        public readonly struct Location
        {
            /// Executable to run, or null when neither the override nor the default exists.
            public readonly string Path;

            public readonly string OverrideError;

            public Location(string path, string overrideError)
            {
                Path = path;
                OverrideError = overrideError;
            }
        }

        /// A valid manual CLI takes precedence. An invalid override is reported.
        public static Location Locate(string manual, string defaultPath)
        {
            string overrideError = null;
            if (!string.IsNullOrEmpty(manual))
            {
                overrideError = ValidateCli(manual, requiredVersion: null);
                if (overrideError == null)
                    return new Location(manual, null);
            }
            return new Location(ValidateCli(defaultPath, Version) == null ? defaultPath : null, overrideError);
        }

        /// The manual CLI path override, EditorPrefs-backed. Empty = unset. The single
        /// get/set surface shared by the window and the settings page (#162); clearing
        /// deletes the key so "unset" and "empty" cannot drift apart.
        public static string PathOverride
        {
            get => EditorPrefs.GetString(CliPathPref, "");
            set
            {
                if (string.IsNullOrEmpty(value))
                    EditorPrefs.DeleteKey(CliPathPref);
                else
                    EditorPrefs.SetString(CliPathPref, value);
            }
        }

        public static Location Locate() => Locate(PathOverride, DefaultPath);
    }
}
