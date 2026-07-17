// Minimal Unity API stand-ins so editor/Editor compiles on the plain dotnet SDK.
// Signatures mirror Unity 2022.3; bodies are inert.
using System;
using UnityEngine.UIElements;

namespace UnityEditor
{
    public class EditorWindow
    {
        public VisualElement rootVisualElement { get; } = new VisualElement();

        public static T GetWindow<T>(string title)
            where T : EditorWindow => throw new NotSupportedException("compile-only stub");
    }

    [AttributeUsage(AttributeTargets.Method)]
    public sealed class MenuItem : Attribute
    {
        public MenuItem(string itemName, bool isValidateFunction = false) { }
    }

    public static class EditorPrefs
    {
        // In-memory store: PathOverride round-trips are real behavior under the
        // DotNet harness (real Unity persists to the registry/plist instead).
        static readonly System.Collections.Generic.Dictionary<string, string> strings = new();

        public static string GetString(string key, string defaultValue) =>
            strings.TryGetValue(key, out var v) ? v : defaultValue;

        public static void SetString(string key, string value) => strings[key] = value;

        public static void DeleteKey(string key) => strings.Remove(key);
    }

    public static class EditorUtility
    {
        public static void DisplayProgressBar(string title, string info, float progress) { }

        public static void ClearProgressBar() { }
    }

    public static class AssetDatabase
    {
        public static string GetAssetPath(UnityEngine.Object assetObject) => "";

        public static string GUIDToAssetPath(string guid) => "";

        public static UnityEngine.Texture GetCachedIcon(string path) => null;
    }

    public static class Selection
    {
        public static UnityEngine.Object activeObject => null;
    }

    public static class EditorGUIUtility
    {
        public static bool isProSkin => false;

        public static UnityEngine.Texture2D FindTexture(string name) => null;
    }
}
