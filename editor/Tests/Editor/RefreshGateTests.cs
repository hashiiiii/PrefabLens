using NUnit.Framework;

namespace PrefabLens.Tests
{
    public class RefreshGateTests
    {
        static Cli.Location Found(string path) => new Cli.Location(path, null);

        static Cli.Location NotFound() => new Cli.Location(null, null);

        static Cli.Location MissingOverride(string over, string fallback) => new Cli.Location(fallback, over);

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
        }

        [Test]
        public void MissingOverrideWarnsOncePerPathAndRearmsWhenCleared()
        {
            var gate = new RefreshGate();
            Assert.AreEqual("/gone", gate.OnRefresh(MissingOverride("/gone", "bin/prefablens")).Warn);
            Assert.IsFalse(gate.OnRunDone(canceled: false));
            // Same broken path on the next refresh: state visible, no repeat warning.
            var repeat = gate.OnRefresh(MissingOverride("/gone", "bin/prefablens"));
            Assert.IsNull(repeat.Warn);
            Assert.AreEqual("/gone", gate.MissingOverride);
            gate.OnRunDone(canceled: false);
            // Override fixed: the state clears and the warning re-arms.
            gate.OnRefresh(Found("bin/prefablens"));
            Assert.IsNull(gate.MissingOverride);
            gate.OnRunDone(canceled: false);
            // The same path breaking again warns again.
            Assert.AreEqual("/gone", gate.OnRefresh(MissingOverride("/gone", "bin/prefablens")).Warn);
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
