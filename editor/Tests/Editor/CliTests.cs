using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Threading;
using NUnit.Framework;

namespace PrefabLens.Tests
{
    public class CliTests
    {
        [Test]
        public void ReleaseAssetNameCoversAllTargets()
        {
            Assert.AreEqual(
                "prefablens-windows-x64.zip",
                Cli.ReleaseAssetName(isWindows: true, isMac: false, isArm64: false)
            );
            Assert.AreEqual(
                "prefablens-windows-arm64.zip",
                Cli.ReleaseAssetName(isWindows: true, isMac: false, isArm64: true)
            );
            Assert.AreEqual(
                "prefablens-macos-arm64.zip",
                Cli.ReleaseAssetName(isWindows: false, isMac: true, isArm64: true)
            );
            Assert.AreEqual(
                "prefablens-macos-x64.zip",
                Cli.ReleaseAssetName(isWindows: false, isMac: true, isArm64: false)
            );
            Assert.AreEqual(
                "prefablens-linux-x64.zip",
                Cli.ReleaseAssetName(isWindows: false, isMac: false, isArm64: false)
            );
            Assert.AreEqual(
                "prefablens-linux-arm64.zip",
                Cli.ReleaseAssetName(isWindows: false, isMac: false, isArm64: true)
            );
        }

        [Test]
        public void DownloadUrlPointsAtTheVersionedRelease()
        {
            Assert.AreEqual(
                "https://github.com/hashiiiii/PrefabLens/releases/download/v0.1.0/prefablens-macos-arm64.zip",
                Cli.DownloadUrl("0.1.0", "prefablens-macos-arm64.zip")
            );
        }

        [Test]
        public void QuoteArgsSurvivesSpacesAndQuotes()
        {
            Assert.AreEqual(
                "\"HEAD\" \"Assets/My Prefab.prefab\" \"--json\"",
                Cli.QuoteArgs(new[] { "HEAD", "Assets/My Prefab.prefab", "--json" })
            );
            Assert.AreEqual("\"a\\\"b\"", Cli.QuoteArgs(new[] { "a\"b" }));
        }

        [Test]
        public void RunProcessKillsAHungProcessAndReportsTimeout()
        {
            // Verify with a real process (sleep): it is killed on timeout and doesn't make us wait 60s.
            var isWindows = RuntimeInformation.IsOSPlatform(OSPlatform.Windows);
            var file = isWindows ? "cmd.exe" : "/bin/sh";
            var args = isWindows ? "/c ping -n 60 127.0.0.1 > NUL" : "-c \"sleep 60\"";
            var sw = Stopwatch.StartNew();
            var res = Cli.RunProcess(file, args, ".", timeoutMs: 500);
            sw.Stop();
            Assert.IsTrue(res.TimedOut, "expected the hung process to be reported as timed out");
            Assert.AreNotEqual(0, res.ExitCode);
            StringAssert.Contains("timed out", res.Stderr);
            Assert.Less(sw.ElapsedMilliseconds, 30_000, "timeout must not degrade into waiting for the child");
        }

        [Test]
        public void RunProcessReturnsOutputWhenTheProcessExitsInTime()
        {
            var isWindows = RuntimeInformation.IsOSPlatform(OSPlatform.Windows);
            var file = isWindows ? "cmd.exe" : "/bin/sh";
            var args = isWindows ? "/c echo hello" : "-c \"echo hello\"";
            var res = Cli.RunProcess(file, args, ".", timeoutMs: Cli.RunTimeoutMs);
            Assert.IsFalse(res.TimedOut);
            Assert.AreEqual(0, res.ExitCode);
            StringAssert.Contains("hello", res.Stdout);
        }

        [Test]
        public void RunProcessCapturesStderrAndExitCode()
        {
            // When ExitCode != 0 the Window shows stderr as the primary source. Verifies that wiring.
            var isWindows = RuntimeInformation.IsOSPlatform(OSPlatform.Windows);
            var file = isWindows ? "cmd.exe" : "/bin/sh";
            var args = isWindows ? "/c echo boom 1>&2 & exit 3" : "-c \"echo boom 1>&2; exit 3\"";
            var res = Cli.RunProcess(file, args, ".", timeoutMs: Cli.RunTimeoutMs);
            Assert.IsFalse(res.TimedOut);
            Assert.AreEqual(3, res.ExitCode);
            StringAssert.Contains("boom", res.Stderr);
        }

