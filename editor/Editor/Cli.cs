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
        public const string Version = "0.9.2";
        public const string CliPathPref = "PrefabLens.CliPath";

        public static string BinaryName =>
            RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "prefablens.exe" : "prefablens";

        /// Default install location. Under Library, relative to cwd (= Unity project root).
        public static string DefaultPath => Path.Combine("Library", "PrefabLens", Version, BinaryName);

        const int VersionTimeoutMs = 5_000;

        readonly struct CliValidation
        {
            public readonly bool IsValid;
            public readonly string Version;
            public readonly string Error;

            public CliValidation(bool isValid, string version, string error)
            {
                IsValid = isValid;
                Version = version;
                Error = error;
            }
        }

        static CliValidation ValidateCli(string cliPath, string requiredVersion)
        {
            if (!File.Exists(cliPath))
                return Invalid($"{BinaryName} was not found at '{cliPath}'.");

            var cli = ReadVersion(cliPath, "prefablens");
            if (!cli.IsValid)
                return cli;
            if (requiredVersion != null && cli.Version != requiredVersion)
                return Invalid($"The CLI version is {cli.Version}, but PrefabLens requires {requiredVersion}.");
            return cli;
        }

        static CliValidation ReadVersion(string path, string command)
        {
            Result result;
            try
            {
                result = RunProcess(
                    Path.GetFullPath(path),
                    "--version",
                    Path.GetDirectoryName(Path.GetFullPath(path)),
                    VersionTimeoutMs
                );
            }
            catch (Exception e)
            {
                return Invalid($"{command} at '{path}' did not start: {e.Message}");
            }
            if (result.ExitCode != 0)
            {
                var detail = string.IsNullOrWhiteSpace(result.Stderr)
                    ? $"exit {result.ExitCode}"
                    : result.Stderr.Trim();
                return Invalid($"{command} at '{path}' failed for --version: {detail}");
            }

            var output = result.Stdout.Trim();
            var prefix = command + " ";
            if (!output.StartsWith(prefix, StringComparison.Ordinal))
                return Invalid($"{command} at '{path}' returned an invalid --version value: '{output}'.");
            var version = output.Substring(prefix.Length);
            if (version.Length == 0 || version.IndexOfAny(new[] { ' ', '\t', '\r', '\n' }) >= 0)
                return Invalid($"{command} at '{path}' returned an invalid --version value: '{output}'.");
            return new CliValidation(true, version, null);
        }

        static CliValidation Invalid(string error) => new CliValidation(false, null, error);

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
            if (!string.IsNullOrEmpty(manual))
            {
                var manualValidation = ValidateCli(manual, requiredVersion: null);
                if (manualValidation.IsValid)
                    return new Location(manual, null);
                return new Location(
                    ValidateCli(defaultPath, Version).IsValid ? defaultPath : null,
                    manualValidation.Error
                );
            }
            return new Location(ValidateCli(defaultPath, Version).IsValid ? defaultPath : null, null);
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
