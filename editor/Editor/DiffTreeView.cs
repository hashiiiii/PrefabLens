using System.Collections.Generic;
using UnityEditor;
using UnityEngine;
using UnityEngine.UIElements;

namespace PrefabLens
{
    public static class DiffTreeView
    {
        const float TreeRowHeight = 24;
        const float ListRowHeight = 26;

        public static float ListItemHeight => ListRowHeight;

        public static Row EntryRow(BulkEntry entry) =>
            DiffTree
                .Badge(BulkModel.AggregateStatus(entry.Diff))
                .WithIcon(AssetDatabase.GetCachedIcon(entry.Path))
                .Add(entry.Path);

        public static VisualElement MakeListRow() => MakeRow(6);

        public static VisualElement BuildHeader(BulkEntry entry)
        {
            var block = new VisualElement { style = { flexShrink = 0 } };
            var header = MakeRow(8);
            header.style.height = 34;
            header.style.paddingTop = 5;
            header.style.paddingBottom = 5;

            var icon = AssetDatabase.GetCachedIcon(entry.Path);
            if (icon != null)
                header.Add(Icon(icon));

            var path = new Label(entry.Path)
            {
                tooltip = entry.Path,
                style =
                {
                    flexGrow = 1,
                    marginLeft = 2,
                    unityFontStyleAndWeight = FontStyle.Bold,
                },
            };
            header.Add(path);
            AddBadge(header, BulkModel.AggregateStatus(entry.Diff));
            block.Add(header);
            block.Add(
                new VisualElement
                {
                    style =
                    {
                        height = 1,
                        flexShrink = 0,
                        backgroundColor = EditorGUIUtility.isProSkin
                            ? new Color(0.24f, 0.27f, 0.30f)
                            : new Color(0.85f, 0.87f, 0.89f),
                    },
                }
            );
            return block;
        }

        public static TreeView BuildTree(DiffModel model)
        {
            var id = 0;
            var items = new List<TreeViewItemData<Row>>();
            foreach (var item in DiffTree.Build(model))
                items.Add(ToViewItem(item, ref id));

            var tree = new TreeView
            {
                fixedItemHeight = TreeRowHeight,
                selectionType = SelectionType.None,
                style =
                {
                    flexGrow = 1,
                    marginTop = 4,
                    marginBottom = 4,
                    marginLeft = 4,
                    marginRight = 4,
                },
            };
            tree.SetRootItems(items);
            tree.makeItem = () => MakeRow(2);
            tree.bindItem = (element, index) => BindRow(element, tree.GetItemDataForIndex<Row>(index));
            tree.ExpandAll();
            return tree;
        }

        public static void BindRow(VisualElement element, Row row)
        {
            element.Clear();
            if (row.Icon != null)
                element.Add(Icon(row.Icon));

            for (var i = 1; i < row.Spans.Count; i++)
            {
                var span = row.Spans[i];
                var label = new Label(span.Text)
                {
                    style =
                    {
                        marginLeft = 0,
                        marginRight = 0,
                        paddingLeft = 0,
                        paddingRight = 0,
                    },
                };
                if (span.Tint is Color tint)
                    label.style.color = tint;
                if (row.Kind == RowKind.Group)
                    label.style.unityFontStyleAndWeight = FontStyle.Bold;
                element.Add(label);
            }

            element.Add(new VisualElement { style = { flexGrow = 1 } });
            if (row.Kind == RowKind.Summary)
                AddBadge(element, row.Status);
        }

        static VisualElement MakeRow(float horizontalPadding) =>
            new VisualElement
            {
                style =
                {
                    flexDirection = FlexDirection.Row,
                    alignItems = Align.Center,
                    paddingLeft = horizontalPadding,
                    paddingRight = horizontalPadding,
                },
            };

        static Image Icon(Texture texture) =>
            new Image
            {
                image = texture,
                style =
                {
                    width = 16,
                    height = 16,
                    marginRight = 4,
                    flexShrink = 0,
                },
            };

        static void AddBadge(VisualElement parent, DiffStatus status)
        {
            if (status == DiffStatus.Unchanged)
                return;
            var tint = StatusColor(status);
            parent.Add(
                new Label(StatusText(status))
                {
                    style =
                    {
                        width = 18,
                        height = 16,
                        marginLeft = 8,
                        marginRight = 2,
                        paddingLeft = 0,
                        paddingRight = 0,
                        borderTopLeftRadius = 3,
                        borderTopRightRadius = 3,
                        borderBottomLeftRadius = 3,
                        borderBottomRightRadius = 3,
                        unityTextAlign = TextAnchor.MiddleCenter,
                        unityFontStyleAndWeight = FontStyle.Bold,
                        color = tint,
                        backgroundColor = WithAlpha(tint, EditorGUIUtility.isProSkin ? 0.2f : 0.12f),
                    },
                }
            );
        }

        static string StatusText(DiffStatus status) =>
            status switch
            {
                DiffStatus.Added => "+",
                DiffStatus.Removed => "−",
                DiffStatus.Modified => "~",
                _ => "",
            };

        static Color StatusColor(DiffStatus status) =>
            status switch
            {
                DiffStatus.Added => Palette.Added,
                DiffStatus.Removed => Palette.Removed,
                _ => Palette.Modified,
            };

        static Color WithAlpha(Color color, float alpha) => new Color(color.r, color.g, color.b, alpha);

        static TreeViewItemData<Row> ToViewItem(DiffTree.Item item, ref int id)
        {
            var children = new List<TreeViewItemData<Row>>();
            foreach (var child in item.Children)
                children.Add(ToViewItem(child, ref id));
            return new TreeViewItemData<Row>(id++, item.Row, children);
        }
    }
}