        [Test]
        public void RunProcessDrainsBothPipesPastTheOsBuffer()
        {
            // Even a child that writes both stdout and stderr past the OS pipe buffer (typically 64KB)
            // can be read in full without deadlock. "Simplifying" RunProcess's async reads into two synchronous
            // ReadToEnd calls leaves the child blocked on the stderr write and the test fails on timeout.
            var isWindows = RuntimeInformation.IsOSPlatform(OSPlatform.Windows);
            var file = isWindows ? "cmd.exe" : "/bin/sh";
            var line = new string('x', 40);
            var args = isWindows
                ? $"/c for /L %i in (1,1,4000) do @(echo {line}& echo {line} 1>&2)"
                : $"-c \"i=0; while [ $i -lt 4000 ]; do echo {line}; echo {line} 1>&2; i=$((i+1)); done\"";
            var res = Cli.RunProcess(file, args, ".", timeoutMs: Cli.RunTimeoutMs);
            Assert.IsFalse(res.TimedOut);
            Assert.AreEqual(0, res.ExitCode);
            // 4000 lines × 41 bytes ≈ 160KB. Reliably exceeds the buffer while also detecting dropped output.
            Assert.Greater(res.Stdout.Length, 100_000);
            Assert.Greater(res.Stderr.Length, 100_000);
        }

        [Test]
        public void BuildBulkArgsRequestsAllChangedFilesAsJson()
        {
            // Bare `prefablens --json` is bulk mode: HEAD vs working tree, all changed Unity files.
            Assert.AreEqual(new[] { "--json" }, Cli.BuildBulkArgs());
        }

        [Test]
        public void RunAsyncInvokesTheCallbackOffTheBlockedCaller()
        {
            // ctx: null exercises the no-SynchronizationContext fallback; a posted callback
            // could not run while this test blocks the caller, failing the wait below.
            var isWindows = RuntimeInformation.IsOSPlatform(OSPlatform.Windows);
            var file = isWindows ? "cmd.exe" : "/bin/sh";
            var args = isWindows ? "/c echo hello" : "-c \"echo hello\"";
            Cli.Result? got = null;
            using var done = new ManualResetEventSlim();
            Cli.RunAsync(
                file,
                args,
                r =>
                {
                    got = r;
                    done.Set();
                },
                ctx: null
            );
            Assert.IsTrue(done.Wait(30_000), "callback never fired");
            Assert.AreEqual(0, got.Value.ExitCode);
            StringAssert.Contains("hello", got.Value.Stdout);
        }

        [Test]
        public void RunAsyncReportsAStartupFailureInsteadOfThrowing()
        {
            // Process.Start throws when the binary is missing; the async path must fold
            // that into a Result so the window's error display keeps working.
            Cli.Result? got = null;
            using var done = new ManualResetEventSlim();
            Cli.RunAsync(
                "/nonexistent/prefablens-binary",
                "\"--json\"",
                r =>
                {
                    got = r;
                    done.Set();
                },
                ctx: null
            );
            Assert.IsTrue(done.Wait(30_000), "callback never fired");
            Assert.AreNotEqual(0, got.Value.ExitCode);
            Assert.IsNotEmpty(got.Value.Stderr);
        }

        [Test]
        public void ExtractToWritesEveryZipEntry()
        {
            // Build a real zip in memory (no fixture files) and extract it into a temp dir.
            var buffer = new MemoryStream();
            using (var zip = new ZipArchive(buffer, ZipArchiveMode.Create, leaveOpen: true))
            {
                using (var w = new StreamWriter(zip.CreateEntry("prefablens").Open()))
                    w.Write("binary");
                using (var w = new StreamWriter(zip.CreateEntry("LICENSE").Open()))
                    w.Write("apache");
            }
            var dir = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName());
            Directory.CreateDirectory(dir);
            try
            {
                Cli.ExtractTo(buffer.ToArray(), dir);
                Assert.AreEqual("binary", File.ReadAllText(Path.Combine(dir, "prefablens")));
                Assert.AreEqual("apache", File.ReadAllText(Path.Combine(dir, "LICENSE")));
            }
            finally
            {
                Directory.Delete(dir, recursive: true);
            }
        }

        [Test]
        public void DeleteStaleVersionsKeepsOnlyThePinnedVersion()
        {
            // Simulates Library/PrefabLens after a package upgrade: the old cache dir
            // must be removed, the freshly downloaded pinned version must survive.
            var root = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName());
            Directory.CreateDirectory(Path.Combine(root, "0.5.0"));
            File.WriteAllText(Path.Combine(root, "0.5.0", "prefablens"), "old");
            Directory.CreateDirectory(Path.Combine(root, "0.6.1"));
            try
            {
                Cli.DeleteStaleVersions(root, keep: "0.6.1");
                Assert.IsFalse(Directory.Exists(Path.Combine(root, "0.5.0")));
                Assert.IsTrue(Directory.Exists(Path.Combine(root, "0.6.1")));
            }
            finally
            {
                Directory.Delete(root, recursive: true);
            }
        }

        [Test]
        public void DeleteStaleVersionsToleratesAMissingRoot()
        {
            // First-ever download: Library/PrefabLens does not exist yet.
            // Cleanup must be a silent no-op, not a DirectoryNotFoundException.
            var root = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName());
            Assert.DoesNotThrow(() => Cli.DeleteStaleVersions(root, keep: "0.6.1"));
        }
    }
}
