using NUnit.Framework;

namespace PrefabLens.Tests
{
    public class SettingsTests
    {
        [Test]
        public void ResolvedLabelAndOverrideNoteNameTheBinaryTheWindowWillRun()
        {
            Assert.AreEqual(
                $"Resolved CLI (downloaded): {Cli.DefaultPath}",
                PrefabLensSettings.ResolvedLabel(new Cli.Location(Cli.DefaultPath, null), "0.7.1")
            );
            Assert.AreEqual(
                "Resolved CLI (override): /custom/prefablens",
                PrefabLensSettings.ResolvedLabel(new Cli.Location("/custom/prefablens", null), "0.7.1")
            );
            Assert.AreEqual(
                "Resolved CLI: not found — the PrefabLens window downloads v0.7.1 on its next refresh",
                PrefabLensSettings.ResolvedLabel(new Cli.Location(null, null), "0.7.1")
            );

            var broken = new Cli.Location(
                "Library/PrefabLens/0.7.1/prefablens",
                "prefablens was not found at '/gone/prefablens'."
            );
            Assert.AreEqual(
                "CLI path override is invalid. prefablens was not found at '/gone/prefablens'.",
                PrefabLensSettings.OverrideErrorNote(broken)
            );
            Assert.IsNull(PrefabLensSettings.OverrideErrorNote(new Cli.Location(null, null)));
        }
    }
}
