using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Threading;
using UnityEditor;
using UnityEngine;
using UnityEngine.UIElements;

[assembly: InternalsVisibleTo("PrefabLens.Editor.Tests")]

namespace PrefabLens
{
    /// The left pane lists UnityYAML assets that differ from the Base ref, which defaults to HEAD.
    /// The right pane shows the selected asset's semantic diff.
    public sealed class PrefabLensWindow : EditorWindow
    {
        Label status;
        TextField baseRef;
        ListView list;
        VisualElement content;
        BulkModel bulk = new();
        string selectedPath;
        string lastStdout;
        string downloadError;
        CancellationTokenSource downloadCts;
        CancellationTokenSource runCts;
        readonly RefreshGate gate = new RefreshGate();

        [MenuItem("Window/PrefabLens")]
        public static void Open() => GetWindow<PrefabLensWindow>("PrefabLens");

        public void CreateGUI()
        {
            CreateLayout();
            // Window-lifetime token for CLI runs; domain reload re-enters CreateGUI with a fresh one.
            runCts = new CancellationTokenSource();
            Refresh();
        }

        /// Toolbar and split view only. Tests feed fixtures through ShowBulkResult without a CLI run.
        internal void CreateLayout()
        {
            var toolbar = new VisualElement
            {
                style =
                {
                    flexDirection = FlexDirection.Row,
                    alignItems = Align.Center,
                    paddingTop = 4,
                    paddingBottom = 4,
                    paddingLeft = 6,
                    paddingRight = 6,
                },
            };
            status = new Label { style = { flexGrow = 1, unityTextAlign = TextAnchor.MiddleLeft } };
            toolbar.Add(status);
            baseRef = new TextField("Base")
            {
                // Committing on Enter or focus loss avoids a CLI run for every keystroke.
                isDelayed = true,
                tooltip = "Git ref to compare against: branch, tag, or commit. Empty = HEAD.",
                style = { width = 220, marginRight = 4 },
            };
            baseRef.RegisterValueChangedCallback(_ => Refresh());
            toolbar.Add(baseRef);
            toolbar.Add(new Button(Refresh) { text = "Refresh" });
            rootVisualElement.Add(toolbar);

            var split = new TwoPaneSplitView(0, 280, TwoPaneSplitViewOrientation.Horizontal)
            {
                style = { flexGrow = 1 },
            };
            list = new ListView { fixedItemHeight = DiffTreeView.ListItemHeight };
            list.makeItem = DiffTreeView.MakeListRow;
            list.bindItem = (element, index) =>
                DiffTreeView.BindRow(element, DiffTreeView.EntryRow(bulk.Entries[index]));
            list.selectionChanged += OnSelectionChanged;
            split.Add(list);
            content = new VisualElement { style = { flexGrow = 1 } };
            split.Add(content);
            rootVisualElement.Add(split);
        }

        internal ListView FileList => list;
        internal VisualElement DetailPane => content;
        internal string StatusText => status.text;

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
            var loc = Cli.Locate();
            var d = gate.OnRefresh(loc);
            if (d.Warn != null)
            {
                var next =
                    loc.Path != null
                        ? $"PrefabLens will use '{loc.Path}'."
                        : $"PrefabLens will download v{Cli.Version}.";
                Debug.LogWarning($"PrefabLens: CLI path override '{Cli.CliPathPref}' is invalid. {d.Warn} {next}");
            }
            switch (d.Step)
            {
                case RefreshGate.Step.Run:
                    status.text = "Refreshing…";
                    // The Base field can change during a run, so its result must retain the ref it used.
                    var runRef = baseRef.value;
                    Cli.RunBulkAsync(loc.Path, runRef, res => OnBulkDone(res, runRef), runCts.Token);
                    break;
                case RefreshGate.Step.StartDownload:
                    StartDownload();
                    break;
                case RefreshGate.Step.ShowMissingCli:
                    ShowMissingCli();
                    break;
            }
        }

        void OnBulkDone(Cli.Result res, string runRef)
        {
            // A canceled completion must update the gate while leaving the closing window's UI alone.
            var rerun = gate.OnRunDone(res.Canceled);
            if (content == null || res.Canceled)
                return; // window gone or closing: leave the UI alone
            ShowBulkResult(res, runRef);
            if (rerun)
                Refresh(); // the base ref changed mid-run: run again with the current field
        }

