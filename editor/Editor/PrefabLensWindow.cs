using System;
using System.Collections.Generic;
using System.IO;
using UnityEditor;
using UnityEngine;
using UnityEngine.UIElements;

namespace PrefabLens
{
    /// 選択アセットの「HEAD vs 作業ツリー」意味的 diff を表示する(Phase 3 ウォーキングスケルトン)。
    public sealed class PrefabLensWindow : EditorWindow
    {
        [SerializeField] string assetPath = "";

        Label status;
        VisualElement content;

        [MenuItem("Window/PrefabLens")]
        public static void Open() => GetWindow<PrefabLensWindow>("PrefabLens");

        [MenuItem("Assets/PrefabLens: Diff vs HEAD")]
        static void DiffSelected()
        {
            var w = GetWindow<PrefabLensWindow>("PrefabLens");
            w.assetPath = AssetDatabase.GetAssetPath(Selection.activeObject);
            w.Refresh();
        }

        [MenuItem("Assets/PrefabLens: Diff vs HEAD", true)]
        static bool ValidateDiffSelected()
        {
            var p = Selection.activeObject == null ? "" : AssetDatabase.GetAssetPath(Selection.activeObject);
            return UnityYamlPaths.IsSupported(p);
        }

        public void CreateGUI()
        {
            var toolbar = new VisualElement { style = { flexDirection = FlexDirection.Row, marginTop = 4, marginBottom = 4 } };
            status = new Label { style = { flexGrow = 1, unityTextAlign = TextAnchor.MiddleLeft, marginLeft = 6 } };
            toolbar.Add(status);
            toolbar.Add(new Button(Refresh) { text = "Refresh" });
            rootVisualElement.Add(toolbar);

            content = new VisualElement { style = { flexGrow = 1 } };
            rootVisualElement.Add(content);
            Refresh();
        }

        void Refresh()
        {
            content.Clear();
            if (string.IsNullOrEmpty(assetPath))
            {
                status.text = "Select a UnityYAML asset (.prefab / .unity / .asset / .mat / .anim / …) and run Assets → PrefabLens: Diff vs HEAD";
                return;
            }
            status.text = assetPath;

            var cli = Cli.Find();
            if (cli == null)
            {
                Note($"prefablens CLI not found (v{Cli.Version}).");
                content.Add(new Button(DownloadThenRefresh) { text = "Download from GitHub Releases", style = { alignSelf = Align.FlexStart, marginLeft = 6 } });
                Note($"Or set a manual path via EditorPrefs key '{Cli.CliPathPref}'.");
                return;
            }

            var res = Cli.Run(cli, assetPath);
            if (res.ExitCode != 0)
            {
                // CLI の stderr が一次情報(非 git リポジトリ・不正 ref 等)
                Note(string.IsNullOrEmpty(res.Stderr) ? $"prefablens exited with {res.ExitCode}" : res.Stderr.Trim());
                return;
            }

            DiffModel model;
            try
            {
                model = DiffModel.Parse(res.Stdout);
            }
            catch (Exception)
            {
                Note("Could not parse CLI output (CLI version mismatch?):");
                Note(res.Stdout.Length > 200 ? res.Stdout.Substring(0, 200) + "…" : res.Stdout);
                return;
            }

            model.ResolveWith(AssetDatabase.GUIDToAssetPath);
            if (model.IsEmpty)
            {
                Note("No semantic changes");
                return;
            }
            content.Add(BuildTree(model));
        }

        void DownloadThenRefresh()
        {
            try
            {
                Cli.Download();
            }
            catch (Exception e)
            {
                content.Clear();
                Note($"Download failed: {e.Message}");
                Note($"You can place the binary manually and set EditorPrefs '{Cli.CliPathPref}'.");
                return;
            }
            Refresh();
        }

        void Note(string text)
        {
            content.Add(new Label(text) { style = { marginLeft = 6, marginTop = 2, whiteSpace = WhiteSpace.Normal } });
        }

        // ---- ツリー描画(Chrome 版レンダラと同じ配色トーン・記法) ----
        // rich text は使わない: リポジトリ由来文字列をマークアップ解釈させない(Chrome 版の XSS テストと同じ思想)。

        static class Palette
        {
            public static Color Added => Hex(EditorGUIUtility.isProSkin ? 0x3fb950 : 0x1a7f37);
            public static Color Removed => Hex(EditorGUIUtility.isProSkin ? 0xf85149 : 0xcf222e);
            public static Color Modified => Hex(EditorGUIUtility.isProSkin ? 0xd29922 : 0x9a6700);
            public static Color Muted => Hex(EditorGUIUtility.isProSkin ? 0x9198a1 : 0x59636e);

            static Color Hex(int rgb) => new Color(((rgb >> 16) & 0xff) / 255f, ((rgb >> 8) & 0xff) / 255f, (rgb & 0xff) / 255f);
        }

