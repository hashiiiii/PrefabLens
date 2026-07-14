using System;
using System.Collections.Generic;
using System.IO;
using UnityEditor;
using UnityEngine;
using UnityEngine.UIElements;

namespace PrefabLens
{
    /// Master-detail view: UnityYAML assets that differ from HEAD on the left,
    /// the selected asset's semantic diff on the right.
    public sealed class PrefabLensWindow : EditorWindow
    {
        Label status;
        ListView list;
        VisualElement content;
        BulkModel bulk = new();
        string selectedPath;
        string pendingSelectPath;
        bool refreshing;

        [MenuItem("Window/PrefabLens")]
        public static void Open() => GetWindow<PrefabLensWindow>("PrefabLens");

        [MenuItem("Assets/PrefabLens: Diff vs HEAD")]
        static void DiffSelected()
        {
            var w = GetWindow<PrefabLensWindow>("PrefabLens");
            w.pendingSelectPath = AssetDatabase.GetAssetPath(Selection.activeObject);
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
            var toolbar = new VisualElement
            {
                style =
                {
                    flexDirection = FlexDirection.Row,
                    marginTop = 4,
                    marginBottom = 4,
                },
            };
            status = new Label
            {
                style =
                {
                    flexGrow = 1,
                    unityTextAlign = TextAnchor.MiddleLeft,
                    marginLeft = 6,
                },
            };
            toolbar.Add(status);
            toolbar.Add(new Button(Refresh) { text = "Refresh" });
            rootVisualElement.Add(toolbar);

            var split = new TwoPaneSplitView(0, 240, TwoPaneSplitViewOrientation.Horizontal);
            list = new ListView { fixedItemHeight = 20 };
            list.makeItem = () =>
                new VisualElement { style = { flexDirection = FlexDirection.Row, alignItems = Align.Center } };
            list.bindItem = (e, i) => RenderRow(e, EntryRow(bulk.Entries[i]));
            list.selectionChanged += OnSelectionChanged;
            split.Add(list);
            content = new VisualElement { style = { flexGrow = 1 } };
            split.Add(content);
            rootVisualElement.Add(split);
            Refresh();
        }

        /// Unity calls this whenever the window gains focus; before CreateGUI on first open.
        void OnFocus()
        {
            if (content != null)
                Refresh();
        }

        void Refresh()
        {
            if (content == null || refreshing)
                return;
            var cli = Cli.Find();
            if (cli == null)
            {
                ShowMissingCli();
                return;
            }
            refreshing = true;
            status.text = "Refreshing…";
            Cli.RunBulkAsync(cli, OnBulkDone);
        }

        void OnBulkDone(Cli.Result res)
        {
            refreshing = false;
            // Consume the menu's pending selection on every completion path, success or not,
            // so a failed run cannot leak it into a later unrelated refresh.
            var wanted = pendingSelectPath ?? selectedPath;
            var menuInvoked = pendingSelectPath != null;
            pendingSelectPath = null;
            if (content == null)
                return; // unreachable given Refresh's own guard; kept as cheap defense
            content.Clear();
            if (res.ExitCode != 0)
            {
                // The CLI's stderr is the primary source (non-git repository, timeout, etc.)
                status.text = "";
                Note(string.IsNullOrEmpty(res.Stderr) ? $"prefablens exited with {res.ExitCode}" : res.Stderr.Trim());
                return;
            }
            try
            {
                bulk = BulkModel.Parse(res.Stdout);
            }
            catch (Exception)
            {
                status.text = "";
                Note("Could not parse CLI output (CLI version mismatch?):");
                Note(res.Stdout.Length > 200 ? res.Stdout.Substring(0, 200) + "…" : res.Stdout);
                return;
            }
            list.itemsSource = bulk.Entries;
            list.RefreshItems();
            status.text = bulk.Entries.Count == 0 ? "No changes vs HEAD" : $"{bulk.Entries.Count} changed vs HEAD";

            if (menuInvoked && IndexOfPath(wanted) < 0)
            {
                Note($"No semantic changes for {wanted}");
                return;
            }
            if (bulk.Entries.Count == 0)
                return;
            var idx = IndexOfPath(wanted);
            if (idx < 0)
                idx = 0;
            list.SetSelection(idx);
            // Render directly instead of relying on SetSelection to re-fire selectionChanged
            // when the index is unchanged (undocumented ListView behavior).
            ShowEntry(bulk.Entries[idx]);
        }

        int IndexOfPath(string path)
        {
            if (path == null)
                return -1;
            for (var i = 0; i < bulk.Entries.Count; i++)
                if (bulk.Entries[i].Path == path)
                    return i;
            return -1;
        }

