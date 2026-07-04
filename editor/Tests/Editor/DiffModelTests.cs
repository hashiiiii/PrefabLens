using NUnit.Framework;

namespace PrefabLens.Tests
{
    public class DiffModelTests
    {
        // core/tests/wasm_golden.test.mjs の GOLDEN と同一(スキーマ互換の回帰点)
        const string Golden =
            "{\"schema\":\"prefablens.diff.v2\",\"unresolvedGuids\":[\"def\"],\"roots\":[],\"loose\":[{\"kind\":\"component\",\"fileId\":\"11400000\",\"classId\":114,\"typeName\":\"MonoBehaviour\",\"scriptGuid\":\"def\",\"className\":null,\"status\":\"modified\",\"fields\":[{\"path\":\"Volume\",\"status\":\"modified\",\"before\":\"0.5\",\"after\":\"0.8\"}]}]}";

        [Test]
        public void ParsesTheWasmGolden()
        {
            var m = DiffModel.Parse(Golden);
            Assert.AreEqual(new[] { "def" }, m.UnresolvedGuids);
            Assert.AreEqual(0, m.Roots.Count);
            Assert.AreEqual(1, m.Loose.Count);
            var c = m.Loose[0];
            Assert.AreEqual("MonoBehaviour", c.TypeName);
            Assert.AreEqual("def", c.ScriptGuid);
            Assert.IsNull(c.ClassName);
            Assert.AreEqual(DiffStatus.Modified, c.Status);
            Assert.AreEqual(1, c.Fields.Count);
            Assert.AreEqual("Volume", c.Fields[0].Path);
            Assert.AreEqual("0.5", c.Fields[0].Before.Scalar);
            Assert.AreEqual("0.8", c.Fields[0].After.Scalar);
            Assert.IsFalse(m.IsEmpty);
        }

        [Test]
        public void ParsesNodesInstancesAndRefValues()
        {
            const string json = @"{
                ""schema"":""prefablens.diff.v2"",""unresolvedGuids"":[""aaa""],""resolved"":{},
                ""roots"":[{
                    ""kind"":""gameObject"",""fileId"":""1"",""name"":""Plane"",""status"":""unchanged"",""components"":[],
                    ""children"":[{
                        ""kind"":""prefabInstance"",""fileId"":""1001"",""name"":""Cylinder"",""status"":""added"",""sourceGuid"":""aaa"",
                        ""overrides"":[{""group"":""Transform"",""label"":""Position"",""status"":""added"",""before"":null,""after"":""(1, 2, 3)""}],
                        ""components"":[],
                        ""children"":[]
                    }]
                }],
                ""loose"":[{""kind"":""component"",""fileId"":""2"",""classId"":114,""typeName"":""MonoBehaviour"",""scriptGuid"":null,""className"":null,""status"":""modified"",
                    ""fields"":[{""path"":""Target"",""status"":""modified"",""before"":{""ref"":{""fileId"":""100"",""guid"":null,""type"":null}},""after"":{""ref"":{""fileId"":""0"",""guid"":""bbb"",""type"":2}}}]}]
            }";
            var m = DiffModel.Parse(json);
            var root = (GameObjectDiff)m.Roots[0];
            var inst = (PrefabInstanceDiff)root.Children[0];
            Assert.AreEqual("aaa", inst.SourceGuid);
            Assert.AreEqual(DiffStatus.Added, inst.Status);
            Assert.AreEqual("Transform", inst.Overrides[0].Group);
            Assert.IsTrue(inst.Overrides[0].Before.IsNull);
            Assert.AreEqual("(1, 2, 3)", inst.Overrides[0].After.Scalar);

            var field = m.Loose[0].Fields[0];
            Assert.IsTrue(field.Before.IsRef);
            Assert.AreEqual("100", field.Before.RefFileId);
            Assert.IsNull(field.Before.RefGuid);
            Assert.AreEqual("bbb", field.After.RefGuid);
        }

        [Test]
        public void SkipsUnknownNodeKindsAndToleratesMissingFields()
        {
            const string json = @"{
                ""unresolvedGuids"":[],
                ""roots"":[
                    {""kind"":""hologram"",""fileId"":""9"",""name"":""Future"",""status"":""added""},
                    {""kind"":""gameObject""}
                ],
                ""loose"":[]
            }";
            var m = DiffModel.Parse(json);
            Assert.AreEqual(1, m.Roots.Count); // 未知 kind は読み飛ばし、欠損フィールドは既定値
            Assert.AreEqual("", m.Roots[0].Name);
            Assert.AreEqual(DiffStatus.Unchanged, m.Roots[0].Status);
        }

        [Test]
        public void ResolveWithFillsOnlyUnresolvedGuids()
        {
            var m = DiffModel.Parse(Golden);
            m.Resolved["def"] = "Assets/Preexisting.cs";
            m.ResolveWith(_ => "Assets/FromAssetDatabase.cs");
            Assert.AreEqual("Assets/Preexisting.cs", m.Resolved["def"]); // 既存の解決が先勝ち

            var fresh = DiffModel.Parse(Golden);
            fresh.ResolveWith(g => g == "def" ? "Assets/Scripts/Sound.cs" : "");
            Assert.AreEqual("Assets/Scripts/Sound.cs", fresh.Resolved["def"]);

            var none = DiffModel.Parse(Golden);
            none.ResolveWith(_ => ""); // AssetDatabase が空を返したら未解決のまま
            Assert.IsFalse(none.Resolved.ContainsKey("def"));
        }
    }
}
