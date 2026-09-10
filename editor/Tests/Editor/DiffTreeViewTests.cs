using System.Collections.Generic;
using NUnit.Framework;
using UnityEngine.UIElements;

namespace PrefabLens.Tests
{
    public sealed class DiffTreeViewTests
    {
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

            CollectionAssert.AreEqual(badge == null ? new[] { "Robot" } : new[] { "Robot", badge }, Labels(element));
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

            CollectionAssert.AreEqual(new[] { "Position.x ", "0", " → ", "1" }, Labels(element));
        }

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
