using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using NUnit.Framework;

namespace PrefabLens.Tests
{
    public partial class CliTests
    {
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
        public void BuildBulkArgsOmitsABlankBaseRefAndPassesATrimmedRef()
        {
            // Bare `prefablens --json` is bulk mode. A non-blank operand is a git ref.
            // The window feeds a free-form text field: null, empty, and whitespace-only
            // must keep the default invocation, and surrounding whitespace must not leak.
            Assert.AreEqual(new[] { "--json" }, Cli.BuildBulkArgs());
            Assert.AreEqual(new[] { "--json" }, Cli.BuildBulkArgs(null));
            Assert.AreEqual(new[] { "--json" }, Cli.BuildBulkArgs(""));
            Assert.AreEqual(new[] { "--json" }, Cli.BuildBulkArgs("   "));
            Assert.AreEqual(new[] { "main", "--json" }, Cli.BuildBulkArgs("main"));
            Assert.AreEqual(new[] { "HEAD~1", "--json" }, Cli.BuildBulkArgs("HEAD~1"));
            Assert.AreEqual(new[] { "main", "--json" }, Cli.BuildBulkArgs(" main "));
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
        public void RunProcessCancellationKillsTheChildQuickly()
        {
            // Closing the window cancels an in-flight run: the child must die immediately,
            // not survive until the 90 s timeout safety net fires.
            var isWindows = RuntimeInformation.IsOSPlatform(OSPlatform.Windows);
            var file = isWindows ? "cmd.exe" : "/bin/sh";
            var args = isWindows ? "/c ping -n 60 127.0.0.1 > NUL" : "-c \"sleep 60\"";
            using var cts = new CancellationTokenSource();
            cts.CancelAfter(300);
            var sw = Stopwatch.StartNew();
            var res = Cli.RunProcess(file, args, ".", timeoutMs: 60_000, ct: cts.Token);
            sw.Stop();
            Assert.IsTrue(res.Canceled, "expected the killed run to be reported as canceled");
            Assert.AreNotEqual(0, res.ExitCode);
            Assert.Less(sw.ElapsedMilliseconds, 30_000, "cancellation must not degrade into waiting out the timeout");
        }

        [Test]
        public void RunAsyncCancellationPostsACanceledResult()
        {
            // OnDisable cancels the window CTS; the posted Result must say Canceled so
            // OnBulkDone can skip touching the (closing) UI instead of rendering into it.
            var isWindows = RuntimeInformation.IsOSPlatform(OSPlatform.Windows);
            var file = isWindows ? "cmd.exe" : "/bin/sh";
            var args = isWindows ? "/c ping -n 60 127.0.0.1 > NUL" : "-c \"sleep 60\"";
            using var cts = new CancellationTokenSource();
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
                ctx: null,
                ct: cts.Token
            );
            cts.CancelAfter(300);
            Assert.IsTrue(done.Wait(30_000), "callback never fired");
            Assert.IsTrue(got.Value.Canceled);
        }
    }
}
