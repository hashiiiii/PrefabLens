using System;

namespace PrefabLens
{
    /// Decides which asset extensions Unity text-serializes (UnityYAML).
    /// The same set as unityyamlmerge targets. Excludes .meta (not !u! document format) and
    /// JSON such as .asmdef.
    public static class UnityYamlPaths
    {
        static readonly string[] Extensions =
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

        public static bool IsSupported(string path)
        {
            foreach (var ext in Extensions)
                if (path.EndsWith(ext, StringComparison.OrdinalIgnoreCase))
                    return true;
            return false;
        }
    }
}
