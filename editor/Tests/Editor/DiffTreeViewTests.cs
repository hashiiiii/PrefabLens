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

        [Test]
        public void GroupLabelUsesRegularFontWeight()
        {
            var element = new VisualElement();
            var row = new Row(kind: RowKind.Group).Add("  ").Add("Components (1)", Palette.Muted);

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
