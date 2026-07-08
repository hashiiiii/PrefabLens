using NUnit.Framework;

namespace PrefabLens.Tests
{
    public class UnityYamlPathsTests
    {
        // The full set of text-serialized extensions unityyamlmerge targets.
        // Listed in the camelCase Unity actually emits (.overrideController, etc.).
        static readonly string[] Supported =
        {
            ".prefab",
            ".unity",
            ".asset",
            ".mat",
            ".anim",
            ".controller",
            ".overrideController",
            ".physicMaterial",
            ".physicsMaterial2D",
            ".playable",
            ".mask",
            ".brush",
            ".flare",
            ".fontsettings",
            ".guiskin",
            ".giparams",
            ".renderTexture",
            ".spriteatlas",
            ".spriteatlasv2",
            ".terrainlayer",
            ".mixer",
            ".shadervariants",
            ".preset",
            ".signal",
            ".lighting",
            ".scenetemplate",
        };

        [Test]
        public void AcceptsEveryUnityYamlExtension()
        {
            foreach (var ext in Supported)
                Assert.IsTrue(UnityYamlPaths.IsSupported("Assets/Sample" + ext), ext);
        }

        [Test]
        public void IsCaseInsensitive()
        {
            // Unity writes lowercase extensions, but manually renamed files are accepted too
            Assert.IsTrue(UnityYamlPaths.IsSupported("Assets/FOO.PREFAB"));
            Assert.IsTrue(UnityYamlPaths.IsSupported("Assets/Sample.Mat"));
        }

        [Test]
        public void RejectsNonUnityYamlPaths()
        {
            // .meta isn't !u! document format and .asmdef is JSON. A partial match (.matx) is rejected too
            Assert.IsFalse(UnityYamlPaths.IsSupported("Assets/Foo.prefab.meta"));
            Assert.IsFalse(UnityYamlPaths.IsSupported("Assets/Code.asmdef"));
            Assert.IsFalse(UnityYamlPaths.IsSupported("Assets/T.matx"));
            Assert.IsFalse(UnityYamlPaths.IsSupported(""));
        }
    }
}
