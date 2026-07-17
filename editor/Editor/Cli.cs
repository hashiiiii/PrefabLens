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
        public const string Version = "0.7.1";
        public const string CliPathPref = "PrefabLens.CliPath";

        public static string BinaryName =>
            RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "prefablens.exe" : "prefablens";

        /// Default install location. Under Library, relative to cwd (= Unity project root).
        public static string DefaultPath => Path.Combine("Library", "PrefabLens", Version, BinaryName);

        /// Result of the CLI lookup. MissingOverride is non-null when the EditorPrefs
        /// override points at a file that does not exist — reportable instead of a silent
        /// fallback, and exactly the state the #162 settings page will display.
        public readonly struct Location
        {
            /// Executable to run, or null when neither the override nor the default exists.
            public readonly string Path;

            public readonly string MissingOverride;

            public Location(string path, string missingOverride)
            {
                Path = path;
                MissingOverride = missingOverride;
            }
        }

        /// Pure lookup order (EditMode test target): a manual override takes precedence;
        /// an override pointing at a missing file is reported, not silently skipped.
        public static Location Locate(string manual, string defaultPath)
        {
            if (!string.IsNullOrEmpty(manual))
            {
                if (File.Exists(manual))
                    return new Location(manual, null);
                return new Location(File.Exists(defaultPath) ? defaultPath : null, manual);
            }
            return new Location(File.Exists(defaultPath) ? defaultPath : null, null);
        }

        public static Location Locate() => Locate(EditorPrefs.GetString(CliPathPref, ""), DefaultPath);
    }
}
