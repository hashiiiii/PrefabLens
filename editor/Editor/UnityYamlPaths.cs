using System;

namespace PrefabLens
{
    /// Unity がテキストシリアライズ(UnityYAML)するアセット拡張子の判定。
    /// unityyamlmerge の対象と同じ集合。.meta(!u! ドキュメント形式でない)と
    /// .asmdef 等の JSON は対象外。
    public static class UnityYamlPaths
    {
        static readonly string[] Extensions =
        {
            ".prefab", ".unity", ".asset", ".mat", ".anim", ".controller", ".overrideController",
            ".physicMaterial", ".physicsMaterial2D", ".playable", ".mask", ".brush", ".flare",
            ".fontsettings", ".guiskin", ".giparams", ".renderTexture", ".spriteatlas",
            ".spriteatlasv2", ".terrainlayer", ".mixer", ".shadervariants", ".preset", ".signal",
            ".lighting", ".scenetemplate",
        };

        public static bool IsSupported(string path)
        {
            foreach (var ext in Extensions)
                if (path.EndsWith(ext, StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }
    }
}
