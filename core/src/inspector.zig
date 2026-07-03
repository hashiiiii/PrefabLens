const std = @import("std");
const testing = std.testing;

test "inspector: hidden fields are hidden by first path segment" {
    try testing.expect(isHidden("m_ObjectHideFlags"));
    try testing.expect(isHidden("m_GameObject"));
    try testing.expect(isHidden("m_Children[3]"));
    try testing.expect(isHidden("m_LocalEulerAnglesHint.x"));
    try testing.expect(isHidden("m_EditorClassIdentifier"));
    try testing.expect(isHidden("serializedVersion"));
    try testing.expect(!isHidden("m_LocalPosition.x"));
    try testing.expect(!isHidden("maxHp"));
}

test "inspector: displayPath maps table entries and nicifies the rest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("Position.x", try displayPath(arena, "m_LocalPosition.x"));
    try testing.expectEqualStrings("Rotation", try displayPath(arena, "m_LocalRotation"));
    try testing.expectEqualStrings("Scale.y", try displayPath(arena, "m_LocalScale.y"));
    try testing.expectEqualStrings("Name", try displayPath(arena, "m_Name"));
    try testing.expectEqualStrings("Max Hp", try displayPath(arena, "maxHp"));
    try testing.expectEqualStrings("Constrain Proportions Scale", try displayPath(arena, "m_ConstrainProportionsScale"));
    try testing.expectEqualStrings("Materials[0]", try displayPath(arena, "m_Materials[0]"));
}

test "inspector: groupOf infers pseudo component from propertyPath" {
    try testing.expectEqualStrings("Transform", groupOf("m_LocalPosition.x"));
    try testing.expectEqualStrings("Transform", groupOf("m_LocalScale.y"));
    try testing.expectEqualStrings("GameObject", groupOf("m_Name"));
    try testing.expectEqualStrings("GameObject", groupOf("m_IsActive"));
    try testing.expectEqualStrings("Overrides", groupOf("maxHp"));
}

/// Inspector に表示されないフィールド(パス先頭セグメントで判定)。
const hidden = [_][]const u8{
    "m_ObjectHideFlags",
    "m_CorrespondingSourceObject",
    "m_PrefabInstance",
    "m_PrefabAsset",
    "m_GameObject",
    "m_Father",
    "m_Children",
    "m_Component",
    "m_LocalEulerAnglesHint",
    "m_EditorHideFlags",
    "m_EditorClassIdentifier",
    "serializedVersion",
    "m_RootOrder",
};

/// 主要ビルトインの Inspector 表示名(先頭セグメント単位)。
const display = [_]struct { raw: []const u8, shown: []const u8 }{
    .{ .raw = "m_LocalPosition", .shown = "Position" },
    .{ .raw = "m_LocalRotation", .shown = "Rotation" },
    .{ .raw = "m_LocalScale", .shown = "Scale" },
    .{ .raw = "m_Name", .shown = "Name" },
    .{ .raw = "m_IsActive", .shown = "Active" },
    .{ .raw = "m_Enabled", .shown = "Enabled" },
    .{ .raw = "m_TagString", .shown = "Tag" },
    .{ .raw = "m_Layer", .shown = "Layer" },
    .{ .raw = "m_Script", .shown = "Script" },
};

fn firstSegment(path: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, path, '.') orelse path.len;
    const seg = path[0..dot];
    const br = std.mem.indexOfScalar(u8, seg, '[') orelse seg.len;
    return seg[0..br];
}

pub fn isHidden(path: []const u8) bool {
    const head = firstSegment(path);
    for (hidden) |h| if (std.mem.eql(u8, head, h)) return true;
    return false;
}

pub fn displayPath(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, path, '.');
    var first = true;
    while (it.next()) |seg| {
        if (!first) try out.append(arena, '.');
        first = false;
        try appendSegment(arena, &out, seg);
    }
    return out.toOwnedSlice(arena);
}

/// "[N]" 添字は名前部の後ろにそのまま残す。
fn appendSegment(arena: std.mem.Allocator, out: *std.ArrayList(u8), seg: []const u8) !void {
    const br = std.mem.indexOfScalar(u8, seg, '[') orelse seg.len;
    try appendNicified(arena, out, seg[0..br]);
    try out.appendSlice(arena, seg[br..]);
}

/// Unity の ObjectNames.NicifyVariableName 相当: 固定テーブル →
/// "m_" 除去 + 先頭大文字化 + 小文字/数字→大文字境界に空白挿入。
fn appendNicified(arena: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8) !void {
    for (display) |d| if (std.mem.eql(u8, name, d.raw)) {
        try out.appendSlice(arena, d.shown);
        return;
    };
    var s = name;
    if (std.mem.startsWith(u8, s, "m_")) s = s[2..];
    if (s.len == 0) {
        try out.appendSlice(arena, name);
        return;
    }
    // 単一小文字セグメント (x/y/z/w) は Inspector 同様そのまま。
    if (s.len == 1 and std.ascii.isLower(s[0])) {
        try out.appendSlice(arena, s);
        return;
    }
    try out.append(arena, std.ascii.toUpper(s[0]));
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (std.ascii.isUpper(c) and (std.ascii.isLower(s[i - 1]) or std.ascii.isDigit(s[i - 1]))) {
            try out.append(arena, ' ');
        }
        try out.append(arena, c);
    }
}

const transform_props = [_][]const u8{
    "m_LocalPosition", "m_LocalRotation", "m_LocalScale",
    "m_LocalEulerAnglesHint", "m_ConstrainProportionsScale",
};
const game_object_props = [_][]const u8{
    "m_Name", "m_IsActive", "m_TagString", "m_Layer", "m_StaticEditorFlags", "m_Icon",
};

pub fn groupOf(property_path: []const u8) []const u8 {
    const head = firstSegment(property_path);
    for (transform_props) |t| if (std.mem.eql(u8, head, t)) return "Transform";
    for (game_object_props) |g| if (std.mem.eql(u8, head, g)) return "GameObject";
    return "Overrides";
}
