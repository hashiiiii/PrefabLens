using System;
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
        });
        Case(plain, "array-both-append", c => c.names = c.names.Concat(new[] { "Ours" }).ToArray(),
            c => c.names = c.names.Concat(new[] { "Theirs" }).ToArray());
        Case(plain, "array-separate-insert", c => c.names = new[] { "Ours" }.Concat(c.names).ToArray(),
            c => c.names = c.names.Concat(new[] { "Theirs" }).ToArray());
        Case(plain, "int-array-both-append", c => c.numbers = c.numbers.Concat(new[] { 10 }).ToArray(),
            c => c.numbers = c.numbers.Concat(new[] { 20 }).ToArray());
        AssetDatabase.SaveAssets();
        File.WriteAllText(Path.Combine(Root, "unity-version.txt"), Application.unityVersion);
        Debug.Log("Array fixtures are complete.");
    }
}
