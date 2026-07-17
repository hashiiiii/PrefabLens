using NUnit.Framework;

namespace PrefabLens.Tests
{
    public class SettingsTests
    {
        [Test]
        public void ResolvedLabelTagsTheDownloadedBinary()
        {
            var loc = new Cli.Location(Cli.DefaultPath, null);
            Assert.AreEqual(
                $"Resolved CLI (downloaded): {Cli.DefaultPath}",
                PrefabLensSettings.ResolvedLabel(loc, "0.7.1")
            );
        }

        [Test]
        public void ResolvedLabelTagsAnOverrideBinary()
        {
            var loc = new Cli.Location("/custom/prefablens", null);
            Assert.AreEqual(
                "Resolved CLI (override): /custom/prefablens",
                PrefabLensSettings.ResolvedLabel(loc, "0.7.1")
            );
        }

        [Test]
        public void ResolvedLabelExplainsTheDownloadWhenNothingExists()
        {
            // The page must not show a blank/None path: say what will happen instead.
            var loc = new Cli.Location(null, null);
            Assert.AreEqual(
                "Resolved CLI: not found — the PrefabLens window downloads v0.7.1 on its next refresh",
                PrefabLensSettings.ResolvedLabel(loc, "0.7.1")
            );
        }

        [Test]
        public void MissingOverrideNoteSurfacesTheBrokenPath()
        {
            // Same state #196 made reportable: an override pointing at a missing file.
            var broken = new Cli.Location("Library/PrefabLens/0.7.1/prefablens", "/gone/prefablens");
            Assert.AreEqual(
                "Override points at a missing file: /gone/prefablens",
                PrefabLensSettings.MissingOverrideNote(broken)
            );
            Assert.IsNull(PrefabLensSettings.MissingOverrideNote(new Cli.Location(null, null)));
        }
    }
}
