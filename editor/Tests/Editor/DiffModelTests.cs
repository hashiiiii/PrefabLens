using NUnit.Framework;

namespace PrefabLens.Tests
{
    public class DiffModelTests
    {
        // Identical to the GOLDEN in core/tests/wasm_golden.test.mjs (a schema-compat regression point)
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
            const string json =
                @"{
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
            const string json =
                @"{
                ""unresolvedGuids"":[],
                ""roots"":[
                    {""kind"":""hologram"",""fileId"":""9"",""name"":""Future"",""status"":""added""},
                    {""kind"":""gameObject""}
                ],
                ""loose"":[]
            }";
            var m = DiffModel.Parse(json);
            Assert.AreEqual(1, m.Roots.Count); // unknown kinds are skipped, missing fields default
            Assert.AreEqual("", m.Roots[0].Name);
            Assert.AreEqual(DiffStatus.Unchanged, m.Roots[0].Status);
        }

        [Test]
        public void EmptyDiffIsEmpty()
        {
            // On no changes the Window checks IsEmpty and shows "No semantic changes". The basis for that branch.
            var m = DiffModel.Parse(
                @"{""schema"":""prefablens.diff.v2"",""unresolvedGuids"":[],""roots"":[],""loose"":[]}"
            );
            Assert.IsTrue(m.IsEmpty);
        }

        [Test]
        public void ParsesResolvedMapAndRemovedStatus()
        {
            // resolved is the guid -> path already resolved by the CLI (that ResolveWith doesn't overwrite it is verified in another test).
            // removed is the one remaining status of the four not covered by other tests.
            const string json =
                @"{
                ""unresolvedGuids"":[],
                ""resolved"":{""ccc"":""Assets/Textures/Grass.png""},
                ""roots"":[],
                ""loose"":[{""kind"":""component"",""fileId"":""3"",""classId"":135,""typeName"":""SphereCollider"",""scriptGuid"":null,""className"":null,""status"":""removed"",
                    ""fields"":[{""path"":""m_Radius"",""status"":""removed"",""before"":""0.5"",""after"":null}]}]
            }";
            var m = DiffModel.Parse(json);
            Assert.AreEqual("Assets/Textures/Grass.png", m.Resolved["ccc"]);
            Assert.AreEqual(DiffStatus.Removed, m.Loose[0].Status);
            var f = m.Loose[0].Fields[0];
            Assert.AreEqual(DiffStatus.Removed, f.Status);
            Assert.AreEqual("0.5", f.Before.Scalar);
            Assert.IsTrue(f.After.IsNull);
        }

        [Test]
        public void ThrowsOnMalformedOrNonObjectJson()
        {
            // The bundled MiniJSON returns null on malformed input rather than throwing, but DiffModel.Parse
            // keeps the contract of throwing (which the Window converts into the "Could not parse CLI output" display).
            Assert.That(() => DiffModel.Parse("not json at all"), Throws.Exception);
            Assert.That(() => DiffModel.Parse(""), Throws.Exception);
            Assert.That(() => DiffModel.Parse("[]"), Throws.Exception); // root is not an object
        }

        [Test]
        public void ResolveWithFillsOnlyUnresolvedGuids()
        {
            var m = DiffModel.Parse(Golden);
            m.Resolved["def"] = "Assets/Preexisting.cs";
            m.ResolveWith(_ => "Assets/FromAssetDatabase.cs");
            Assert.AreEqual("Assets/Preexisting.cs", m.Resolved["def"]); // an existing resolution wins

            var fresh = DiffModel.Parse(Golden);
            fresh.ResolveWith(g => g == "def" ? "Assets/Scripts/Sound.cs" : "");
            Assert.AreEqual("Assets/Scripts/Sound.cs", fresh.Resolved["def"]);

            var none = DiffModel.Parse(Golden);
            none.ResolveWith(_ => ""); // if AssetDatabase returns empty, it stays unresolved
            Assert.IsFalse(none.Resolved.ContainsKey("def"));
        }
    }
}
