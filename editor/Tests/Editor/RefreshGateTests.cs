using NUnit.Framework;

namespace PrefabLens.Tests
{
    public class RefreshGateTests
    {
        static Cli.Location Found(string path) => new Cli.Location(path, null);

        static Cli.Location NotFound() => new Cli.Location(null, null);

        static Cli.Location InvalidOverride(string error, string fallback) => new Cli.Location(fallback, error);

        [Test]
        public void RefreshWithACliRunsAndGatesReentry()
        {
            var gate = new RefreshGate();
            var first = gate.OnRefresh(Found("bin/prefablens"));
            Assert.AreEqual(RefreshGate.Step.Run, first.Step);
            // A second trigger while the run is in flight queues instead of double-running.
            var second = gate.OnRefresh(Found("bin/prefablens"));
            Assert.AreEqual(RefreshGate.Step.Wait, second.Step);
            // The queued edit re-enters exactly once when the run completes.
            Assert.IsTrue(gate.OnRunDone(canceled: false));
            Assert.IsFalse(gate.OnRunDone(canceled: false));
        }

        [Test]
        public void ACanceledRunDoesNotConsumeTheQueuedRefresh()
        {
            // The window is closing when a run cancels: the pending flag must not be
            // eaten by the canceled completion (matches the pre-extraction behavior).
            var gate = new RefreshGate();
            gate.OnRefresh(Found("bin/prefablens"));
            gate.OnRefresh(Found("bin/prefablens")); // queues
            Assert.IsFalse(gate.OnRunDone(canceled: true));
            gate.OnRefresh(Found("bin/prefablens")); // not refreshing anymore: runs again
            Assert.IsTrue(gate.OnRunDone(canceled: false));
        }

        [Test]
        public void MissingCliDownloadsOnceThenShowsTheManualScreen()
        {
            var gate = new RefreshGate();
            Assert.AreEqual(RefreshGate.Step.StartDownload, gate.OnRefresh(NotFound()).Step);
            gate.OnDownloadStart();
            // Focus-triggered refreshes during the download queue behind it.
            Assert.AreEqual(RefreshGate.Step.Wait, gate.OnRefresh(NotFound()).Step);
            gate.OnDownloadDone();
            // After a failed download the missing screen shows instead of re-downloading.
            Assert.AreEqual(RefreshGate.Step.ShowMissingCli, gate.OnRefresh(NotFound()).Step);
            // The refresh queued mid-download survives OnDownloadDone and rides the next
            // run's completion — the accepted one-redundant-refresh behavior from #195.
            Assert.AreEqual(RefreshGate.Step.Run, gate.OnRefresh(Found("bin/prefablens")).Step);
            Assert.IsTrue(gate.OnRunDone(canceled: false));
        }

        [Test]
        public void InvalidOverrideWarnsOncePerErrorAndRearmsWhenCleared()
        {
            var gate = new RefreshGate();
            Assert.AreEqual(
                "missing companion",
                gate.OnRefresh(InvalidOverride("missing companion", "bin/prefablens")).Warn
            );
            Assert.IsFalse(gate.OnRunDone(canceled: false));
            // The next refresh keeps the state visible without a duplicate warning.
            var repeat = gate.OnRefresh(InvalidOverride("missing companion", "bin/prefablens"));
            Assert.IsNull(repeat.Warn);
            Assert.AreEqual("missing companion", gate.OverrideError);
            gate.OnRunDone(canceled: false);
            // A valid override clears the state. The same later error produces a warning.
            gate.OnRefresh(Found("bin/prefablens"));
            Assert.IsNull(gate.OverrideError);
            gate.OnRunDone(canceled: false);
            Assert.AreEqual(
                "missing companion",
                gate.OnRefresh(InvalidOverride("missing companion", "bin/prefablens")).Warn
            );
        }

        [Test]
        public void AWarnRidesTheDownloadAndMissingScreenSteps()
        {
            // A broken override plus no usable binary: the user must still see the
            // warning even though no run starts.
            var gate = new RefreshGate();
            var d = gate.OnRefresh(new Cli.Location(null, "/gone"));
            Assert.AreEqual(RefreshGate.Step.StartDownload, d.Step);
            Assert.AreEqual("/gone", d.Warn);
        }
    }
}
