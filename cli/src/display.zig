//! Shared display-name resolution for render_tree / render_html.
const std = @import("std");
const core = @import("core");
const model = core.model;

pub fn objectName(o: model.ObjectDiff, resolved: ?*const core.json.Resolver) []const u8 {
    if (o.name.len != 0) return o.name;
    if (o.kind == .prefab_instance) {
        if (o.source_guid) |g| if (resolved) |r| if (r.get(g)) |p| {
            return std.fs.path.stem(p);
        };
        return "Prefab Instance";
    }
    return "(GameObject)";
}

/// Priority: guid-resolved script name > m_EditorClassIdentifier class name > type name.
pub fn componentName(c: model.ComponentDiff, resolved: ?*const core.json.Resolver) []const u8 {
    if (c.script_guid) |g| if (resolved) |r| if (r.get(g)) |p| {
        return std.fs.path.stem(p);
    };
    return c.class_name orelse c.type_name;
}
