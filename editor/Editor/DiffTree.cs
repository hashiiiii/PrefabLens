using System.Collections.Generic;
using System.IO;
using UnityEditor;
using UnityEngine;

namespace PrefabLens
{
    /// Status colors for diff rows (same color tone as the Chrome renderer, per editor skin).
    public static class Palette
    {
        public static Color Added => Hex(EditorGUIUtility.isProSkin ? 0x3fb950 : 0x1a7f37);
        public static Color Removed => Hex(EditorGUIUtility.isProSkin ? 0xf85149 : 0xcf222e);
        public static Color Modified => Hex(EditorGUIUtility.isProSkin ? 0xd29922 : 0x9a6700);
        public static Color Muted => Hex(EditorGUIUtility.isProSkin ? 0x9198a1 : 0x59636e);

        static Color Hex(int rgb) =>
            new Color(((rgb >> 16) & 0xff) / 255f, ((rgb >> 8) & 0xff) / 255f, (rgb & 0xff) / 255f);
    }

    /// One run of text with an optional tint. Rows are span lists rather than rich text:
    /// don't let repository-derived strings be interpreted as markup (same rationale as
    /// the Chrome build's XSS test).
    public readonly struct Span
    {
        public readonly string Text;
        public readonly Color? Tint;

        public Span(string text, Color? tint = null)
        {
            Text = text;
            Tint = tint;
        }
    }

    /// One rendered line: spans plus an optional leading icon.
    public sealed class Row
    {
        public Texture Icon;
        public readonly List<Span> Spans = new();

        public Row Add(string text, Color? tint = null)
        {
            if (!string.IsNullOrEmpty(text))
                Spans.Add(new Span(text, tint));
            return this;
        }

        public Row WithIcon(Texture icon)
        {
            Icon = icon;
            return this;
        }
    }

    /// Maps a DiffModel to the row tree the window renders (same notation as the Chrome
    /// renderer). Pure with respect to UIElements — PrefabLensWindow owns the TreeView
    /// wiring — so `dotnet test` covers it via the DotNetTests~ stubs.
    public static class DiffTree
    {
        /// A row and its children; the window converts this to TreeViewItemData.
        public sealed class Item
        {
            public readonly Row Row;
            public readonly List<Item> Children = new();

            public Item(Row row) => Row = row;
        }

        public static List<Item> Build(DiffModel model)
        {
            var items = new List<Item>();
            foreach (var n in model.Roots)
                items.Add(NodeItem(n, model));
            foreach (var c in model.Loose)
                items.Add(ComponentItem(c, model));
            return items;
        }

        public static Row Badge(DiffStatus s) =>
            s switch
            {
                DiffStatus.Added => new Row().Add("+ ", Palette.Added),
                DiffStatus.Removed => new Row().Add("− ", Palette.Removed),
                DiffStatus.Modified => new Row().Add("~ ", Palette.Modified),
                _ => new Row().Add("  "),
            };

        static Item NodeItem(NodeDiff n, DiffModel m)
        {
            var pi = n as PrefabInstanceDiff;
            var row = Badge(n.Status).WithIcon(FindIcon(pi != null ? "Prefab Icon" : "GameObject Icon")).Add(n.Name);
            if (pi?.SourceGuid != null)
                row.Add(
                    " ‹Prefab: " + (m.Resolved.TryGetValue(pi.SourceGuid, out var src) ? src : pi.SourceGuid) + "›",
                    Palette.Muted
                );
            var item = new Item(row);
            if (pi != null)
                foreach (var ov in pi.Overrides)
                    item.Children.Add(new Item(OverrideRow(ov, m)));
            if (n.Components.Count > 0)
            {
                // Components fold as their own group one level below the object row (extension parity).
                var group = new Item(Badge(DiffStatus.Unchanged).Add("Components", Palette.Muted));
                foreach (var c in n.Components)
                    group.Children.Add(ComponentItem(c, m));
                item.Children.Add(group);
            }
            foreach (var ch in n.Children)
                item.Children.Add(NodeItem(ch, m));
            return item;
        }

        static Item ComponentItem(ComponentDiff c, DiffModel m)
        {
            var row = Badge(c.Status).WithIcon(ComponentIcon(c));
            if (!string.IsNullOrEmpty(c.ClassName))
                row.Add(c.ClassName).Add(" ‹Script›", Palette.Muted);
            else if (c.ScriptGuid != null && m.Resolved.TryGetValue(c.ScriptGuid, out var p))
                row.Add(Stem(p)).Add(" ‹Script›", Palette.Muted);
            else
                row.Add(c.TypeName);
            var item = new Item(row);
            foreach (var f in c.Fields)
                item.Children.Add(new Item(FieldRow(f.Path, f.Status, f.Before, f.After, m)));
            return item;
        }

        static Row OverrideRow(OverrideDiff ov, DiffModel m)
        {
            var label = ov.Group.Length > 0 && ov.Group != "Overrides" ? ov.Group + " / " + ov.Label : ov.Label;
            return FieldRow(label, ov.Status, ov.Before, ov.After, m);
        }

        static Row FieldRow(string label, DiffStatus status, Value before, Value after, DiffModel m)
        {
            var row = Badge(status).Add(label + " ", Palette.Muted);
            var b = ValueFormat.Format(before, m);
            var a = ValueFormat.Format(after, m);
            if (status == DiffStatus.Modified)
                row.Add(b, Palette.Removed).Add(" → ", Palette.Muted).Add(a, Palette.Added);
            else if (status == DiffStatus.Removed)
                row.Add(b, Palette.Removed);
            else
                row.Add(a, status == DiffStatus.Added ? Palette.Added : (Color?)null);
            return row;
        }

        /// Unity built-in icon lookup. Pro skin ships d_-prefixed variants, so probe those
        /// first; FindTexture returns null silently for unknown names.
        static Texture2D FindIcon(string name)
        {
            var dark = EditorGUIUtility.isProSkin ? EditorGUIUtility.FindTexture("d_" + name) : null;
            return dark != null ? dark : EditorGUIUtility.FindTexture(name);
        }

        static Texture2D ComponentIcon(ComponentDiff c)
        {
            // Built-in components have "<TypeName> Icon" textures; script components use the script icon.
            var builtin = c.ClassName == null && c.ScriptGuid == null ? FindIcon(c.TypeName + " Icon") : null;
            return builtin != null ? builtin : FindIcon("cs Script Icon");
        }

        static string Stem(string path)
        {
            var name = Path.GetFileNameWithoutExtension(path);
            return string.IsNullOrEmpty(name) ? path : name;
        }
    }
}
