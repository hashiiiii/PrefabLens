using NUnit.Framework;

namespace PrefabLens.Tests
{
    public class UnityYamlPathsTests
    {
        // unityyamlmerge が対象とするテキストシリアライズ済み拡張子の全集合。
        // Unity の実出力どおりの camelCase(.overrideController 等)で列挙する。
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
            // Unity は小文字拡張子で書き出すが、手動リネームされたファイルも受け付ける
            Assert.IsTrue(UnityYamlPaths.IsSupported("Assets/FOO.PREFAB"));
            Assert.IsTrue(UnityYamlPaths.IsSupported("Assets/Sample.Mat"));
        }

        [Test]
        public void RejectsNonUnityYamlPaths()
        {
            // .meta は !u! ドキュメント形式でなく、.asmdef は JSON。部分一致(.matx)も不可
            Assert.IsFalse(UnityYamlPaths.IsSupported("Assets/Foo.prefab.meta"));
            Assert.IsFalse(UnityYamlPaths.IsSupported("Assets/Code.asmdef"));
            Assert.IsFalse(UnityYamlPaths.IsSupported("Assets/T.matx"));
            Assert.IsFalse(UnityYamlPaths.IsSupported(""));
        }
    }
}
