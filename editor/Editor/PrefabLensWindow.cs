using System;
using System.Collections.Generic;
using System.Threading;
using UnityEditor;
using UnityEngine;
using UnityEngine.UIElements;

namespace PrefabLens
{
    /// Master-detail view: UnityYAML assets that differ from the chosen base ref
    /// (HEAD by default) on the left, the selected asset's semantic diff on the right.
    public sealed class PrefabLensWindow : EditorWindow
    {
        Label status;
        TextField baseRef;
        ListView list;
        VisualElement content;
        BulkModel bulk = new();
        string selectedPath;
        string lastStdout;
        bool refreshing;
        bool downloadAttempted;
        string downloadError;
        CancellationTokenSource downloadCts;
        bool pendingRefresh;
        CancellationTokenSource runCts;
        string warnedOverride; // last missing-override path already logged (no console spam on every focus)

        [MenuItem("Window/PrefabLens")]
        public static void Open() => GetWindow<PrefabLensWindow>("PrefabLens");

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
            baseRef = new TextField("Base")
            {
                // Commit on Enter or focus loss instead of every keystroke, so each
                // edit triggers exactly one CLI run.
                isDelayed = true,
                tooltip = "Git ref to compare against: branch, tag, or commit. Empty = HEAD.",
                style = { width = 220 },
            };
            baseRef.RegisterValueChangedCallback(_ => Refresh());
            toolbar.Add(baseRef);
            toolbar.Add(new Button(Refresh) { text = "Refresh" });
            rootVisualElement.Add(toolbar);

            var split = new TwoPaneSplitView(0, 240, TwoPaneSplitViewOrientation.Horizontal);
            list = new ListView { fixedItemHeight = 20, style = { marginTop = 2 } };
            list.makeItem = () =>
                new VisualElement
                {
                    style =
                    {
                        flexDirection = FlexDirection.Row,
                        alignItems = Align.Center,
                        paddingLeft = 6,
                        paddingRight = 6,
                    },
                };
            list.bindItem = (e, i) => RenderRow(e, EntryRow(bulk.Entries[i]));
            list.selectionChanged += OnSelectionChanged;
            split.Add(list);
            content = new VisualElement { style = { flexGrow = 1 } };
            split.Add(content);
            rootVisualElement.Add(split);
            // Window-lifetime token for CLI runs; domain reload re-enters CreateGUI with a fresh one.
            runCts = new CancellationTokenSource();
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
            if (content == null)
                return;
            if (refreshing)
            {
                // A base-ref edit landed mid-run: run again when the in-flight run returns,
                // instead of silently dropping the edit.
                pendingRefresh = true;
                return;
            }
            var loc = Cli.Locate();
            if (loc.MissingOverride != null && loc.MissingOverride != warnedOverride)
            {
                warnedOverride = loc.MissingOverride;
                Debug.LogWarning(
                    $"PrefabLens: EditorPrefs '{Cli.CliPathPref}' points at a missing file: "
                        + $"{loc.MissingOverride}. Falling back to the default location."
                );
            }
            var cli = loc.Path;
            if (cli == null)
            {
                // Fetch the pinned binary automatically, once per session; after a
                // failure, fall back to the manual screen instead of re-downloading
                // on every focus.
                if (downloadAttempted)
                    ShowMissingCli();
                else
                    StartDownload();
                return;
            }
            refreshing = true;
            status.text = "Refreshing…";
            // Capture the ref this run compares against: the field can change before it completes,
            // and the completion callback must label the data with the ref it was produced from.
            var runRef = baseRef.value;
            Cli.RunBulkAsync(cli, runRef, res => OnBulkDone(res, runRef), runCts.Token);
        }

        void OnBulkDone(Cli.Result res, string runRef)
        {
            refreshing = false;
            if (content == null || res.Canceled)
                return; // window gone or closing: leave the UI alone
            ShowBulkResult(res, runRef);
            if (pendingRefresh)
            {
                // The base ref changed mid-run: the result above is already labeled with its own
                // ref; now run again with the current field value.
                pendingRefresh = false;
                Refresh();
            }
        }

        void ShowBulkResult(Cli.Result res, string runRef)
        {
            // Unchanged output — the common focus-triggered refresh. Leave the whole UI
            // alone so the user's tree fold state survives; only restore the status line.
            if (res.ExitCode == 0 && res.Stdout == lastStdout)
            {
                status.text = CountText(runRef);
                return;
            }
            content.Clear();
            if (res.ExitCode != 0)
            {
                // The CLI's stderr is the primary source (non-git repository, timeout, etc.)
                lastStdout = null;
                status.text = "";
                Note(string.IsNullOrEmpty(res.Stderr) ? $"prefablens exited with {res.ExitCode}" : res.Stderr.Trim());
                return;
            }
            try
            {
                bulk = BulkModel.Parse(res.Stdout);
            }
            catch (Exception e)
            {
                // The generic UI note stays short; the console carries the real reason
                // (exception type + message) so a version mismatch is diagnosable.
                Debug.LogException(e);
                lastStdout = null;
                status.text = "";
                Note("Could not parse CLI output (CLI version mismatch?):");
                Note(res.Stdout.Length > 200 ? res.Stdout.Substring(0, 200) + "…" : res.Stdout);
                return;
            }
            lastStdout = res.Stdout;
            list.itemsSource = bulk.Entries;
            list.RefreshItems();
            status.text = CountText(runRef);

            if (bulk.Entries.Count == 0)
                return;
            var idx = IndexOfPath(selectedPath);
            if (idx < 0)
                idx = 0;
            list.SetSelection(idx);
            // Render directly instead of relying on SetSelection to re-fire selectionChanged
            // when the index is unchanged (undocumented ListView behavior).
            ShowEntry(bulk.Entries[idx]);
        }

