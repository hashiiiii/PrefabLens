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
        public void OverrideErrorNoteSurfacesTheValidationError()
        {
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
