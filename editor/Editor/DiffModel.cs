using System;
using System.Collections.Generic;
using Newtonsoft.Json.Linq;

namespace PrefabLens
{
    public enum DiffStatus { Added, Removed, Modified, Unchanged }

    /// diff.v2 のフィールド値: scalar / ref / null の 3 態。
    public sealed class Value
    {
        public string Scalar;      // scalar のときのみ
        public string RefFileId;   // ref のときのみ
        public string RefGuid;     // ref かつ外部参照のときのみ
        public bool IsRef;
        public bool IsNull;

        public static readonly Value Null = new Value { IsNull = true };
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
        public List<FieldDiff> Fields = new List<FieldDiff>();
    }

    public abstract class NodeDiff
    {
        public string FileId;
        public string Name;
        public DiffStatus Status;
        public List<ComponentDiff> Components = new List<ComponentDiff>();
        public List<NodeDiff> Children = new List<NodeDiff>();
    }

    public sealed class GameObjectDiff : NodeDiff { }

    public sealed class PrefabInstanceDiff : NodeDiff
    {
        public string SourceGuid;
        public List<OverrideDiff> Overrides = new List<OverrideDiff>();
    }

    /// prefablens.diff.v2(core/src/json.zig の出力)の読み取り側モデル。
    /// 未知の kind やフィールド欠損は落とさず読み飛ばす(CLI が新しい場合に Editor 側が壊れない)。
    public sealed class DiffModel
    {
        public List<string> UnresolvedGuids = new List<string>();
        public Dictionary<string, string> Resolved = new Dictionary<string, string>();
        public List<NodeDiff> Roots = new List<NodeDiff>();
        public List<ComponentDiff> Loose = new List<ComponentDiff>();

        public bool IsEmpty => Roots.Count == 0 && Loose.Count == 0;

        public static DiffModel Parse(string json)
        {
            var o = JObject.Parse(json);
            var m = new DiffModel();
            foreach (var g in o["unresolvedGuids"] as JArray ?? new JArray())
                m.UnresolvedGuids.Add((string)g);
            if (o["resolved"] is JObject resolved)
                foreach (var p in resolved.Properties())
                    m.Resolved[p.Name] = (string)p.Value;
            foreach (var r in o["roots"] as JArray ?? new JArray())
                if (ParseNode(r as JObject) is NodeDiff n)
                    m.Roots.Add(n);
            foreach (var c in o["loose"] as JArray ?? new JArray())
                if (c is JObject co)
                    m.Loose.Add(ParseComponent(co));
            return m;
        }

        /// Editor 内では AssetDatabase で guid を完全解決できる(Chrome 版より強い)。
        public void ResolveWith(Func<string, string> guidToPath)
        {
            foreach (var g in UnresolvedGuids)
            {
                if (Resolved.ContainsKey(g)) continue;
                var path = guidToPath(g);
                if (!string.IsNullOrEmpty(path)) Resolved[g] = path;
            }
        }

        static NodeDiff ParseNode(JObject o)
        {
            if (o == null) return null;
            NodeDiff n;
            switch ((string)o["kind"])
            {
                case "gameObject":
                    n = new GameObjectDiff();
                    break;
                case "prefabInstance":
                    var pi = new PrefabInstanceDiff { SourceGuid = (string)o["sourceGuid"] };
                    foreach (var ov in o["overrides"] as JArray ?? new JArray())
                        if (ov is JObject ovo)
                            pi.Overrides.Add(new OverrideDiff
                            {
                                Group = (string)ovo["group"] ?? "",
                                Label = (string)ovo["label"] ?? "",
                                Status = ParseStatus((string)ovo["status"]),
                                Before = ParseValue(ovo["before"]),
                                After = ParseValue(ovo["after"]),
                            });
                    n = pi;
                    break;
                default:
                    return null; // 未知の kind は読み飛ばす
            }
            n.FileId = (string)o["fileId"] ?? "";
            n.Name = (string)o["name"] ?? "";
            n.Status = ParseStatus((string)o["status"]);
            foreach (var c in o["components"] as JArray ?? new JArray())
                if (c is JObject co)
                    n.Components.Add(ParseComponent(co));
            foreach (var ch in o["children"] as JArray ?? new JArray())
                if (ParseNode(ch as JObject) is NodeDiff child)
                    n.Children.Add(child);
            return n;
        }

        static ComponentDiff ParseComponent(JObject o)
        {
            var c = new ComponentDiff
            {
                FileId = (string)o["fileId"] ?? "",
                ClassId = (int?)o["classId"] ?? 0,
                TypeName = (string)o["typeName"] ?? "",
                ScriptGuid = (string)o["scriptGuid"],
                ClassName = (string)o["className"],
                Status = ParseStatus((string)o["status"]),
            };
            foreach (var f in o["fields"] as JArray ?? new JArray())
                if (f is JObject fo)
                    c.Fields.Add(new FieldDiff
                    {
                        Path = (string)fo["path"] ?? "",
                        Status = ParseStatus((string)fo["status"]),
                        Before = ParseValue(fo["before"]),
                        After = ParseValue(fo["after"]),
                    });
            return c;
        }

        static Value ParseValue(JToken t)
        {
            if (t == null || t.Type == JTokenType.Null) return Value.Null;
            if (t is JObject o && o["ref"] is JObject r)
                return new Value { IsRef = true, RefFileId = (string)r["fileId"] ?? "0", RefGuid = (string)r["guid"] };
            return new Value { Scalar = (string)t };
        }

        static DiffStatus ParseStatus(string s)
        {
            switch (s)
            {
                case "added": return DiffStatus.Added;
                case "removed": return DiffStatus.Removed;
                case "modified": return DiffStatus.Modified;
                default: return DiffStatus.Unchanged;
            }
        }
    }
}
