using NUnit.Framework;

namespace PrefabLens.Tests
{
    public class BulkModelTests
    {
        // Shape emitted by `prefablens --json` (bulk mode, v0.6.1), verified against the
        // released binary: a top-level array of {path, diff} objects.
        const string Bulk =
            "[{\"path\":\"Assets/Smoke.prefab\",\"diff\":{\"schema\":\"prefablens.diff.v2\",\"unresolvedGuids\":[],\"roots\":[{\"kind\":\"gameObject\",\"fileId\":\"1\",\"name\":\"Smoke\",\"status\":\"unchanged\",\"components\":[{\"kind\":\"component\",\"fileId\":\"4\",\"classId\":4,\"typeName\":\"Transform\",\"scriptGuid\":null,\"className\":null,\"status\":\"modified\",\"fields\":[{\"path\":\"Position.x\",\"status\":\"modified\",\"before\":\"0\",\"after\":\"1\"}]}],\"children\":[]}],\"loose\":[]}},"
            + "{\"path\":\"ProjectSettings/ProjectSettings.asset\",\"diff\":{\"schema\":\"prefablens.diff.v2\",\"unresolvedGuids\":[],\"roots\":[],\"loose\":[{\"kind\":\"component\",\"fileId\":\"1\",\"classId\":129,\"typeName\":\"PlayerSettings\",\"scriptGuid\":null,\"className\":null,\"status\":\"modified\",\"fields\":[]}]}}]";

        [Test]
        public void ParsesEntriesInOrder()
        {
            var m = BulkModel.Parse(Bulk);
            Assert.AreEqual(2, m.Entries.Count);
            Assert.AreEqual("Assets/Smoke.prefab", m.Entries[0].Path);
            Assert.AreEqual("Smoke", m.Entries[0].Diff.Roots[0].Name);
            Assert.AreEqual("ProjectSettings/ProjectSettings.asset", m.Entries[1].Path);
            Assert.AreEqual("PlayerSettings", m.Entries[1].Diff.Loose[0].TypeName);
        }

        [Test]
        public void EmptyArrayYieldsNoEntries()
        {
            Assert.AreEqual(0, BulkModel.Parse("[]").Entries.Count);
        }

        [Test]
        public void ThrowsOnMalformedOrNonArrayJson()
        {
            // Same contract as DiffModel.Parse: the window converts the throw into
            // the "Could not parse CLI output" display.
            Assert.That(() => BulkModel.Parse("not json"), Throws.Exception);
            Assert.That(() => BulkModel.Parse(""), Throws.Exception);
            Assert.That(() => BulkModel.Parse("{}"), Throws.Exception); // root is not an array
        }

        [Test]
        public void SkipsEntriesMissingPathOrDiff()
        {
            var m = BulkModel.Parse(
                "[{\"path\":\"Assets/A.prefab\"},{\"diff\":{\"roots\":[],\"loose\":[]}},{\"path\":\"Assets/B.prefab\",\"diff\":{\"roots\":[],\"loose\":[]}}]"
            );
            Assert.AreEqual(1, m.Entries.Count);
            Assert.AreEqual("Assets/B.prefab", m.Entries[0].Path);
        }

        [Test]
        public void AggregateStatusDerivesTheListBadge()
        {
            // All top-level statuses added -> Added (new asset), all removed -> Removed
            // (deleted asset), anything else -> Modified. Empty diff -> Modified
            // (the file changed in git even if the semantic diff is empty).
            var added = DiffModel.Parse(
                "{\"roots\":[{\"kind\":\"gameObject\",\"status\":\"added\"}],\"loose\":[{\"kind\":\"component\",\"status\":\"added\"}]}"
            );
            var removed = DiffModel.Parse(
                "{\"roots\":[{\"kind\":\"gameObject\",\"status\":\"removed\"}],\"loose\":[]}"
            );
            var mixed = DiffModel.Parse(
                "{\"roots\":[{\"kind\":\"gameObject\",\"status\":\"unchanged\"}],\"loose\":[]}"
            );
            var empty = DiffModel.Parse("{\"roots\":[],\"loose\":[]}");
            Assert.AreEqual(DiffStatus.Added, BulkModel.AggregateStatus(added));
            Assert.AreEqual(DiffStatus.Removed, BulkModel.AggregateStatus(removed));
            Assert.AreEqual(DiffStatus.Modified, BulkModel.AggregateStatus(mixed));
            Assert.AreEqual(DiffStatus.Modified, BulkModel.AggregateStatus(empty));
        }
    }
}
