using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
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
        public void BuildArgsDiffsHeadAgainstTheWorktreeAsJson()
        {
            Assert.AreEqual(
                new[] { "--git", "HEAD", "Assets/Foo.prefab", "--json" },
                Cli.BuildArgs("Assets/Foo.prefab")
            );
        }

        [Test]
        public void QuoteArgsSurvivesSpacesAndQuotes()
        {
            Assert.AreEqual(
                "\"--git\" \"HEAD\" \"Assets/My Prefab.prefab\" \"--json\"",
                Cli.QuoteArgs(Cli.BuildArgs("Assets/My Prefab.prefab"))
            );
            Assert.AreEqual("\"a\\\"b\"", Cli.QuoteArgs(new[] { "a\"b" }));
        }

        [Test]
        public void ParseSha256SumsFindsTheAssetLine()
        {
            // Exactly the form release.yml's `sha256sum *.zip` produces.
            var sums =
                "1111111111111111111111111111111111111111111111111111111111111111  prefablens-linux-x64.zip\n"
                + "2222222222222222222222222222222222222222222222222222222222222222  prefablens-macos-arm64.zip\n";
            Assert.AreEqual(
                "2222222222222222222222222222222222222222222222222222222222222222",
                Cli.ParseSha256Sums(sums, "prefablens-macos-arm64.zip")
            );
            Assert.IsNull(Cli.ParseSha256Sums(sums, "prefablens-windows-x64.zip"));
        }

        [Test]
        public void ParseSha256SumsHandlesCrlfAndBinaryMarker()
        {
            // Also accepts CRLF line endings and sha256sum binary mode's leading "*".
            var sums = "cafe01 *prefablens-windows-x64.zip\r\n";
            Assert.AreEqual("cafe01", Cli.ParseSha256Sums(sums, "prefablens-windows-x64.zip"));
        }

        [Test]
        public void Sha256HexMatchesTheStandardTestVector()
        {
            // Known vector from FIPS 180-2: sha256("abc")
            Assert.AreEqual(
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                Cli.Sha256Hex(Encoding.ASCII.GetBytes("abc"))
            );
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
    }
}
