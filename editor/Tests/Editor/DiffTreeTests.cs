using System.Collections.Generic;
using NUnit.Framework;
using UnityEngine;

namespace PrefabLens.Tests
{
    // Pins the DiffModel -> rows/spans mapping that DiffTreeView maps to UI Toolkit elements
    // (same color tone and notation as the Chrome renderer). Tints are compared against
    // Palette properties rather than raw hex so the tests hold under both editor skins.
    public class DiffTreeTests
    {
        static List<DiffTree.Item> Build(string json) => DiffTree.Build(DiffModel.Parse(json));

        static void AssertSpan(Span s, string text, Color? tint)
        {
            Assert.AreEqual(text, s.Text);
            Assert.AreEqual(tint, s.Tint);
        }

        [Test]
        public void BadgeMarksMirrorTheChromeRenderer()
        {
            // + / − / ~ prefixes tinted with the status color; unchanged keeps a
            // two-space placeholder (no tint) so names stay column-aligned.
            AssertSpan(DiffTree.Badge(DiffStatus.Added).Spans[0], "+ ", Palette.Added);
            AssertSpan(DiffTree.Badge(DiffStatus.Removed).Spans[0], "− ", Palette.Removed);
            AssertSpan(DiffTree.Badge(DiffStatus.Modified).Spans[0], "~ ", Palette.Modified);
            AssertSpan(DiffTree.Badge(DiffStatus.Unchanged).Spans[0], "  ", null);
        }

        [Test]
        public void RowSuppressesNullAndEmptySpans()
        {
            // A node with no name must not emit an empty Label after the badge.
            var row = new Row().Add(null).Add("");
            Assert.AreEqual(0, row.Spans.Count);
        }

        [Test]
        public void NodesComeBeforeTheLooseComponentsGroup()
        {
            // The group keeps loose components separate from the GameObject hierarchy.
            const string json =
                @"{
                ""unresolvedGuids"":[],
                ""roots"":[{""kind"":""gameObject"",""fileId"":""1"",""name"":""Plane"",""status"":""unchanged"",""components"":[],""children"":[]}],
                ""loose"":[{""kind"":""component"",""fileId"":""2"",""classId"":135,""typeName"":""SphereCollider"",""scriptGuid"":null,""className"":null,""status"":""added"",""fields"":[]}]
            }";
            var items = Build(json);
            Assert.AreEqual(2, items.Count);
            AssertSpan(items[0].Row.Spans[1], "Plane", null);
            AssertSpan(items[1].Row.Spans[1], "Components (1)", Palette.Muted);
            AssertSpan(items[1].Children[0].Row.Spans[0], "+ ", Palette.Added);
            AssertSpan(items[1].Children[0].Row.Spans[1], "SphereCollider", null);
        }

