using NUnit.Framework;

namespace PrefabLens.Tests
{
    public class CliTests
    {
        [Test]
        public void ReleaseAssetNameCoversAllTargets()
        {
            Assert.AreEqual("prefablens-windows-x64.zip", Cli.ReleaseAssetName(isWindows: true, isMac: false, isArm64: false));
            Assert.AreEqual("prefablens-macos-arm64.zip", Cli.ReleaseAssetName(isWindows: false, isMac: true, isArm64: true));
            Assert.AreEqual("prefablens-macos-x64.zip", Cli.ReleaseAssetName(isWindows: false, isMac: true, isArm64: false));
            Assert.AreEqual("prefablens-linux-x64.zip", Cli.ReleaseAssetName(isWindows: false, isMac: false, isArm64: false));
        }

        [Test]
        public void DownloadUrlPointsAtTheVersionedRelease()
        {
            Assert.AreEqual(
                "https://github.com/hashiiiii/PrefabLens/releases/download/v0.1.0/prefablens-macos-arm64.zip",
                Cli.DownloadUrl("0.1.0", "prefablens-macos-arm64.zip"));
        }

        [Test]
        public void BuildArgsDiffsHeadAgainstTheWorktreeAsJson()
        {
            Assert.AreEqual(new[] { "--git", "HEAD", "Assets/Foo.prefab", "--json" }, Cli.BuildArgs("Assets/Foo.prefab"));
        }

        [Test]
        public void QuoteArgsSurvivesSpacesAndQuotes()
        {
            Assert.AreEqual("\"--git\" \"HEAD\" \"Assets/My Prefab.prefab\" \"--json\"", Cli.QuoteArgs(Cli.BuildArgs("Assets/My Prefab.prefab")));
            Assert.AreEqual("\"a\\\"b\"", Cli.QuoteArgs(new[] { "a\"b" }));
        }
    }
}
