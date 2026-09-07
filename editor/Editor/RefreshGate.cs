namespace PrefabLens
{
    /// The window's refresh/download gating, extracted so the state machine runs
    /// under DotNetTests~. Holds state and decides the next step; the window
    /// executes the step (UI, process, download) and reports completions back.
    public sealed class RefreshGate
    {
        bool refreshing;
        bool pendingRefresh;
        bool downloadAttempted;
        string warnedOverride; // last override error already logged

        /// Current override error, or null when the override is unset or valid.
        public string OverrideError { get; private set; }

        public enum Step
        {
            Wait, // a run or download is in flight; the trigger is queued
            Run,
            StartDownload,
            ShowMissingCli,
        }

        public struct Decision
        {
            public Step Step;
            public string Warn; // non-null: log this override error once
        }

        /// Every refresh trigger (focus, button, base-ref edit, post-download) lands here.
        public Decision OnRefresh(Cli.Location loc)
        {
            if (refreshing)
            {
                // A trigger landed mid-run: run again when the in-flight work returns,
                // instead of silently dropping the edit.
                pendingRefresh = true;
                return new Decision { Step = Step.Wait };
            }
            OverrideError = loc.OverrideError;
            var warn = loc.OverrideError != warnedOverride ? loc.OverrideError : null;
            // Clearing the error allows a later occurrence to produce a new warning.
            warnedOverride = loc.OverrideError;
            if (loc.Path == null)
                return new Decision
                {
                    Step = downloadAttempted ? Step.ShowMissingCli : Step.StartDownload,
                    Warn = warn,
                };
            refreshing = true;
            return new Decision { Step = Step.Run, Warn = warn };
        }

        /// A bulk run completed. True = a refresh queued mid-run must re-enter now.
        /// A canceled run keeps the queue: the window is closing and must not re-run.
        public bool OnRunDone(bool canceled)
        {
            refreshing = false;
            if (canceled || !pendingRefresh)
                return false;
            pendingRefresh = false;
            return true;
        }

        public void OnDownloadStart()
        {
            downloadAttempted = true;
            refreshing = true; // keeps focus-triggered refreshes out while the download runs
        }

        public void OnDownloadDone() => refreshing = false;
    }
}
