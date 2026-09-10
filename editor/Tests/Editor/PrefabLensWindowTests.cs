using System.Collections.Generic;
using NUnit.Framework;
using UnityEngine.UIElements;
#if UNITY_EDITOR
using System.Text.RegularExpressions;
using UnityEngine;
using UnityEngine.TestTools;
#endif

namespace PrefabLens.Tests
{
    public sealed class PrefabLensWindowTests
    {
        // One bulk entry in the v2 shape the window parses. A later failed refresh must
        // not leave this path selectable.
        const string OneFile =
            "[{\"path\":\"Assets/Smoke.prefab\",\"diff\":{\"schema\":\"prefablens.diff.v2\",\"unresolvedGuids\":[],\"roots\":[{\"kind\":\"gameObject\",\"fileId\":\"1\",\"name\":\"Smoke\",\"status\":\"unchanged\",\"components\":[{\"kind\":\"component\",\"fileId\":\"4\",\"classId\":4,\"typeName\":\"Transform\",\"scriptGuid\":null,\"className\":null,\"status\":\"modified\",\"fields\":[{\"path\":\"Position.x\",\"status\":\"modified\",\"before\":\"0\",\"after\":\"1\"}]}],\"children\":[]}],\"loose\":[]}}]";

        const string CliError = "fatal: Needed a single revision";

        [Test]
        public void FailedCliResultClearsThePreviousFileListAndKeepsTheError()
        {
            var window = OpenRenderedWindow();
            try
            {
                window.ShowBulkResult(Ok(OneFile), "HEAD");
                Assert.AreEqual(1, FileCount(window));

                window.ShowBulkResult(
                    new Cli.Result
                    {
                        ExitCode = 128,
                        Stdout = "",
                        Stderr = CliError + "\n",
                    },
                    "missing-ref"
                );

                Assert.AreEqual(0, FileCount(window));
                Assert.AreEqual("", window.StatusText);
                Assert.That(Labels(window.DetailPane), Does.Contain(CliError));
            }
            finally
            {
                CloseWindow(window);
            }
        }

        [Test]
        public void JsonParseFailureClearsThePreviousFileListAndKeepsTheDiagnostic()
        {
#if UNITY_EDITOR
            LogAssert.Expect(LogType.Exception, new Regex("bulk json root is not an array"));
#endif
            var window = OpenRenderedWindow();
            try
            {
                window.ShowBulkResult(Ok(OneFile), "HEAD");
                Assert.AreEqual(1, FileCount(window));

                window.ShowBulkResult(Ok("not json"), "HEAD");

                Assert.AreEqual(0, FileCount(window));
                Assert.AreEqual("", window.StatusText);
                var labels = Labels(window.DetailPane);
                Assert.That(labels, Does.Contain("Could not parse CLI output (CLI version mismatch?):"));
                Assert.That(labels, Does.Contain("not json"));
            }
            finally
            {
                CloseWindow(window);
            }
        }

        [Test]
        public void SuccessfulRefreshAfterFailureShowsTheNewFileListAndDiff()
        {
            var window = OpenRenderedWindow();
            try
            {
                window.ShowBulkResult(Ok(OneFile), "HEAD");
                window.ShowBulkResult(
                    new Cli.Result
                    {
                        ExitCode = 128,
                        Stdout = "",
                        Stderr = CliError,
                    },
                    "missing-ref"
                );

                window.ShowBulkResult(Ok(OneFile), "HEAD");

                Assert.AreEqual(1, FileCount(window));
                Assert.AreEqual("1 changed vs HEAD", window.StatusText);
                var labels = Labels(window.DetailPane);
                Assert.That(labels, Does.Contain("Assets/Smoke.prefab"));
                Assert.That(labels, Does.Not.Contain(CliError));
            }
            finally
            {
                CloseWindow(window);
            }
        }

        [Test]
        public void UnchangedStdoutKeepsTheFileListAndOnlyRestoresTheStatus()
        {
            // Focus-triggered refresh reuses the last stdout. The list and tree must stay
            // put; only the status line follows the current base ref.
            var window = OpenRenderedWindow();
            try
            {
                window.ShowBulkResult(Ok(OneFile), "HEAD");
                Assert.AreEqual(1, FileCount(window));

                window.ShowBulkResult(Ok(OneFile), "main");

                Assert.AreEqual(1, FileCount(window));
                Assert.AreEqual("1 changed vs main", window.StatusText);
                Assert.That(Labels(window.DetailPane), Does.Contain("Assets/Smoke.prefab"));
            }
            finally
            {
                CloseWindow(window);
            }
        }

        [Test]
        public void EmptyBulkResultShowsNoFilesAndTheNoChangesStatus()
        {
            var window = OpenRenderedWindow();
            try
            {
                window.ShowBulkResult(Ok("[]"), "HEAD");

                Assert.AreEqual(0, FileCount(window));
                Assert.AreEqual("No changes vs HEAD", window.StatusText);
            }
            finally
            {
                CloseWindow(window);
            }
        }

        [Test]
        public void EmptySemanticDiffShowsTheFileAndTheNoSemanticChangesNote()
        {
            const string emptyDiff =
                "[{\"path\":\"Assets/Smoke.prefab\",\"diff\":{\"schema\":\"prefablens.diff.v2\",\"unresolvedGuids\":[],\"roots\":[],\"loose\":[]}}]";
            var window = OpenRenderedWindow();
            try
            {
                window.ShowBulkResult(Ok(emptyDiff), "HEAD");

                Assert.AreEqual(1, FileCount(window));
                Assert.AreEqual("1 changed vs HEAD", window.StatusText);
                var labels = Labels(window.DetailPane);
                Assert.That(labels, Does.Contain("Assets/Smoke.prefab"));
                Assert.That(labels, Does.Contain("No semantic changes"));
            }
            finally
            {
                CloseWindow(window);
            }
        }

        static Cli.Result Ok(string stdout) =>
            new Cli.Result
            {
                ExitCode = 0,
                Stdout = stdout,
                Stderr = "",
            };

        static PrefabLensWindow OpenRenderedWindow()
        {
#if UNITY_EDITOR
            var window = ScriptableObject.CreateInstance<PrefabLensWindow>();
#else
            var window = new PrefabLensWindow();
#endif
            window.CreateLayout();
            return window;
        }

        static void CloseWindow(PrefabLensWindow window)
        {
#if UNITY_EDITOR
            window.Close();
#endif
        }

        static int FileCount(PrefabLensWindow window) => window.FileList.itemsSource?.Count ?? 0;

        static List<string> Labels(VisualElement root)
        {
            var texts = new List<string>();
            Collect(root, texts);
            return texts;
        }

        static void Collect(VisualElement element, List<string> texts)
        {
            if (element is Label label)
                texts.Add(label.text);
            foreach (var child in element.Children())
                Collect(child, texts);
        }
    }
}