        string CountText(string runRef) =>
            bulk.Entries.Count == 0
                ? $"No changes vs {BaseLabel(runRef)}"
                : $"{bulk.Entries.Count} changed vs {BaseLabel(runRef)}";

        static string BaseLabel(string runRef)
        {
            var r = runRef?.Trim();
            return string.IsNullOrEmpty(r) ? "HEAD" : r;
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
            lastStdout = null;
            status.text = "";
            content.Clear();
            if (downloadError != null)
                Note($"Download failed: {downloadError}");
            if (warnedOverride != null)
                Note($"Override '{Cli.CliPathPref}' points at a missing file: {warnedOverride}");
            Note($"prefablens CLI not found (v{Cli.Version}).");
            content.Add(
                new Button(StartDownload)
                {
                    text = "Download from GitHub Releases",
                    style = { alignSelf = Align.FlexStart, marginLeft = 6 },
                }
            );
            Note($"Or set a manual path via EditorPrefs key '{Cli.CliPathPref}'.");
        }

        /// Shared by the automatic trigger in Refresh and the manual retry button.
        void StartDownload()
        {
            downloadAttempted = true;
            refreshing = true; // keeps focus-triggered Refresh calls out while the download runs
            bulk = new BulkModel();
            list.itemsSource = bulk.Entries;
            list.RefreshItems();
            lastStdout = null;
            status.text = $"Downloading prefablens v{Cli.Version}…";
            content.Clear();
            downloadCts = new CancellationTokenSource();
            content.Add(
                // Null-conditional: the button outlives the download (until the next content.Clear),
                // and OnDownloadDone nulls the field on the same thread as this click handler.
                new Button(() => downloadCts?.Cancel())
                {
                    text = "Cancel",
                    style = { alignSelf = Align.FlexStart, marginLeft = 6 },
                }
            );
            Cli.DownloadAsync(OnDownloadDone, OnDownloadProgress, downloadCts.Token);
        }

        void OnDownloadProgress(long read, long total)
        {
            if (content == null)
                return;
            status.text =
                total > 0
                    ? $"Downloading prefablens v{Cli.Version}… {read * 100 / total}%"
                    : $"Downloading prefablens v{Cli.Version}… {read / 1024} KB";
        }

        /// The success path re-resolves through Cli.Locate instead of using the returned
        /// path, so the manual EditorPrefs override keeps precedence.
        void OnDownloadDone(string path, string error)
        {
            refreshing = false;
            // A user-initiated cancel is not a failure: show the plain missing-CLI screen
            // with its retry button instead of "Download failed: …".
            var canceled = downloadCts != null && downloadCts.IsCancellationRequested;
            downloadCts?.Dispose();
            downloadCts = null;
            if (content == null)
                return;
            downloadError = canceled ? null : error;
            if (error != null)
            {
                ShowMissingCli();
                return;
            }
            // Drop the Cancel button now; Refresh only rebuilds content once the bulk run returns.
            content.Clear();
            Refresh();
        }

        /// Unity calls this when the window closes (and on domain reload): stop an
        /// in-flight download and kill an in-flight CLI run (no 90 s orphan).
        void OnDisable()
        {
            downloadCts?.Cancel();
            runCts?.Cancel();
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

        static Row EntryRow(BulkEntry entry) =>
            DiffTree
                .Badge(BulkModel.AggregateStatus(entry.Diff))
                .WithIcon(AssetDatabase.GetCachedIcon(entry.Path))
                .Add(entry.Path);

        static void RenderRow(VisualElement e, Row row)
        {
            e.Clear();
            for (var i = 0; i < row.Spans.Count; i++)
            {
                var span = row.Spans[i];
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
                // The icon sits between the badge (always the first span) and the name.
                if (i == 0 && row.Icon != null)
                    e.Add(
                        new Image
                        {
                            image = row.Icon,
                            style =
                            {
                                width = 16,
                                height = 16,
                                marginRight = 2,
                                flexShrink = 0,
                            },
                        }
                    );
            }
        }

        // ---- Tree rendering: DiffTree builds the rows; only the UIElements wiring lives here ----

        static TreeView BuildTree(DiffModel model)
        {
            var id = 0;
            var items = new List<TreeViewItemData<Row>>();
            foreach (var item in DiffTree.Build(model))
                items.Add(ToViewItem(item, ref id));

            var tree = new TreeView { fixedItemHeight = 18, style = { flexGrow = 1 } };
            tree.SetRootItems(items);
            tree.makeItem = () =>
                new VisualElement { style = { flexDirection = FlexDirection.Row, alignItems = Align.Center } };
            tree.bindItem = (e, i) => RenderRow(e, tree.GetItemDataForIndex<Row>(i));
            tree.ExpandAll();
            return tree;
        }

        /// Ids only need to be unique within one TreeView; each ShowEntry builds a fresh one.
        static TreeViewItemData<Row> ToViewItem(DiffTree.Item item, ref int id)
        {
            var children = new List<TreeViewItemData<Row>>();
            foreach (var ch in item.Children)
                children.Add(ToViewItem(ch, ref id));
            return new TreeViewItemData<Row>(id++, item.Row, children);
        }
    }
}
