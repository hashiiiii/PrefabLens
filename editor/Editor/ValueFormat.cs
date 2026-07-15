namespace PrefabLens
{
    /// <summary>
    /// Renders a diff.v2 field value for display. All four surfaces follow the
    /// same decision table — keep in sync with the extension's formatValue
    /// (render.ts) and the CLI's writeValueText (render_tree.zig) /
    /// writeValue (render_html.zig).
    /// </summary>
    public static class ValueFormat
    {
        public static string Format(Value v, DiffModel m)
        {
            if (v == null || v.IsNull)
                return "—";
            if (!v.IsRef)
                return v.Scalar ?? "";
            if (v.RefGuid != null)
            {
                if (m.Resolved.TryGetValue(v.RefGuid, out var p))
                    return p;
                var builtin = BuiltinRefs.Name(v.RefGuid, v.RefFileId);
                if (builtin != null)
                    return builtin + " (built-in)";
                return "guid:" + v.RefGuid;
            }
            // {fileID: 0} is Unity's null reference; the Inspector shows it as None.
            return v.RefFileId == "0" ? "None" : "#" + v.RefFileId;
        }
    }
}