        internal void ShowBulkResult(Cli.Result res, string runRef)
        {
            // A focus-triggered refresh often returns unchanged output. Preserve the user's expanded rows in that case.
            if (res.ExitCode == 0 && res.Stdout == lastStdout)
            {
                status.text = CountText(runRef);
                return;
            }
            if (res.ExitCode != 0)
            {
                // CLI stderr includes the cause, such as a missing Git repository or timeout.
                ResetList();
                content.Clear();
                Note(string.IsNullOrEmpty(res.Stderr) ? $"prefablens exited with {res.ExitCode}" : res.Stderr.Trim());
                return;
            }
            try
            {
                bulk = BulkModel.Parse(res.Stdout);
            }
            catch (Exception e)
            {
                // The console retains the exception type and message for diagnosing a version mismatch.
                // The UI note stays short.
                Debug.LogException(e);
                ResetList();
                content.Clear();
                Note("Could not parse CLI output (CLI version mismatch?):");
                Note(res.Stdout.Length > 200 ? res.Stdout.Substring(0, 200) + "…" : res.Stdout);
                return;
            }
            lastStdout = res.Stdout;
            list.itemsSource = bulk.Entries;
            list.RefreshItems();
            status.text = CountText(runRef);

            if (bulk.Entries.Count == 0)
            {
                content.Clear();
                return;
            }
            var idx = bulk.Entries.FindIndex(entry => entry.Path == selectedPath);
            if (idx < 0)
                idx = 0;
            list.SetSelection(idx);
            // ListView may omit selectionChanged when the index stays the same, so the selected entry needs a direct render.
            ShowEntry(bulk.Entries[idx]);
        }

        string CountText(string runRef) =>
            bulk.Entries.Count == 0
                ? $"No changes vs {BaseLabel(runRef)}"
                : $"Changed assets vs {BaseLabel(runRef)}: {bulk.Entries.Count}";

        static string BaseLabel(string runRef)
        {
            var r = runRef?.Trim();
            return string.IsNullOrEmpty(r) ? "HEAD" : r;
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
            content.Add(DiffTreeView.BuildHeader(entry));
            if (entry.Diff.IsEmpty)
                Note("No semantic changes");
            else
                content.Add(DiffTreeView.BuildTree(entry.Diff));
        }

        /// Clears the list pane, selection, and status. Missing-CLI, download start,
        /// and a failed refresh share this reset.
        void ResetList()
        {
            bulk = new BulkModel();
            list.SetSelection(-1);
            list.itemsSource = bulk.Entries;
            list.RefreshItems();
            lastStdout = null;
            status.text = "";
        }

        void ShowMissingCli()
        {
            ResetList();
            content.Clear();
            if (downloadError != null)
                Note($"Download failed: {downloadError}");
            if (gate.OverrideError != null)
                Note($"CLI path override '{Cli.CliPathPref}' is invalid. {gate.OverrideError}");
            Note($"PrefabLens CLI v{Cli.Version} was not found.");
            content.Add(
                new Button(StartDownload)
                {
                    text = "Download from GitHub Releases",
                    style = { alignSelf = Align.FlexStart, marginLeft = 6 },
                }
            );
            Note("Select a CLI executable in Preferences > PrefabLens.");
        }

        /// Shared by the automatic trigger in Refresh and the manual retry button.
        void StartDownload()
        {
            gate.OnDownloadStart();
            ResetList();
            status.text = DownloadingText;
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

        /// Built once: the progress line appends to this exact prefix.
        static readonly string DownloadingText = $"Downloading prefablens v{Cli.Version}…";

        void OnDownloadProgress(long read, long total)
        {
            if (content == null)
                return;
            status.text =
                total > 0 ? $"{DownloadingText} {read * 100 / total}%" : $"{DownloadingText} {read / 1024} KB";
        }

        /// The success path re-resolves through Cli.Locate instead of using the returned
        /// path, so the manual EditorPrefs override keeps precedence.
        void OnDownloadDone(string path, string error)
        {
            gate.OnDownloadDone();
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

        /// Closing the window or reloading the domain must cancel downloads and CLI runs.
        /// Otherwise, a CLI process could remain alive for its 90 s timeout.
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
                        marginTop = 6,
                        whiteSpace = WhiteSpace.Normal,
                    },
                }
            );
        }
    }
}
