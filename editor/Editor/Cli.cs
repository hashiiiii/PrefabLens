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
        public const string Version = "0.9.1";
        public const string CliPathPref = "PrefabLens.CliPath";

        public static string BinaryName =>
            RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "prefablens.exe" : "prefablens";

        public static string MergeBinaryName =>
            RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "git-merge-prefablens.exe" : "git-merge-prefablens";

        /// Default install location. Under Library, relative to cwd (= Unity project root).
        public static string DefaultPath => Path.Combine("Library", "PrefabLens", Version, BinaryName);

        public static string MergePath(string cliPath) =>
            Path.Combine(Path.GetDirectoryName(cliPath) ?? "", MergeBinaryName);

        const int VersionTimeoutMs = 5_000;

        readonly struct BundleValidation
        {
            public readonly bool IsValid;
            public readonly string Version;
            public readonly string Error;

            public BundleValidation(bool isValid, string version, string error)
            {
                IsValid = isValid;
                Version = version;
                Error = error;
            }
        }

        static BundleValidation ValidateBundle(string cliPath, string requiredVersion)
        {
            if (!File.Exists(cliPath))
                return Invalid($"{BinaryName} was not found at '{cliPath}'.");
            var mergePath = MergePath(cliPath);
            if (!File.Exists(mergePath))
                return Invalid($"{MergeBinaryName} was not found at '{mergePath}'.");

            var cli = ReadVersion(cliPath, "prefablens");
            if (!cli.IsValid)
                return cli;
            var merge = ReadVersion(mergePath, "git-merge-prefablens");
            if (!merge.IsValid)
                return merge;
            if (cli.Version != merge.Version)
                return Invalid(
                    $"The CLI bundle contains different versions: prefablens {cli.Version} and "
                        + $"git-merge-prefablens {merge.Version}."
                );
            if (requiredVersion != null && cli.Version != requiredVersion)
                return Invalid($"The CLI bundle version is {cli.Version}, but PrefabLens requires {requiredVersion}.");
            return cli;
        }

        static BundleValidation ReadVersion(string path, string command)
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
            return new BundleValidation(true, version, null);
        }

        static BundleValidation Invalid(string error) => new BundleValidation(false, null, error);

        /// Result of the CLI lookup. OverrideError is non-null when the EditorPrefs
        /// override does not identify a complete, matching CLI bundle.
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

        /// A valid manual bundle takes precedence. An invalid override is reported.
        public static Location Locate(string manual, string defaultPath)
        {
            if (!string.IsNullOrEmpty(manual))
            {
                var manualValidation = ValidateBundle(manual, requiredVersion: null);
                if (manualValidation.IsValid)
                    return new Location(manual, null);
                return new Location(
                    ValidateBundle(defaultPath, Version).IsValid ? defaultPath : null,
                    manualValidation.Error
                );
            }
            return new Location(ValidateBundle(defaultPath, Version).IsValid ? defaultPath : null, null);
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
