#if UNITY_EDITOR
using System.Collections;
using NUnit.Framework;
using UnityEditor;
using UnityEngine;
using UnityEngine.UIElements;
using UnityEngine.TestTools;

namespace PrefabLens.Tests
{
    public sealed class DiffTreeViewTests
    {
        sealed class TreeHostWindow : EditorWindow { }

        [TestCase(DiffStatus.Added, "+")]
        [TestCase(DiffStatus.Removed, "−")]
        [TestCase(DiffStatus.Modified, "~")]
        [TestCase(DiffStatus.Unchanged, null)]
        public void SummaryRowsShowTheNameAndOneStatusBadge(DiffStatus status, string badge)
        {
            // The visible row must keep its name when status moves between data and rendering.
            var model = new DiffModel();
            model.Roots.Add(new GameObjectDiff { Name = "Robot", Status = status });
            var element = new VisualElement();

            DiffTreeView.BindRow(element, DiffTree.Build(model)[0].Row);

            var labels = element.Query<Label>().ToList().ConvertAll(label => label.text);
            CollectionAssert.AreEqual(badge == null ? new[] { "Robot" } : new[] { "Robot", badge }, labels);
        }

        [Test]
        public void FieldRowsShowTheChangeWithoutASummaryBadge()
        {
            // A field already expresses its change through the before and after values.
            var model = new DiffModel();
            var component = new ComponentDiff { TypeName = "Transform", Status = DiffStatus.Modified };
            component.Fields.Add(
                new FieldDiff
                {
                    Path = "Position.x",
                    Status = DiffStatus.Modified,
                    Before = new Value { Scalar = "0" },
                    After = new Value { Scalar = "1" },
                }
            );
            model.Loose.Add(component);
            var element = new VisualElement();

            DiffTreeView.BindRow(element, DiffTree.Build(model)[0].Children[0].Children[0].Row);

            CollectionAssert.AreEqual(
                new[] { "Position.x ", "0", " → ", "1" },
                element.Query<Label>().ToList().ConvertAll(label => label.text)
            );
        }

        [Test]
        public void GroupLabelUsesRegularFontWeight()
        {
            var element = new VisualElement();
            var row = new Row(kind: RowKind.Group).Add("Components (1)", Palette.Muted);

            DiffTreeView.BindRow(element, row);

            Assert.AreEqual(FontStyle.Normal, element.Q<Label>().resolvedStyle.unityFontStyleAndWeight);
        }

        [UnityTest]
        public IEnumerator TreeToggleAlignsWithGroupLabel()
        {
            var model = new DiffModel();
            var root = new GameObjectDiff { Name = "Robot", Status = DiffStatus.Modified };
            root.Components.Add(new ComponentDiff { TypeName = "Transform", Status = DiffStatus.Modified });
            model.Roots.Add(root);

            // The panel resolves the geometry of the TreeView items.
            var window = ScriptableObject.CreateInstance<TreeHostWindow>();
            try
            {
                window.position = new Rect(0, 0, 600, 400);
                var tree = DiffTreeView.BuildTree(model);
                window.rootVisualElement.Add(tree);
                window.Show();

                yield return null;

                var label = tree.Query<Label>().ToList().Find(element => element.text == "Components (1)");
                Assert.NotNull(label);
                var item = label.parent;
                while (item != null && !item.ClassListContains(BaseTreeView.itemUssClassName))
                    item = item.parent;
                Assert.NotNull(item);
                var toggle = item.Q<Toggle>(className: BaseTreeView.itemToggleUssClassName);
                Assert.NotNull(toggle);
                var checkmark = toggle.Q<VisualElement>(className: Toggle.checkmarkUssClassName);
                Assert.NotNull(checkmark);
                Assert.AreEqual(
                    label.worldBound.center.y,
                    checkmark.worldBound.center.y,
                    0.5f,
                    $"item={item.worldBound}, label={label.worldBound}, toggle={toggle.worldBound}, "
                        + $"checkmark={checkmark.worldBound}, itemAlign={item.resolvedStyle.alignItems}, "
                        + $"toggleAlign={toggle.resolvedStyle.alignSelf}, checkmarkMarginTop={checkmark.resolvedStyle.marginTop}"
                );
            }
            finally
            {
                window.Close();
            }
        }
    }
}
#endif
