using System;
using System.IO;
using System.IO.Compression;
using NUnit.Framework;

namespace PrefabLens.Tests
{
    public partial class CliTests
    {
        static string NativeCliDirectory(string variable = "PREFABLENS_TEST_BIN_DIR")
        {
            var dir = Environment.GetEnvironmentVariable(variable);
            Assert.IsFalse(
                string.IsNullOrEmpty(dir),
                $"Set {variable} to a directory that contains the real native CLI executable."
            );
            return dir;
        }

        static void CopyNativeCli(string sourceDirectory, string destinationDirectory)
        {
            Directory.CreateDirectory(destinationDirectory);
            File.Copy(
                Path.Combine(sourceDirectory, Cli.BinaryName),
                Path.Combine(destinationDirectory, Cli.BinaryName)
            );
        }

        static byte[] CreateNativeArchive(string sourceDirectory, params (string SourceName, string EntryName)[] files)
        {
            using var buffer = new MemoryStream();
            using (var zip = new ZipArchive(buffer, ZipArchiveMode.Create, leaveOpen: true))
            {
                foreach (var file in files)
                {
                    using var source = File.OpenRead(Path.Combine(sourceDirectory, file.SourceName));
                    using var destination = zip.CreateEntry(file.EntryName).Open();
                    source.CopyTo(destination);
                }
            }
            return buffer.ToArray();
        }

        static byte[] CreateNativeCliArchive(string sourceDirectory) =>
            CreateNativeArchive(sourceDirectory, (Cli.BinaryName, Cli.BinaryName));

        [Test]
        public void LocateUsesAnExistingOverrideAndReportsNothingMissing()
        {
            var dir = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName());
            CopyNativeCli(NativeCliDirectory(), dir);
            var manual = Path.Combine(dir, Cli.BinaryName);
            try
            {
                var loc = Cli.Locate(manual, Path.Combine(dir, "default-prefablens"));
                Assert.AreEqual(manual, loc.Path);
                Assert.IsNull(loc.OverrideError);
            }
            finally
            {
                Directory.Delete(dir, recursive: true);
            }
        }

        [Test]
        public void LocateRejectsADefaultCliFromAnotherRelease()
        {
            // The automatic cache belongs to Cli.Version and cannot silently use another release.
            var dir = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName());
            CopyNativeCli(NativeCliDirectory("PREFABLENS_TEST_ALT_BIN_DIR"), dir);
            try
            {
                var loc = Cli.Locate("", Path.Combine(dir, Cli.BinaryName));
                Assert.IsNull(loc.Path);
            }
            finally
            {
                Directory.Delete(dir, recursive: true);
            }
        }

        [Test]
        public void LocateAcceptsAnOverrideFromAnotherRelease()
        {
            var dir = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName());
            CopyNativeCli(NativeCliDirectory("PREFABLENS_TEST_ALT_BIN_DIR"), dir);
            var manual = Path.Combine(dir, Cli.BinaryName);
            try
            {
                var loc = Cli.Locate(manual, Path.Combine(dir, "absent", Cli.BinaryName));
                Assert.AreEqual(manual, loc.Path);
                Assert.IsNull(loc.OverrideError);
            }
            finally
            {
                Directory.Delete(dir, recursive: true);
            }
        }

        [Test]
        public void LocateReportsAnInvalidOverrideWhileUsingTheDefault()
        {
            // The silent-fallback bug: an override pointing at a deleted binary used to be
            // indistinguishable from "no override set". The state must be reportable.
            var dir = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName());
            var defaultDirectory = Path.Combine(dir, "default");
            CopyNativeCli(NativeCliDirectory(), defaultDirectory);
            var def = Path.Combine(defaultDirectory, Cli.BinaryName);
            var gone = Path.Combine(dir, "gone-prefablens");
            try
            {
                var loc = Cli.Locate(gone, def);
                Assert.AreEqual(def, loc.Path);
                StringAssert.Contains(gone, loc.OverrideError);
            }
            finally
            {
                Directory.Delete(dir, recursive: true);
            }
        }

        [Test]
        public void LocateReportsAnInvalidOverrideWhenNothingElseExists()
        {
            var dir = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName());
            var gone = Path.Combine(dir, "gone-prefablens");
            var loc = Cli.Locate(gone, Path.Combine(dir, "default-prefablens"));
            Assert.IsNull(loc.Path);
            StringAssert.Contains(gone, loc.OverrideError);
        }

        [Test]
        public void LocateWithoutAnOverrideUsesTheDefaultOrNothing()
        {
            var dir = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName());
            var defaultDirectory = Path.Combine(dir, "default");
            CopyNativeCli(NativeCliDirectory(), defaultDirectory);
            var def = Path.Combine(defaultDirectory, Cli.BinaryName);
            try
            {
                Assert.AreEqual(def, Cli.Locate("", def).Path);
                Assert.IsNull(Cli.Locate("", def).OverrideError);
                var none = Cli.Locate("", Path.Combine(dir, "absent"));
                Assert.IsNull(none.Path);
                Assert.IsNull(none.OverrideError);
            }
            finally
            {
                Directory.Delete(dir, recursive: true);
            }
        }

        [Test]
        public void PathOverrideRoundTripsAndUnsetsThroughEditorPrefs()
        {
            // Save/restore: under real Unity EditMode this touches the developer's
            // actual EditorPrefs, so the original value must survive the test.
            var original = Cli.PathOverride;
            try
            {
                Cli.PathOverride = "/tmp/custom-prefablens";
                Assert.AreEqual("/tmp/custom-prefablens", Cli.PathOverride);
                // Clearing must remove the key entirely, not store an empty string:
                // Locate() treats "" as unset either way, but a deleted key keeps
                // the Preferences page's "unset" state honest.
                Cli.PathOverride = "";
                Assert.AreEqual("", Cli.PathOverride);
                Cli.PathOverride = null;
                Assert.AreEqual("", Cli.PathOverride);
            }
            finally
            {
                Cli.PathOverride = original;
            }
        }

        [Test]
        public void LocateReadsThePathOverride()
        {
            var original = Cli.PathOverride;
            var dir = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName());
            CopyNativeCli(NativeCliDirectory(), dir);
            var manual = Path.Combine(dir, Cli.BinaryName);
            try
            {
                Cli.PathOverride = manual;
                Assert.AreEqual(manual, Cli.Locate().Path);
            }
            finally
            {
                Cli.PathOverride = original;
                Directory.Delete(dir, recursive: true);
            }
        }
    }
}