        [Test]
        public void ComponentsGroupShowsItsCardCount()
        {
            // The count helps readers scan the tree before they expand the group.
            const string json =
                @"{
                ""unresolvedGuids"":[],
                ""roots"":[{""kind"":""gameObject"",""fileId"":""1"",""name"":""Plane"",""status"":""modified"",
                    ""components"":[{""kind"":""component"",""fileId"":""4"",""classId"":4,""typeName"":""Transform"",""scriptGuid"":null,""className"":null,""status"":""modified"",""fields"":[]}],
                    ""children"":[]}],
                ""loose"":[]
            }";
            var items = Build(json);
            AssertSpan(items[0].Row.Spans[0], "~ ", Palette.Modified);
            var group = items[0].Children[0];
            AssertSpan(group.Row.Spans[0], "  ", null);
            AssertSpan(group.Row.Spans[1], "Components (1)", Palette.Muted);
            AssertSpan(group.Children[0].Row.Spans[1], "Transform", null);
        }

        [Test]
        public void OverrideGroupsBecomeCardsInsideComponents()
        {
            // Override cards and real components use one count because both appear in the Inspector area.
            const string json =
                @"{
                ""unresolvedGuids"":[],
                ""roots"":[{""kind"":""gameObject"",""fileId"":""1"",""name"":""Sensor"",""status"":""modified"",
                    ""overrides"":[
                        {""group"":""GameObject"",""label"":""Name"",""status"":""modified"",""before"":""Head"",""after"":""Sensor""},
                        {""group"":""Transform"",""label"":""Position.y"",""status"":""modified"",""before"":""2"",""after"":""2.2""},
                        {""group"":""Transform"",""label"":""Position.z"",""status"":""added"",""before"":null,""after"":""0.1""}
                    ],
                    ""components"":[{""kind"":""component"",""fileId"":""4"",""classId"":4,""typeName"":""Transform"",""scriptGuid"":null,""className"":null,""status"":""modified"",""fields"":[]}],
                    ""children"":[]}],
                ""loose"":[]
            }";
            var root = Build(json)[0];

            Assert.AreEqual(1, root.Children.Count);
            var components = root.Children[0];
            AssertSpan(components.Row.Spans[1], "Components (3)", Palette.Muted);
            Assert.AreEqual(3, components.Children.Count);
            AssertSpan(components.Children[0].Row.Spans[1], "GameObject", null);
            AssertSpan(components.Children[0].Children[0].Row.Spans[1], "Name ", Palette.Muted);
            AssertSpan(components.Children[1].Row.Spans[1], "Transform", null);
            Assert.AreEqual(2, components.Children[1].Children.Count);
            AssertSpan(components.Children[2].Row.Spans[1], "Transform", null);
        }

        [Test]
        public void ModifiedFieldReadsBeforeArrowAfter()
        {
            const string json =
                @"{
                ""unresolvedGuids"":[],
                ""roots"":[],
                ""loose"":[{""kind"":""component"",""fileId"":""4"",""classId"":4,""typeName"":""Transform"",""scriptGuid"":null,""className"":null,""status"":""modified"",
                    ""fields"":[{""path"":""Position"",""status"":""modified"",""before"":""(0, 0, 0)"",""after"":""(1, 0, 0)""}]}]
            }";
            var field = Build(json)[0].Children[0].Children[0].Row;
            AssertSpan(field.Spans[0], "~ ", Palette.Modified);
            AssertSpan(field.Spans[1], "Position ", Palette.Muted); // trailing space separates label and value
            AssertSpan(field.Spans[2], "(0, 0, 0)", Palette.Removed);
            AssertSpan(field.Spans[3], " → ", Palette.Muted);
            AssertSpan(field.Spans[4], "(1, 0, 0)", Palette.Added);
        }

        [Test]
        public void SingleSidedFieldsShowOnlyTheExistingValue()
        {
            // removed -> before only (red); added -> after only (green);
            // unchanged -> after with no tint. One fixture covers all three branches.
            const string json =
                @"{
                ""unresolvedGuids"":[],
                ""roots"":[],
                ""loose"":[{""kind"":""component"",""fileId"":""2"",""classId"":54,""typeName"":""Rigidbody"",""scriptGuid"":null,""className"":null,""status"":""modified"",
                    ""fields"":[
                        {""path"":""Speed"",""status"":""removed"",""before"":""2"",""after"":null},
                        {""path"":""Mass"",""status"":""added"",""before"":null,""after"":""10""},
                        {""path"":""Drag"",""status"":""unchanged"",""before"":""0"",""after"":""0""}
                    ]}]
            }";
            var fields = Build(json)[0].Children[0].Children;
            Assert.AreEqual(3, fields[0].Row.Spans.Count);
            AssertSpan(fields[0].Row.Spans[2], "2", Palette.Removed);
            Assert.AreEqual(3, fields[1].Row.Spans.Count);
            AssertSpan(fields[1].Row.Spans[2], "10", Palette.Added);
            Assert.AreEqual(3, fields[2].Row.Spans.Count);
            AssertSpan(fields[2].Row.Spans[2], "0", null);
        }

        [Test]
        public void StructuralFieldsShowTheLabelAndStatusWithoutAFakeValue()
        {
            // Structural summaries have no value, so the row must preserve status without adding a placeholder.
            const string json =
                @"{
                ""unresolvedGuids"":[],
                ""roots"":[],
                ""loose"":[{""kind"":""component"",""fileId"":""2"",""classId"":54,""typeName"":""Rigidbody"",""scriptGuid"":null,""className"":null,""status"":""modified"",
                    ""fields"":[
                        {""path"":""Added Components (1)"",""status"":""added"",""before"":null,""after"":null},
                        {""path"":""Removed Components (1)"",""status"":""removed"",""before"":null,""after"":null}
                    ]}]
            }";
            var fields = Build(json)[0].Children[0].Children;

            Assert.AreEqual(RowKind.Summary, fields[0].Row.Kind);
            Assert.AreEqual(DiffStatus.Added, fields[0].Row.Status);
            Assert.AreEqual(2, fields[0].Row.Spans.Count);
            AssertSpan(fields[0].Row.Spans[1], "Added Components (1)", Palette.Muted);
            Assert.AreEqual(RowKind.Summary, fields[1].Row.Kind);
            Assert.AreEqual(DiffStatus.Removed, fields[1].Row.Status);
            Assert.AreEqual(2, fields[1].Row.Spans.Count);
            AssertSpan(fields[1].Row.Spans[1], "Removed Components (1)", Palette.Muted);
        }

        [Test]
        public void PrefabInstanceShowsItsSourceAfterTheName()
        {
            // Resolved source guid reads as the asset path; unresolved keeps the raw guid.
            const string json =
                @"{
                ""unresolvedGuids"":[""xyz""],
                ""resolved"":{""srcguid"":""Assets/Prefabs/Cylinder.prefab""},
                ""roots"":[
                    {""kind"":""prefabInstance"",""fileId"":""1001"",""name"":""Cylinder"",""status"":""added"",""sourceGuid"":""srcguid"",""overrides"":[],""components"":[],""children"":[]},
                    {""kind"":""prefabInstance"",""fileId"":""1002"",""name"":""Sphere"",""status"":""unchanged"",""sourceGuid"":""xyz"",""overrides"":[],""components"":[],""children"":[]}
                ],
                ""loose"":[]
            }";
            var items = Build(json);
            AssertSpan(items[0].Row.Spans[1], "Cylinder", null);
            AssertSpan(items[0].Row.Spans[2], " ‹Prefab: Assets/Prefabs/Cylinder.prefab›", Palette.Muted);
            AssertSpan(items[1].Row.Spans[2], " ‹Prefab: xyz›", Palette.Muted);
        }

        [Test]
        public void OverrideCardsKeepTheGroupNameSeparateFromTheFieldLabel()
        {
            // Separate labels make the card hierarchy match the CLI and extension views.
            const string json =
                @"{
                ""unresolvedGuids"":[],
                ""roots"":[{""kind"":""prefabInstance"",""fileId"":""1001"",""name"":""Cylinder"",""status"":""modified"",""sourceGuid"":null,
                    ""overrides"":[
                        {""group"":""Transform"",""label"":""Position"",""status"":""modified"",""before"":""0"",""after"":""1""},
                        {""group"":""Overrides"",""label"":""Active"",""status"":""modified"",""before"":""0"",""after"":""1""},
                        {""group"":"""",""label"":""Name"",""status"":""modified"",""before"":""a"",""after"":""b""}
                    ],
                    ""components"":[],""children"":[]}],
                ""loose"":[]
            }";
            var cards = Build(json)[0].Children[0].Children;
            AssertSpan(cards[0].Row.Spans[1], "Transform", null);
            AssertSpan(cards[0].Children[0].Row.Spans[1], "Position ", Palette.Muted);
            AssertSpan(cards[1].Row.Spans[1], "Overrides", null);
            AssertSpan(cards[1].Children[0].Row.Spans[1], "Active ", Palette.Muted);
            AssertSpan(cards[2].Row.Spans[1], "Overrides", null);
            AssertSpan(cards[2].Children[0].Row.Spans[1], "Name ", Palette.Muted);
        }

        [Test]
        public void ComponentNamePrefersClassNameThenResolvedScriptThenTypeName()
        {
            const string json =
                @"{
                ""unresolvedGuids"":[""ghost""],
                ""resolved"":{""runner"":""Assets/Scripts/Runner.cs""},
                ""roots"":[],
                ""loose"":[
                    {""kind"":""component"",""fileId"":""1"",""classId"":114,""typeName"":""MonoBehaviour"",""scriptGuid"":null,""className"":""Mover"",""status"":""added"",""fields"":[]},
                    {""kind"":""component"",""fileId"":""2"",""classId"":114,""typeName"":""MonoBehaviour"",""scriptGuid"":""runner"",""className"":null,""status"":""added"",""fields"":[]},
                    {""kind"":""component"",""fileId"":""3"",""classId"":114,""typeName"":""MonoBehaviour"",""scriptGuid"":""ghost"",""className"":null,""status"":""added"",""fields"":[]},
                    {""kind"":""component"",""fileId"":""4"",""classId"":4,""typeName"":""Transform"",""scriptGuid"":null,""className"":null,""status"":""added"",""fields"":[]}
                ]
            }";
            var items = Build(json)[0].Children;
            // The C# class name from the CLI wins outright.
            AssertSpan(items[0].Row.Spans[1], "Mover", null);
            AssertSpan(items[0].Row.Spans[2], " ‹Script›", Palette.Muted);
            // A resolved script guid shows the file stem and the full source path.
            AssertSpan(items[1].Row.Spans[1], "Runner", null);
            AssertSpan(items[1].Row.Spans[2], " ‹Script: Assets/Scripts/Runner.cs›", Palette.Muted);
            // Unresolved guid falls back to the Unity type name, without the Script tag.
            Assert.AreEqual(2, items[2].Row.Spans.Count);
            AssertSpan(items[2].Row.Spans[1], "MonoBehaviour", null);
            // Built-in components always read as the type name.
            AssertSpan(items[3].Row.Spans[1], "Transform", null);
        }

        [Test]
        public void GameObjectOverrideRendersInsideAComponentCard()
        {
            const string json =
                @"{
                ""unresolvedGuids"":[],
                ""roots"":[{""kind"":""gameObject"",""fileId"":""1"",""name"":""Plane"",""status"":""modified"",
                    ""overrides"":[{""group"":"""",""label"":""Name"",""status"":""modified"",""before"":""Old"",""after"":""New""}],
                    ""components"":[],""children"":[]}],
                ""loose"":[]
            }";
            var components = Build(json)[0].Children[0];
            AssertSpan(components.Row.Spans[1], "Components (1)", Palette.Muted);
            var card = components.Children[0];
            AssertSpan(card.Row.Spans[1], "Overrides", null);
            AssertSpan(card.Children[0].Row.Spans[1], "Name ", Palette.Muted);
            AssertSpan(card.Children[0].Row.Spans[2], "Old", Palette.Removed);
            AssertSpan(card.Children[0].Row.Spans[3], " → ", Palette.Muted);
            AssertSpan(card.Children[0].Row.Spans[4], "New", Palette.Added);
        }

        [Test]
        public void ComponentsGroupComesBeforeChildNodes()
        {
            // The components group separates Inspector data from the nested object hierarchy.
            const string json =
                @"{
                ""unresolvedGuids"":[],
                ""roots"":[{""kind"":""prefabInstance"",""fileId"":""1001"",""name"":""Cylinder"",""status"":""modified"",""sourceGuid"":null,
                    ""overrides"":[{""group"":""Transform"",""label"":""Position"",""status"":""modified"",""before"":""0"",""after"":""1""}],
                    ""components"":[{""kind"":""component"",""fileId"":""4"",""classId"":4,""typeName"":""Transform"",""scriptGuid"":null,""className"":null,""status"":""modified"",""fields"":[]}],
                    ""children"":[{""kind"":""gameObject"",""fileId"":""5"",""name"":""Cap"",""status"":""unchanged"",""components"":[],""children"":[]}]}],
                ""loose"":[]
            }";
            var children = Build(json)[0].Children;
            Assert.AreEqual(2, children.Count);
            AssertSpan(children[0].Row.Spans[1], "Components (2)", Palette.Muted);
            AssertSpan(children[0].Children[0].Row.Spans[1], "Transform", null);
            AssertSpan(children[0].Children[1].Row.Spans[1], "Transform", null);
            AssertSpan(children[1].Row.Spans[1], "Cap", null);
        }
    }
}
