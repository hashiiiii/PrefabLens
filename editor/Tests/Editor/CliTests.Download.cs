using System;
using System.Diagnostics;
using System.IO;
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
    public partial class CliTests
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
        public void ExtractToWritesOnlyTheExactNativeCliEntry()
        {
            var archive = CreateNativeArchive(
                NativeCliDirectory(),
                (Cli.BinaryName, Cli.BinaryName),
                (Cli.BinaryName, "ignored-command")
            );
            var dir = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName());
            Directory.CreateDirectory(dir);
            try
            {
                Cli.ExtractTo(archive, dir);
                CollectionAssert.AreEqual(
                    File.ReadAllBytes(Path.Combine(NativeCliDirectory(), Cli.BinaryName)),
                    File.ReadAllBytes(Path.Combine(dir, Cli.BinaryName))
                );
                var extracted = Directory.GetFiles(dir);
                Assert.AreEqual(1, extracted.Length);
                Assert.AreEqual(Cli.BinaryName, Path.GetFileName(extracted[0]));
            }
            finally
            {
                Directory.Delete(dir, recursive: true);
            }
        }

        [Test]
        public void ExtractToRejectsAnArchiveWithoutTheExactNativeCliEntry()
        {
            var archive = CreateNativeArchive(NativeCliDirectory(), (Cli.BinaryName, "nested/" + Cli.BinaryName));
            var dir = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName());
            Directory.CreateDirectory(dir);
            try
            {
                var error = Assert.Throws<InvalidOperationException>(() => Cli.ExtractTo(archive, dir));
                StringAssert.Contains(Cli.BinaryName, error.Message);
                Assert.IsEmpty(Directory.GetFiles(dir));
            }
            finally
            {
                Directory.Delete(dir, recursive: true);
            }
        }

        [Test]
        public void MarkExecutableMakesTheRealNativeCliRunnable()
        {
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
                Assert.Ignore("chmod is a Unix concern");
            var dir = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName());
            Directory.CreateDirectory(dir);
            try
            {
                var archive = CreateNativeCliArchive(NativeCliDirectory());
                Cli.ExtractTo(archive, dir);
                var cliPath = Path.Combine(dir, Cli.BinaryName);
                Cli.MarkExecutable(cliPath);

                Assert.AreEqual(0, Cli.RunProcess(cliPath, "--version", dir, 10_000).ExitCode);
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
        public void InstallArchiveInstallsAndRunsTheNativeCli()
        {
            // ZIP extraction removes Unix execute bits, so installation must make the CLI executable.
            var root = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName());
            var finalDirectory = Path.Combine(root, Cli.Version);
            var archive = CreateNativeCliArchive(NativeCliDirectory());
            try
            {
                var installed = Cli.InstallArchive(archive, finalDirectory, Cli.Version);
                Assert.AreEqual(Path.Combine(finalDirectory, Cli.BinaryName), installed);
                Assert.AreEqual(0, Cli.RunProcess(installed, "--version", finalDirectory, 10_000).ExitCode);
            }
            finally
            {
                if (Directory.Exists(root))
                    Directory.Delete(root, recursive: true);
            }
        }

        [Test]
        public void InstallArchiveSucceedsInsideADirectoryWithSpacesAndQuotes()
        {
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
                Assert.Ignore("Windows filesystem naming rules are out of scope");
            var root = Path.Combine(Path.GetTempPath(), "Project \"quoted\" " + Path.GetRandomFileName());
            var finalDirectory = Path.Combine(root, Cli.Version);
            var archive = CreateNativeCliArchive(NativeCliDirectory());
            try
            {
                var installed = Cli.InstallArchive(archive, finalDirectory, Cli.Version);
                Assert.AreEqual(Path.Combine(finalDirectory, Cli.BinaryName), installed);
                var version = Cli.RunProcess(installed, "--version", finalDirectory, 10_000);
                Assert.AreEqual(0, version.ExitCode);
                StringAssert.Contains("prefablens " + Cli.Version, version.Stdout.Trim());
            }
            finally
            {
                if (Directory.Exists(root))
                    Directory.Delete(root, recursive: true);
            }
        }

        [Test]
        public void InstallArchiveKeepsAUsableCacheWhenTheArchiveHasAnotherVersion()
        {
            // Validation must finish in staging before the installer replaces a usable cache.
            var root = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName());
            var finalDirectory = Path.Combine(root, Cli.Version);
            CopyNativeCli(NativeCliDirectory(), finalDirectory);
            var cliPath = Path.Combine(finalDirectory, Cli.BinaryName);
            var originalCli = File.ReadAllBytes(cliPath);
            var archive = CreateNativeCliArchive(NativeCliDirectory("PREFABLENS_TEST_ALT_BIN_DIR"));
            try
            {
                Assert.Throws<InvalidOperationException>(() =>
                    Cli.InstallArchive(archive, finalDirectory, Cli.Version)
                );
                CollectionAssert.AreEqual(originalCli, File.ReadAllBytes(cliPath));
                Assert.AreEqual(cliPath, Cli.Locate("", cliPath).Path);
            }
            finally
            {
                Directory.Delete(root, recursive: true);
            }
        }

        [Test]
        public void MarkExecutableFailsTheDownloadStepNamingTheBinaryPath()
        {
            // A swallowed chmod failure used to resurface later as an unrelated
            // Process.Start error on first run; it must fail here, naming the path.
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
                Assert.Ignore("chmod is a unix concern");
            var missing = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName(), "prefablens");
            var e = Assert.Throws<InvalidOperationException>(() => Cli.MarkExecutable(missing));
            StringAssert.Contains(missing, e.Message);
        }
    }
}
