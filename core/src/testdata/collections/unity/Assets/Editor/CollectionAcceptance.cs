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
    }

    public static void Verify()
    {
        string root = Path.GetFullPath(Path.Combine(Application.dataPath, "../.."));
        var manifest = JsonUtility.FromJson<Manifest>(File.ReadAllText(Path.Combine(root, "expected-runtime.json")));
        foreach (var expected in manifest.cases)
        {
            string asset = "Assets/Plain.prefab";
            string directory = Path.Combine(root, "cases", expected.name);
            string result = File.ReadAllText(Path.Combine(directory, "result.prefab"));
            if (result.Contains("<<<<<<<")) throw new Exception(expected.name + ": unresolved result");
            byte[] original = File.ReadAllBytes(asset);
            try
            {
                File.WriteAllText(asset, result);
                // Refresh the file before Unity imports it.
                AssetDatabase.Refresh(ImportAssetOptions.ForceUpdate | ImportAssetOptions.ForceSynchronousImport);
                var instance = PrefabUtility.LoadPrefabContents(asset);
                try
                {
                    var value = instance.GetComponent<AuditBehaviour>();
                    if (value == null) throw new Exception(expected.name + ": missing component");
                    Equal(expected.name, "names", expected.names, value.names);
                    if (expected.numbers != null)
                        Equal(expected.name, "numbers", expected.numbers.Select(x => x.ToString()).ToArray(), value.numbers.Select(x => x.ToString()).ToArray());
                    File.WriteAllText(Path.Combine(directory, "unity-result.txt"), "version=" + Application.unityVersion + "\nverified=" + expected.name + "\n");
                }
                finally { PrefabUtility.UnloadPrefabContents(instance); }
            }
            finally
            {
                // Keep the fixed file IDs and baseline files for the next case.
                File.WriteAllBytes(asset, original);
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
