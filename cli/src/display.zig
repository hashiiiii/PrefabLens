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

/// Heading status for the override group starting at `start`: that status if
/// uniform within the group, modified if mixed.
pub fn groupHeadingStatus(overrides: []const model.OverrideDiff, start: usize) model.Status {
    const first = overrides[start];
    for (overrides[start + 1 ..]) |ov| {
        if (!std.mem.eql(u8, ov.group, first.group)) break;
        if (ov.status != first.status) return .modified;
    }
    return first.status;
}

/// Number of consecutive-group cards the overrides collapse into.
pub fn overrideGroupCount(overrides: []const model.OverrideDiff) usize {
    var n: usize = 0;
    var current: []const u8 = "";
    for (overrides) |ov| {
        if (!std.mem.eql(u8, current, ov.group)) {
            current = ov.group;
            n += 1;
        }
    }
    return n;
}
