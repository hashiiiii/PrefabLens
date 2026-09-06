using UnityEditor;
using UnityEngine.UIElements;

namespace PrefabLens
{
    /// Preferences > PrefabLens: edit the CLI path override and see which binary
    /// actually runs. All state goes through Cli.PathOverride / Cli.Locate so the
    /// page can never drift from the window's resolution behavior.
    public static class PrefabLensSettings
    {
        /// One line that names the binary that Locate will run.
        public static string ResolvedLabel(Cli.Location loc, string version)
        {
            if (loc.Path == null)
                return $"Resolved CLI: not found — the PrefabLens window downloads v{version} on its next refresh";
            var source = loc.Path == Cli.DefaultPath ? "downloaded" : "override";
            return $"Resolved CLI ({source}): {loc.Path}";
        }

        /// Warning line for an invalid override, or null when the override is valid or unset.
        public static string OverrideErrorNote(Cli.Location loc) =>
            loc.OverrideError != null ? $"CLI path override is invalid. {loc.OverrideError}" : null;

        [SettingsProvider]
        public static SettingsProvider Create() =>
            new SettingsProvider("Preferences/PrefabLens", SettingsScope.User, new[] { "prefablens", "cli", "diff" })
            {
                activateHandler = (_, root) => Build(root),
            };

        static void Build(VisualElement root)
        {
            var box = new VisualElement { style = { marginLeft = 10, marginTop = 10 } };
            root.Add(box);

            var resolved = new Label { style = { marginTop = 6, whiteSpace = WhiteSpace.Normal } };
            var warning = new Label { style = { marginTop = 2, whiteSpace = WhiteSpace.Normal } };

            var path = new TextField("CLI path override")
            {
                value = Cli.PathOverride,
                // Commit on Enter or focus loss so each edit re-resolves exactly once.
                isDelayed = true,
                tooltip =
                    $"Select prefablens next to {Cli.MergeBinaryName}. Empty = auto-download v{Cli.Version} under Library. "
                    + $"Stored in EditorPrefs '{Cli.CliPathPref}'.",
            };
            path.RegisterValueChangedCallback(e =>
            {
                // Trim: a pasted path with trailing whitespace would otherwise fail
                // File.Exists with an invisible cause in the warning line.
                Cli.PathOverride = e.newValue?.Trim();
                Sync(resolved, warning);
            });
            box.Add(path);

            var browse = new Button(() =>
            {
                var picked = EditorUtility.OpenFilePanel("Select prefablens binary", "", "");
                if (string.IsNullOrEmpty(picked))
                    return; // canceled: keep the current override
                Cli.PathOverride = picked;
                path.value = picked;
                Sync(resolved, warning);
            })
            {
                text = "Browse…",
                style =
                {
                    alignSelf = Align.FlexStart,
                    marginLeft = 6,
                    marginTop = 2,
                },
            };
            box.Add(browse);

            box.Add(resolved);
            box.Add(warning);
            Sync(resolved, warning);
        }

        /// Re-derives the diagnostic lines from the current resolution state.
        static void Sync(Label resolved, Label warning)
        {
            var loc = Cli.Locate();
            resolved.text = ResolvedLabel(loc, Cli.Version);
            warning.text = OverrideErrorNote(loc) ?? "";
        }
    }
}
