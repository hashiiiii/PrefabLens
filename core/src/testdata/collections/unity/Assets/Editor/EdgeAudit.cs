using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEngine;
using Object = UnityEngine.Object;

public static class EdgeAudit
{
    private static string Root => Path.GetFullPath(Path.Combine(Application.dataPath, "../../cases"));

    private static AuditBehaviour.Item Item(string name, int speed = 1) =>
        new AuditBehaviour.Item { name = name, speed = speed };

    private static void Copy(string asset, string name, string side)
    {
        string directory = Path.Combine(Root, name);
        Directory.CreateDirectory(directory);
        File.Copy(asset, Path.Combine(directory, side + ".prefab"), true);
    }

    private static void Change(string asset, Action<AuditBehaviour> change)
    {
        var root = PrefabUtility.LoadPrefabContents(asset);
        try
        {
            var component = root.GetComponent<AuditBehaviour>();
            change(component);
            EditorUtility.SetDirty(component);
            PrefabUtility.RecordPrefabInstancePropertyModifications(component);
            PrefabUtility.SaveAsPrefabAsset(root, asset);
        }
        finally { PrefabUtility.UnloadPrefabContents(root); }
    }

    private static void Case(string asset, string name, Action<AuditBehaviour> ours, Action<AuditBehaviour> theirs)
    {
        byte[] baseline = File.ReadAllBytes(asset);
        Copy(asset, name, "base");
        Change(asset, ours);
        Copy(asset, name, "ours");
        // Each branch must start with the same file IDs and override records.
        File.WriteAllBytes(asset, baseline);
        AssetDatabase.ImportAsset(asset, ImportAssetOptions.ForceUpdate);
        Change(asset, theirs);
        Copy(asset, name, "theirs");
        File.WriteAllBytes(asset, baseline);
        AssetDatabase.ImportAsset(asset, ImportAssetOptions.ForceUpdate);
    }

    private static string Create(string asset, Action<AuditBehaviour> initialize)
    {
        var root = new GameObject("Audit");
        initialize(root.AddComponent<AuditBehaviour>());
        PrefabUtility.SaveAsPrefabAsset(root, asset);
        Object.DestroyImmediate(root);
        return asset;
    }

    public static void Generate()
    {
        EditorSettings.serializationMode = SerializationMode.ForceText;
        Directory.CreateDirectory(Root);
        string plain = Create("Assets/Plain.prefab", c =>
        {
            c.items = new[] { Item("A"), Item("B"), Item("C"), Item("D") };
            c.names = new[] { "A", "B", "C", "D" };
            c.numbers = new[] { 1, 2, 3, 4 };
            c.counts = new Dictionary<string, int> { { "A", 1 }, { "B", 2 }, { "C", 3 }, { "D", 4 } };
        });
        Case(plain, "array-both-append", c => c.names = c.names.Concat(new[] { "Ours" }).ToArray(),
            c => c.names = c.names.Concat(new[] { "Theirs" }).ToArray());
        Case(plain, "array-separate-insert", c => c.names = new[] { "Ours" }.Concat(c.names).ToArray(),
            c => c.names = c.names.Concat(new[] { "Theirs" }).ToArray());
        Case(plain, "int-array-both-append", c => c.numbers = c.numbers.Concat(new[] { 10 }).ToArray(),
            c => c.numbers = c.numbers.Concat(new[] { 20 }).ToArray());
        Case(plain, "dictionary-both-add", c => c.counts.Add("Ours", 10), c => c.counts.Add("Theirs", 20));
        Case(plain, "dictionary-separate-edit", c => c.counts["A"] = 10, c => c.counts["D"] = 40);
        Case(plain, "dictionary-duplicate-key", c => c.counts.Add("New", 10), c =>
        {
            var values = new Dictionary<string, int> { { "New", 20 } };
            foreach (var pair in c.counts) values.Add(pair.Key, pair.Value);
            c.counts = values;
        });

        string source = Create("Assets/Source.prefab", c => { });
        var instance = (GameObject)PrefabUtility.InstantiatePrefab(AssetDatabase.LoadAssetAtPath<GameObject>(source));
        var component = instance.GetComponent<AuditBehaviour>();
        component.items = new[] { Item("A"), Item("B"), Item("C") };
        PrefabUtility.RecordPrefabInstancePropertyModifications(component);
        string variant = "Assets/Variant.prefab";
        PrefabUtility.SaveAsPrefabAsset(instance, variant);
        Object.DestroyImmediate(instance);
        Case(variant, "variant-independent-fields", c => c.left = 10, c => c.right = 20);
        Case(variant, "variant-same-field", c => c.left = 10, c => c.left = 20);
        Case(variant, "variant-remove-and-edit", c => c.items = new[] { Item("B"), Item("C") },
            c => c.items[1].speed = 99);
        Case(variant, "variant-shrink-and-edit", c => c.items = new[] { Item("A") },
            c => c.items[2].speed = 99);
        Case(variant, "variant-both-append", c => c.items = c.items.Concat(new[] { Item("Ours") }).ToArray(),
            c => c.items = c.items.Concat(new[] { Item("Theirs") }).ToArray());
        AssetDatabase.SaveAssets();
        File.WriteAllText(Path.Combine(Root, "unity-version.txt"), Application.unityVersion);
        Debug.Log("Audit fixtures are complete.");
    }