        readonly struct Span
        {
            public readonly string Text;
            public readonly Color? Tint;

            public Span(string text, Color? tint = null)
            {
                Text = text;
                Tint = tint;
            }
        }

        sealed class Row
        {
            public readonly List<Span> Spans = new();

            public Row Add(string text, Color? tint = null)
            {
                if (!string.IsNullOrEmpty(text)) Spans.Add(new Span(text, tint));
                return this;
            }
        }

        static TreeView BuildTree(DiffModel model)
        {
            var id = 0;
            var items = new List<TreeViewItemData<Row>>();
            foreach (var n in model.Roots) items.Add(NodeItem(n, model, ref id));
            foreach (var c in model.Loose) items.Add(ComponentItem(c, model, ref id));

            var tree = new TreeView { fixedItemHeight = 18, style = { flexGrow = 1 } };
            tree.SetRootItems(items);
            tree.makeItem = () => new VisualElement { style = { flexDirection = FlexDirection.Row, alignItems = Align.Center } };
            tree.bindItem = (e, i) =>
            {
                e.Clear();
                foreach (var span in tree.GetItemDataForIndex<Row>(i).Spans)
                {
                    var l = new Label(span.Text) { style = { marginLeft = 0, marginRight = 0, paddingLeft = 0, paddingRight = 0 } };
                    if (span.Tint is Color tint) l.style.color = tint;
                    e.Add(l);
                }
            };
            tree.ExpandAll();
            return tree;
        }

        static TreeViewItemData<Row> NodeItem(NodeDiff n, DiffModel m, ref int id)
        {
            var pi = n as PrefabInstanceDiff;
            var children = new List<TreeViewItemData<Row>>();
            if (pi != null)
                foreach (var ov in pi.Overrides)
                    children.Add(new TreeViewItemData<Row>(id++, OverrideRow(ov, m)));
            foreach (var c in n.Components) children.Add(ComponentItem(c, m, ref id));
            foreach (var ch in n.Children) children.Add(NodeItem(ch, m, ref id));

            var row = Badge(n.Status).Add(n.Name);
            if (pi?.SourceGuid != null)
                row.Add(" ‹Prefab: " + (m.Resolved.TryGetValue(pi.SourceGuid, out var src) ? src : pi.SourceGuid) + "›", Palette.Muted);
            return new TreeViewItemData<Row>(id++, row, children);
        }

        static TreeViewItemData<Row> ComponentItem(ComponentDiff c, DiffModel m, ref int id)
        {
            var children = new List<TreeViewItemData<Row>>();
            foreach (var f in c.Fields)
                children.Add(new TreeViewItemData<Row>(id++, FieldRow(f.Path, f.Status, f.Before, f.After, m)));

            var row = Badge(c.Status);
            if (!string.IsNullOrEmpty(c.ClassName))
                row.Add(c.ClassName).Add(" ‹Script›", Palette.Muted);
            else if (c.ScriptGuid != null && m.Resolved.TryGetValue(c.ScriptGuid, out var p))
                row.Add(Stem(p)).Add(" ‹Script›", Palette.Muted);
            else
                row.Add(c.TypeName);
            return new TreeViewItemData<Row>(id++, row, children);
        }

        static Row OverrideRow(OverrideDiff ov, DiffModel m)
        {
            var label = ov.Group.Length > 0 && ov.Group != "Overrides" ? ov.Group + " / " + ov.Label : ov.Label;
            return FieldRow(label, ov.Status, ov.Before, ov.After, m);
        }

        static Row FieldRow(string label, DiffStatus status, Value before, Value after, DiffModel m)
        {
            var row = Badge(status).Add(label + " ", Palette.Muted);
            var b = Format(before, m);
            var a = Format(after, m);
            if (status == DiffStatus.Modified)
                row.Add(b, Palette.Removed).Add(" → ", Palette.Muted).Add(a, Palette.Added);
            else if (status == DiffStatus.Removed)
                row.Add(b, Palette.Removed);
            else
                row.Add(a, status == DiffStatus.Added ? Palette.Added : (Color?)null);
            return row;
        }

        static string Format(Value v, DiffModel m)
        {
            if (v == null || v.IsNull) return "";
            if (!v.IsRef) return v.Scalar ?? "";
            if (v.RefGuid != null)
                return m.Resolved.TryGetValue(v.RefGuid, out var p) ? Stem(p) : v.RefGuid;
            return v.RefFileId == "0" ? "None" : "#" + v.RefFileId;
        }

        static Row Badge(DiffStatus s) => s switch
        {
            DiffStatus.Added => new Row().Add("+ ", Palette.Added),
            DiffStatus.Removed => new Row().Add("− ", Palette.Removed),
            DiffStatus.Modified => new Row().Add("~ ", Palette.Modified),
            _ => new Row().Add("  "),
        };

        static string Stem(string path)
        {
            var name = Path.GetFileNameWithoutExtension(path);
            return string.IsNullOrEmpty(name) ? path : name;
        }
    }
}
