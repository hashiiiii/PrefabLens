namespace PrefabLens
{
    /// <summary>
    /// Formats a diff.v2 field value consistently across all four views.
    /// Keep this aligned with formatValue in the extension's render.ts.
    /// The CLI's matching functions are writeValueText in render_tree.zig and writeValue in render_html.zig.
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
