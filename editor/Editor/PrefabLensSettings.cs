using UnityEditor;
using UnityEngine.UIElements;

namespace PrefabLens
{
    /// Preferences > PrefabLens: edit the CLI path override and see which binary
    /// actually runs. All state goes through Cli.PathOverride / Cli.Locate so the
    /// page can never drift from the window's resolution behavior.
    public static class PrefabLensSettings
    {
        /// One line naming the binary Locate would run right now.
        public static string ResolvedLabel(Cli.Location loc, string version) =>
            loc.Path != null
                ? $"Resolved CLI: {loc.Path}"
                : $"Resolved CLI: not found — v{version} downloads on the next refresh";

        /// Warning line for an override pointing at a missing file; null when healthy.
        public static string MissingOverrideNote(Cli.Location loc) =>
            loc.MissingOverride != null ? $"Override points at a missing file: {loc.MissingOverride}" : null;

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
                    $"Manual prefablens binary. Empty = auto-download v{Cli.Version} under Library. "
                    + $"Stored in EditorPrefs '{Cli.CliPathPref}'.",
            };
            path.RegisterValueChangedCallback(e =>
            {
                Cli.PathOverride = e.newValue;
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
            warning.text = MissingOverrideNote(loc) ?? "";
        }
    }
}
