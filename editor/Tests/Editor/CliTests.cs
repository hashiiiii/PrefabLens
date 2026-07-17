using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
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
        public void BuildBulkArgsWithABaseRefComparesRefVsWorkingTree()
        {
            // CLI grammar (cli/src/main.zig parseArgs): one operand without a Unity YAML
            // extension is a git ref, so `prefablens <ref> --json` is ref vs working tree,
            // still bulk mode because no path operand is given.
            Assert.AreEqual(new[] { "main", "--json" }, Cli.BuildBulkArgs("main"));
            Assert.AreEqual(new[] { "HEAD~1", "--json" }, Cli.BuildBulkArgs("HEAD~1"));
        }

        [Test]
        public void BuildBulkArgsTreatsABlankBaseRefAsTheDefault()
        {
            // The window feeds a free-form text field straight in: null, empty, and
            // whitespace-only must all keep the default invocation byte-for-byte, and
            // surrounding whitespace must not leak into the git ref.
            Assert.AreEqual(new[] { "--json" }, Cli.BuildBulkArgs(null));
            Assert.AreEqual(new[] { "--json" }, Cli.BuildBulkArgs(""));
            Assert.AreEqual(new[] { "--json" }, Cli.BuildBulkArgs("   "));
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

        /// One-shot HTTP server on a loopback socket: real HttpClient traffic, no mocks.
        /// Sends Content-Length: body.Length but only the first sendOnly bytes, then blocks
        /// on release — that models a stalled connection for the cancellation test.
        static TcpListener ServeOnce(byte[] body, int sendOnly, ManualResetEventSlim release, out int port)
        {
            var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            port = ((IPEndPoint)listener.LocalEndpoint).Port;
            Task.Run(() =>
            {
                using var client = listener.AcceptTcpClient();
                var stream = client.GetStream();
                // Drain the request head so the client is not reset mid-request.
                stream.Read(new byte[4096], 0, 4096);
                var head = Encoding.ASCII.GetBytes(
                    $"HTTP/1.1 200 OK\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n"
                );
                stream.Write(head, 0, head.Length);
                stream.Write(body, 0, sendOnly);
                stream.Flush();
                if (sendOnly < body.Length)
                    release.Wait(30_000);
            });
            return listener;
        }

        [Test]
        public void FetchBytesReportsProgressAndReturnsTheExactBody()
        {
            var body = new byte[200_000];
            new Random(42).NextBytes(body);
            using var release = new ManualResetEventSlim();
            var listener = ServeOnce(body, sendOnly: body.Length, release, out var port);
            try
            {
                using var http = new HttpClient();
                long lastRead = 0,
                    lastTotal = 0;
                var got = Cli.FetchBytes(
                    http,
                    $"http://127.0.0.1:{port}/",
                    (read, total) =>
                    {
                        lastRead = read;
                        lastTotal = total;
                    },
                    CancellationToken.None
                );
                Assert.AreEqual(body, got);
                // The final callback must report completion against the advertised Content-Length,
                // otherwise the window's percentage never reaches 100%.
                Assert.AreEqual(body.Length, lastRead);
                Assert.AreEqual(body.Length, lastTotal);
            }
            finally
            {
                release.Set();
                listener.Stop();
            }
        }

        [Test]
        public void FetchBytesCancelsMidStream()
        {
            // The server stalls after half the body; cancelling from the first progress
            // callback must abort the blocked read instead of waiting for more bytes.
            var body = new byte[200_000];
            using var release = new ManualResetEventSlim();
            var listener = ServeOnce(body, sendOnly: body.Length / 2, release, out var port);
            try
            {
                using var http = new HttpClient();
                using var cts = new CancellationTokenSource();
                var sw = Stopwatch.StartNew();
                Assert.Catch<OperationCanceledException>(() =>
                    Cli.FetchBytes(http, $"http://127.0.0.1:{port}/", (read, total) => cts.Cancel(), cts.Token)
                );
                sw.Stop();
                Assert.Less(sw.ElapsedMilliseconds, 30_000, "cancellation must not degrade into a full wait");
            }
            finally
            {
                release.Set();
                listener.Stop();
            }
        }

        [Test]
        public void ExpectedSha256FindsTheAssetLine()
        {
            // shasum -a 256 text-mode output: "<hex>  <name>" (two spaces), one line per asset.
            var sums = "aaaa  prefablens-linux-x64.zip\nbbbb  prefablens-macos-arm64.zip\n";
            Assert.AreEqual("bbbb", Cli.ExpectedSha256(sums, "prefablens-macos-arm64.zip"));
            Assert.IsNull(Cli.ExpectedSha256(sums, "prefablens-windows-x64.zip"));
        }

        [Test]
        public void Sha256HexMatchesAKnownVector()
        {
            // FIPS 180-2 test vector for "abc".
            Assert.AreEqual(
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                Cli.Sha256Hex(Encoding.ASCII.GetBytes("abc"))
            );
        }

        [Test]
        public void VerifySha256AcceptsAMatchingArchive()
        {
            var sums = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  prefablens-macos-arm64.zip\n";
            Assert.DoesNotThrow(() =>
                Cli.VerifySha256(Encoding.ASCII.GetBytes("abc"), sums, "prefablens-macos-arm64.zip")
            );
        }

        [Test]
        public void VerifySha256RejectsACorruptedArchive()
        {
            // A byte flipped after publication must fail before extraction, naming both digests.
            var sums = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  prefablens-macos-arm64.zip\n";
            var e = Assert.Throws<InvalidOperationException>(() =>
                Cli.VerifySha256(Encoding.ASCII.GetBytes("abd"), sums, "prefablens-macos-arm64.zip")
            );
            StringAssert.Contains("mismatch", e.Message);
            StringAssert.Contains("ba7816bf", e.Message);
        }

        [Test]
        public void VerifySha256RejectsAnAssetMissingFromSums()
        {
            // A release missing the entry is as suspect as a bad hash: never extract unverified bytes.
            var e = Assert.Throws<InvalidOperationException>(() =>
                Cli.VerifySha256(new byte[0], "aaaa  other.zip\n", "prefablens-linux-arm64.zip")
            );
            StringAssert.Contains("no entry", e.Message);
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
        public void RunProcessWithAnUncanceledTokenBehavesAsBefore()
        {
            // The token is additive: a live token must not disturb the normal exit path.
            var isWindows = RuntimeInformation.IsOSPlatform(OSPlatform.Windows);
            var file = isWindows ? "cmd.exe" : "/bin/sh";
            var args = isWindows ? "/c echo hello" : "-c \"echo hello\"";
            using var cts = new CancellationTokenSource();
            var res = Cli.RunProcess(file, args, ".", timeoutMs: Cli.RunTimeoutMs, ct: cts.Token);
            Assert.IsFalse(res.Canceled);
            Assert.AreEqual(0, res.ExitCode);
            StringAssert.Contains("hello", res.Stdout);
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