        void OnSelectionChanged(IEnumerable<object> items)
        {
            foreach (var item in items)
            {
                if (item is not BulkEntry entry)
                    return;
                ShowEntry(entry);
                return;
            }
        }

        void ShowEntry(BulkEntry entry)
        {
            selectedPath = entry.Path;
            content.Clear();
            entry.Diff.ResolveWith(AssetDatabase.GUIDToAssetPath);
            if (entry.Diff.IsEmpty)
                Note("No semantic changes");
            else
                content.Add(BuildTree(entry.Diff));
        }

        void ShowMissingCli()
        {
            bulk = new BulkModel();
            list.itemsSource = bulk.Entries;
            list.RefreshItems();
            status.text = "";
            // pendingSelectPath intentionally survives this path so DownloadThenRefresh carries the menu intent through.
            content.Clear();
            Note($"prefablens CLI not found (v{Cli.Version}).");
            content.Add(
                new Button(DownloadThenRefresh)
                {
                    text = "Download from GitHub Releases",
                    style = { alignSelf = Align.FlexStart, marginLeft = 6 },
                }
            );
            Note($"Or set a manual path via EditorPrefs key '{Cli.CliPathPref}'.");
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
            content.Add(
                new Label(text)
                {
                    style =
                    {
                        marginLeft = 6,
                        marginTop = 2,
                        whiteSpace = WhiteSpace.Normal,
                    },
                }
            );
        }

        static Row EntryRow(BulkEntry entry) => Badge(BulkModel.AggregateStatus(entry.Diff)).Add(entry.Path);

        static void RenderRow(VisualElement e, Row row)
        {
            e.Clear();
            foreach (var span in row.Spans)
            {
                var l = new Label(span.Text)
                {
                    style =
                    {
                        marginLeft = 0,
                        marginRight = 0,
                        paddingLeft = 0,
                        paddingRight = 0,
                    },
                };
                if (span.Tint is Color tint)
                    l.style.color = tint;
                e.Add(l);
            }
        }

        // ---- Tree rendering (same color tone and notation as the Chrome renderer) ----
        // No rich text: don't let repository-derived strings be interpreted as markup (same rationale as the Chrome build's XSS test).

        static class Palette
        {
            public static Color Added => Hex(EditorGUIUtility.isProSkin ? 0x3fb950 : 0x1a7f37);
            public static Color Removed => Hex(EditorGUIUtility.isProSkin ? 0xf85149 : 0xcf222e);
            public static Color Modified => Hex(EditorGUIUtility.isProSkin ? 0xd29922 : 0x9a6700);
            public static Color Muted => Hex(EditorGUIUtility.isProSkin ? 0x9198a1 : 0x59636e);

            static Color Hex(int rgb) =>
                new Color(((rgb >> 16) & 0xff) / 255f, ((rgb >> 8) & 0xff) / 255f, (rgb & 0xff) / 255f);
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
                if (!string.IsNullOrEmpty(text))
                    Spans.Add(new Span(text, tint));
                return this;
            }
        }

        static TreeView BuildTree(DiffModel model)
        {
            var id = 0;
            var items = new List<TreeViewItemData<Row>>();
            foreach (var n in model.Roots)
                items.Add(NodeItem(n, model, ref id));
            foreach (var c in model.Loose)
                items.Add(ComponentItem(c, model, ref id));

            var tree = new TreeView { fixedItemHeight = 18, style = { flexGrow = 1 } };
            tree.SetRootItems(items);
            tree.makeItem = () =>
                new VisualElement { style = { flexDirection = FlexDirection.Row, alignItems = Align.Center } };
            tree.bindItem = (e, i) => RenderRow(e, tree.GetItemDataForIndex<Row>(i));
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
            foreach (var c in n.Components)
                children.Add(ComponentItem(c, m, ref id));
            foreach (var ch in n.Children)
                children.Add(NodeItem(ch, m, ref id));

            var row = Badge(n.Status).Add(n.Name);
            if (pi?.SourceGuid != null)
                row.Add(
                    " ‹Prefab: " + (m.Resolved.TryGetValue(pi.SourceGuid, out var src) ? src : pi.SourceGuid) + "›",
                    Palette.Muted
                );
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
            if (v == null || v.IsNull)
                return "";
            if (!v.IsRef)
                return v.Scalar ?? "";
            if (v.RefGuid != null)
                return m.Resolved.TryGetValue(v.RefGuid, out var p) ? Stem(p) : v.RefGuid;
            return v.RefFileId == "0" ? "None" : "#" + v.RefFileId;
        }

        static Row Badge(DiffStatus s) =>
            s switch
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
