using NUnit.Framework;

namespace PrefabLens.Tests
{
    // The same decision-table cases live in cli/src/render_tree.zig and
    // cli/src/render_html.zig ("null reference reads as None") and the
    // extension's render.test.ts.
    public class ValueFormatTests
    {
        static DiffModel Model()
        {
            var m = DiffModel.Parse("{\"schema\":\"prefablens.diff.v2\",\"unresolvedGuids\":[],\"roots\":[],\"loose\":[]}");
            m.Resolved["abc123"] = "Assets/Materials/Fixture.mat";
            return m;
        }

        static Value Ref(string fileId, string guid) =>
            new() { IsRef = true, RefFileId = fileId, RefGuid = guid };

        [Test]
        public void MissingSideReadsAsDash() =>
            Assert.AreEqual("—", ValueFormat.Format(Value.Null, Model()));

        [Test]
        public void ScalarPassesThrough() =>
            Assert.AreEqual("0.5", ValueFormat.Format(new Value { Scalar = "0.5" }, Model()));

        [Test]
        public void ResolvedExternalRefReadsAsFullAssetPath() =>
            Assert.AreEqual("Assets/Materials/Fixture.mat", ValueFormat.Format(Ref("2100000", "abc123"), Model()));

        [Test]
        public void BuiltinRefReadsAsObjectName() =>
            Assert.AreEqual("Cube (built-in)", ValueFormat.Format(Ref("10202", BuiltinRefs.DefaultResourcesGuid), Model()));

        [Test]
        public void BuiltinGuidWithUnknownFileIdKeepsTheGuid() =>
            Assert.AreEqual("guid:" + BuiltinRefs.DefaultResourcesGuid, ValueFormat.Format(Ref("424242", BuiltinRefs.DefaultResourcesGuid), Model()));

        [Test]
        public void UnresolvedExternalRefKeepsTheGuid() =>
            Assert.AreEqual("guid:def", ValueFormat.Format(Ref("11500000", "def"), Model()));

        [Test]
        public void NullReferenceReadsAsNone() =>
            Assert.AreEqual("None", ValueFormat.Format(Ref("0", null), Model()));

        [Test]
        public void LocalRefReadsAsHashFileId() =>
            Assert.AreEqual("#42", ValueFormat.Format(Ref("42", null), Model()));
    }
}