    public static void GenerateDictionaryVariants()
    {
        EditorSettings.serializationMode = SerializationMode.ForceText;
        string source = Create("Assets/DictionarySource.prefab", c => { });
        var instance = (GameObject)PrefabUtility.InstantiatePrefab(AssetDatabase.LoadAssetAtPath<GameObject>(source));
        var component = instance.GetComponent<AuditBehaviour>();
        component.counts = new Dictionary<string, int> { { "A", 1 }, { "B", 1 }, { "C", 1 } };
        PrefabUtility.RecordPrefabInstancePropertyModifications(component);
        string variant = "Assets/DictionaryVariant.prefab";
        PrefabUtility.SaveAsPrefabAsset(instance, variant);
        Object.DestroyImmediate(instance);
        Case(variant, "variant-dictionary-independent-values", c => c.counts["A"] = 10, c => c.counts["C"] = 30);
        Case(variant, "variant-dictionary-remove-and-edit", c => c.counts.Remove("A"), c => c.counts["B"] = 99);
        Case(variant, "variant-dictionary-shrink-and-edit", c =>
        {
            c.counts.Remove("B");
            c.counts.Remove("C");
        }, c => c.counts["C"] = 99);
        AssetDatabase.SaveAssets();
        Debug.Log("Dictionary variant fixtures are complete.");
    }

    public static void InspectDictionaries()
    {
        string asset = "Assets/DictionaryVariant.prefab";
        byte[] original = File.ReadAllBytes(asset);
        try
        {
            foreach (string name in new[] { "variant-dictionary-independent-values", "variant-dictionary-remove-and-edit", "variant-dictionary-shrink-and-edit" })
            {
                string merged = Path.Combine(Root, name, "result.prefab");
                if (!File.Exists(merged) || File.ReadAllText(merged).Contains("<<<<<<<")) continue;
                File.Copy(merged, asset, true);
                AssetDatabase.ImportAsset(asset, ImportAssetOptions.ForceUpdate);
                var root = PrefabUtility.LoadPrefabContents(asset);
                try
                {
                    var c = root.GetComponent<AuditBehaviour>();
                    string values = string.Join(",", c.counts.Select(item => item.Key + ":" + item.Value));
                    File.WriteAllText(Path.Combine(Root, name, "unity-result.txt"), "counts=" + values + "\n");
                }
                finally { PrefabUtility.UnloadPrefabContents(root); }
            }
        }
        finally
        {
            File.WriteAllBytes(asset, original);
            AssetDatabase.ImportAsset(asset, ImportAssetOptions.ForceUpdate);
        }
        Debug.Log("Dictionary variant import is complete.");
    }

    public static void Inspect()
    {
        string asset = "Assets/Variant.prefab";
        byte[] original = File.ReadAllBytes(asset);
        try
        {
            foreach (string name in new[] { "variant-independent-fields", "variant-remove-and-edit", "variant-shrink-and-edit" })
            {
                string merged = Path.Combine(Root, name, "result.prefab");
                if (!File.Exists(merged) || File.ReadAllText(merged).Contains("<<<<<<<")) continue;
                File.Copy(merged, asset, true);
                AssetDatabase.ImportAsset(asset, ImportAssetOptions.ForceUpdate);
                var root = PrefabUtility.LoadPrefabContents(asset);
                try
                {
                    var c = root.GetComponent<AuditBehaviour>();
                    string values = string.Join(",", c.items.Select(item => item.name + ":" + item.speed));
                    File.WriteAllText(Path.Combine(Root, name, "unity-result.txt"),
                        "items=" + values + "\nleft=" + c.left + "\nright=" + c.right + "\n");
                }
                finally { PrefabUtility.UnloadPrefabContents(root); }
            }
        }
        finally
        {
            File.WriteAllBytes(asset, original);
            AssetDatabase.ImportAsset(asset, ImportAssetOptions.ForceUpdate);
        }
        Debug.Log("Audit import is complete.");
    }
}
