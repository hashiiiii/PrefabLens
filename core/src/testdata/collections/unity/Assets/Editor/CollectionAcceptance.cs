using System;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEngine;

public static class CollectionAcceptance
{
    [Serializable]
    private class Manifest { public Case[] cases; }

    [Serializable]
    private class Case
    {
        public string name;
        public string[] names;
        public int[] numbers;
        public string[] items;
        public string[] counts;
        public bool scalarFields;
        public int left;
        public int right;
        public int hidden;
        public bool sourceContext;
    }

    public static void Verify()
    {
        string root = Path.GetFullPath(Path.Combine(Application.dataPath, "../.."));
        var manifest = JsonUtility.FromJson<Manifest>(File.ReadAllText(Path.Combine(root, "expected-runtime.json")));
        foreach (var expected in manifest.cases)
        {
            bool replay = expected.name.StartsWith("replay-", StringComparison.Ordinal);
            string asset = replay ? "Assets/ReplayVariant.prefab"
                : expected.name.StartsWith("variant-dictionary-", StringComparison.Ordinal)
                ? "Assets/DictionaryVariant.prefab"
                : expected.name.StartsWith("variant-", StringComparison.Ordinal)
                    ? "Assets/Variant.prefab" : "Assets/Plain.prefab";
            string directory = Path.Combine(root, "cases", expected.name);
            string result = File.ReadAllText(Path.Combine(directory, "result.prefab"));
            if (result.Contains("<<<<<<<")) throw new Exception(expected.name + ": unresolved result");
            byte[] original = File.ReadAllBytes(asset);
            byte[] originalSource = expected.sourceContext ? File.ReadAllBytes("Assets/Source.prefab") : null;
            try
            {
                if (expected.sourceContext)
                {
                    File.Copy(Path.Combine(directory, "output-source.prefab"), "Assets/Source.prefab", true);
                }
                File.WriteAllText(asset, result);
                // Refresh both files before Unity imports their dependency graph.
                AssetDatabase.Refresh(ImportAssetOptions.ForceUpdate | ImportAssetOptions.ForceSynchronousImport);
                var instance = PrefabUtility.LoadPrefabContents(asset);
                try
                {
                    if (replay)
                    {
                        var value = instance.GetComponent<ReplayBehaviour>();
                        if (value == null) throw new Exception(expected.name + ": missing replay component");
                        Equal(expected.name, "items", expected.items, value.items.Select(x => x.name + ":" + x.speed).ToArray());
                        // The expected value comes from the observed unmodified fixture, not its C# initializer.
                        if (value.items.Any(x => x.hidden != expected.hidden))
                            throw new Exception(expected.name + ": changed omitted member");
                    }
                    else
                    {
                        var value = instance.GetComponent<AuditBehaviour>();
                        if (value == null) throw new Exception(expected.name + ": missing component");
                        Equal(expected.name, "names", expected.names, value.names);
                        if (expected.numbers != null)
                            Equal(expected.name, "numbers", expected.numbers.Select(x => x.ToString()).ToArray(), value.numbers.Select(x => x.ToString()).ToArray());
                        Equal(expected.name, "items", expected.items, value.items.Select(x => x.name + ":" + x.speed).ToArray());
                        if (expected.counts != null)
                            Equal(expected.name, "counts", expected.counts.OrderBy(x => x, StringComparer.Ordinal).ToArray(), value.counts.Select(x => x.Key + ":" + x.Value).OrderBy(x => x, StringComparer.Ordinal).ToArray());
                        if (expected.scalarFields && (value.left != expected.left || value.right != expected.right))
                            throw new Exception(expected.name + ": wrong independent fields");
                    }
                    File.WriteAllText(Path.Combine(directory, "unity-result.txt"), "version=" + Application.unityVersion + "\nverified=" + expected.name + "\n");
                }
                finally { PrefabUtility.UnloadPrefabContents(instance); }
            }
            finally
            {
                // Keep the fixed source IDs and baseline files for the next case.
                File.WriteAllBytes(asset, original);
                if (originalSource != null)
                {
                    File.WriteAllBytes("Assets/Source.prefab", originalSource);
                }
                AssetDatabase.Refresh(ImportAssetOptions.ForceUpdate | ImportAssetOptions.ForceSynchronousImport);
            }
        }
        Debug.Log("Verified " + manifest.cases.Length + " collection merge results on " + Application.unityVersion + ".");
    }

    private static void Equal(string name, string field, string[] expected, string[] actual)
    {
        if (expected != null && !expected.SequenceEqual(actual))
            throw new Exception(name + ": " + field + " expected [" + string.Join(",", expected) + "] but got [" + string.Join(",", actual) + "]");
    }
}
