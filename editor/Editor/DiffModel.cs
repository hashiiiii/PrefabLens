using System;
using System.Collections.Generic;
using System.Globalization;
using PrefabLens.MiniJson;

namespace PrefabLens
{
    public enum DiffStatus
    {
        Added,
        Removed,
        Modified,
        Unchanged,
    }

    /// A diff.v2 field value: one of three states — scalar / ref / null.
    public sealed class Value
    {
        public string Scalar; // only when scalar
        public string RefFileId; // only when ref
        public string RefGuid; // only when ref and an external reference
        public bool IsRef;
        public bool IsNull;

        public static readonly Value Null = new() { IsNull = true };
    }

    public sealed class FieldDiff
    {
        public string Path;
        public DiffStatus Status;
        public Value Before;
        public Value After;
    }

    public sealed class OverrideDiff
    {
        public string Group;
        public string Label;
        public DiffStatus Status;
        public Value Before;
        public Value After;
    }

    public sealed class ComponentDiff
    {
        public string FileId;
        public int ClassId;
        public string TypeName;
        public string ScriptGuid;
        public string ClassName;
        public DiffStatus Status;
        public List<FieldDiff> Fields = new();
    }

    public abstract class NodeDiff
    {
        public string FileId;
        public string Name;
        public DiffStatus Status;
        public List<ComponentDiff> Components = new();
        public List<NodeDiff> Children = new();
    }

    public sealed class GameObjectDiff : NodeDiff { }

    public sealed class PrefabInstanceDiff : NodeDiff
    {
        public string SourceGuid;
        public List<OverrideDiff> Overrides = new();
    }

    /// Reader-side model for prefablens.diff.v2 (the output of core/src/json.zig).
    /// Unknown kinds and missing fields are skipped rather than failing (so the Editor doesn't break when the CLI is newer).
    public sealed class DiffModel
    {
        public List<string> UnresolvedGuids = new();
        public Dictionary<string, string> Resolved = new();
        public List<NodeDiff> Roots = new();
        public List<ComponentDiff> Loose = new();

        public bool IsEmpty => Roots.Count == 0 && Loose.Count == 0;

        public static DiffModel Parse(string json)
        {
            // MiniJSON returns null on malformed input rather than throwing. Convert back to a throw here
            // so the Window's "Could not parse CLI output" branch (which catches the Exception) works.
            if (Json.Deserialize(json) is not Dictionary<string, object> o)
                throw new FormatException("diff json root is not an object");
            var m = new DiffModel();
            foreach (var g in Items(o, "unresolvedGuids"))
                if (g is string s)
                    m.UnresolvedGuids.Add(s);
            if (Val(o, "resolved") is Dictionary<string, object> resolved)
                foreach (var p in resolved)
                    if (p.Value is string path)
                        m.Resolved[p.Key] = path;
            foreach (var r in Items(o, "roots"))
                if (ParseNode(r as Dictionary<string, object>) is NodeDiff n)
                    m.Roots.Add(n);
            foreach (var c in Items(o, "loose"))
                if (c is Dictionary<string, object> co)
                    m.Loose.Add(ParseComponent(co));
            return m;
        }

        /// Inside the Editor, AssetDatabase can fully resolve guids (stronger than the Chrome build).
        public void ResolveWith(Func<string, string> guidToPath)
        {
            foreach (var g in UnresolvedGuids)
            {
                if (Resolved.ContainsKey(g))
                    continue;
                var path = guidToPath(g);
                if (!string.IsNullOrEmpty(path))
                    Resolved[g] = path;
            }
        }

        static NodeDiff ParseNode(Dictionary<string, object> o)
        {
            if (o == null)
                return null;
            NodeDiff n = Str(o, "kind") switch
            {
                "gameObject" => new GameObjectDiff(),
                "prefabInstance" => ParsePrefabInstance(o),
                _ => null, // skip unknown kinds
            };
            if (n == null)
                return null;
            n.FileId = Str(o, "fileId") ?? "";
            n.Name = Str(o, "name") ?? "";
            n.Status = ParseStatus(Str(o, "status"));
            foreach (var c in Items(o, "components"))
                if (c is Dictionary<string, object> co)
                    n.Components.Add(ParseComponent(co));
            foreach (var ch in Items(o, "children"))
                if (ParseNode(ch as Dictionary<string, object>) is NodeDiff child)
                    n.Children.Add(child);
            return n;
        }

        static PrefabInstanceDiff ParsePrefabInstance(Dictionary<string, object> o)
        {
            var pi = new PrefabInstanceDiff { SourceGuid = Str(o, "sourceGuid") };
            foreach (var ov in Items(o, "overrides"))
                if (ov is Dictionary<string, object> ovo)
                    pi.Overrides.Add(
                        new OverrideDiff
                        {
                            Group = Str(ovo, "group") ?? "",
                            Label = Str(ovo, "label") ?? "",
                            Status = ParseStatus(Str(ovo, "status")),
                            Before = ParseValue(Val(ovo, "before")),
                            After = ParseValue(Val(ovo, "after")),
                        }
                    );
            return pi;
        }

        static ComponentDiff ParseComponent(Dictionary<string, object> o)
        {
            var c = new ComponentDiff
            {
                FileId = Str(o, "fileId") ?? "",
                ClassId = Val(o, "classId") is long id ? (int)id : 0,
                TypeName = Str(o, "typeName") ?? "",
                ScriptGuid = Str(o, "scriptGuid"),
                ClassName = Str(o, "className"),
                Status = ParseStatus(Str(o, "status")),
            };
            foreach (var f in Items(o, "fields"))
                if (f is Dictionary<string, object> fo)
                    c.Fields.Add(
                        new FieldDiff
                        {
                            Path = Str(fo, "path") ?? "",
                            Status = ParseStatus(Str(fo, "status")),
                            Before = ParseValue(Val(fo, "before")),
                            After = ParseValue(Val(fo, "after")),
                        }
                    );
            return c;
        }

        static Value ParseValue(object t)
        {
            if (t == null)
                return Value.Null;
            if (t is Dictionary<string, object> o && Val(o, "ref") is Dictionary<string, object> r)
                return new Value
                {
                    IsRef = true,
                    RefFileId = Str(r, "fileId") ?? "0",
                    RefGuid = Str(r, "guid"),
                };
            return new Value { Scalar = ScalarString(t) };
        }

        /// The CLI emits scalars as strings, but if a number / bool arrives, stringify it in JSON notation.
        static string ScalarString(object t) =>
            t switch
            {
                string s => s,
                bool b => b ? "true" : "false",
                IFormattable f => f.ToString(null, CultureInfo.InvariantCulture),
                _ => t.ToString(),
            };

        static readonly List<object> EmptyList = new();

        static string Str(Dictionary<string, object> o, string key) =>
            o.TryGetValue(key, out var v) ? v as string : null;

        static object Val(Dictionary<string, object> o, string key) => o.TryGetValue(key, out var v) ? v : null;

        static List<object> Items(Dictionary<string, object> o, string key) => Val(o, key) as List<object> ?? EmptyList;

        static DiffStatus ParseStatus(string s) =>
            s switch
            {
                "added" => DiffStatus.Added,
                "removed" => DiffStatus.Removed,
                "modified" => DiffStatus.Modified,
                _ => DiffStatus.Unchanged,
            };
    }
}
