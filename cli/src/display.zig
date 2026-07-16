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

/// How a reference value reads. Renderers switch on this and keep only their
/// own escaping and decoration (e.g. the "(built-in)" suffix).
pub const RefDisplay = union(enum) {
    /// External ref resolved through the .meta index; reads as the asset path.
    path: []const u8,
    /// Ref into Unity's built-in resource files; reads as the object name.
    builtin: []const u8,
    /// Unresolved external ref; reads as "guid:<guid>".
    guid: []const u8,
    /// fileID 0, Unity's null reference; the Inspector shows it as None.
    none,
    /// Any other local ref; reads as "#<fileID>".
    file_id: i64,
};

/// Resolution ladder for reference values: resolved asset path > built-in
/// object name > raw guid > None for fileID 0 > local fileID. Single Zig
/// source of truth for both CLI renderers; the extension's formatValue
/// mirrors the same ladder (guarded by its parity tests).
pub fn refDisplay(r: model.Ref, resolved: ?*const core.json.Resolver) RefDisplay {
    if (r.guid) |g| {
        if (resolved) |rr| if (rr.get(g)) |p| return .{ .path = p };
        if (builtin_refs.name(g, r.file_id)) |n| return .{ .builtin = n };
        return .{ .guid = g };
    }
    if (r.file_id == 0) return .none;
    return .{ .file_id = r.file_id };
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

/// Unresolved references worth advertising --project for. Built-ins are
/// excluded: they display by name, and no .meta on disk could resolve them.
pub fn unresolvedCount(res: model.DiffResult) usize {
    var n: usize = 0;
    for (res.unresolved_guids) |g| {
        if (!builtin_refs.isBuiltinGuid(g)) n += 1;
    }
    return n;
}

const builtin_refs = @import("builtin_refs.zig");

test "unresolvedCount ignores built-in guids" {
    var guids = [_][]const u8{ "abc123", builtin_refs.builtin_extra_guid };
    const res: model.DiffResult = .{
        .roots = &.{},
        .loose = &.{},
        .unresolved_guids = &guids,
        .needed_sources = &.{},
    };
    try std.testing.expectEqual(@as(usize, 1), unresolvedCount(res));
}

// refDisplay decision table, shared by render_tree's writeValueText and
// render_html's writeValue (and mirrored by the extension's formatValue).

test "refDisplay: resolved external ref reads as its asset path" {
    var resolver = core.json.Resolver.init(std.testing.allocator);
    defer resolver.deinit();
    try resolver.put("abc123", "Assets/Materials/Fixture.mat");
    const d = refDisplay(.{ .file_id = 2100000, .guid = "abc123", .type_id = 2 }, &resolver);
    try std.testing.expectEqualStrings("Assets/Materials/Fixture.mat", d.path);
}

test "refDisplay: built-in ref reads as its object name" {
    // No resolver: built-in names come from the checked-in table, not .meta files.
    const d = refDisplay(.{ .file_id = 10202, .guid = builtin_refs.default_resources_guid, .type_id = 0 }, null);
    try std.testing.expectEqualStrings("Cube", d.builtin);
}

test "refDisplay: built-in guid with unknown fileID falls back to the raw guid" {
    // fileID 424242 is not in the table (e.g. an object added by a future Unity).
    const d = refDisplay(.{ .file_id = 424242, .guid = builtin_refs.default_resources_guid, .type_id = 0 }, null);
    try std.testing.expectEqualStrings(builtin_refs.default_resources_guid, d.guid);
}

test "refDisplay: unresolved external ref keeps the raw guid" {
    var resolver = core.json.Resolver.init(std.testing.allocator);
    defer resolver.deinit();
    const d = refDisplay(.{ .file_id = 2100000, .guid = "abc123", .type_id = 2 }, &resolver);
    try std.testing.expectEqualStrings("abc123", d.guid);
}

test "refDisplay: fileID 0 is Unity's null reference" {
    const d = refDisplay(.{ .file_id = 0 }, null);
    try std.testing.expectEqual(RefDisplay.none, d);
}

test "refDisplay: other local refs read as their fileID" {
    const d = refDisplay(.{ .file_id = 42 }, null);
    try std.testing.expectEqual(@as(i64, 42), d.file_id);
}
