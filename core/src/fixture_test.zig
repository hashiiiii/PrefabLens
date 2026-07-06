// 検証 PR (hashiiiii/unity-yaml-playground#1) の実データに対する統合テスト。
// 期待値は spec の承認済みモック(docs/superpowers/specs/2026-07-03-semantic-diff-inspector-model-design.md)。
const std = @import("std");
const root = @import("root.zig");
const model = @import("model.zig");
const testing = std.testing;

const plane_before = @embedFile("testdata/plane_before.prefab");
const plane_after = @embedFile("testdata/plane_after.prefab");
const cylinder_before = @embedFile("testdata/cylinder_before.prefab");
const cylinder_after = @embedFile("testdata/cylinder_after.prefab");
const cylinder_variant_after = @embedFile("testdata/cylinder_variant_after.prefab");

fn childByName(o: model.ObjectDiff, name: []const u8) ?model.ObjectDiff {
    for (o.children) |c| if (std.mem.eql(u8, c.name, name)) return c;
    return null;
}

test "fixture: Plane.prefab shows both cylinder instances under Plane" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try root.diffBytes(arena, plane_before, plane_after);

    // stripped Transform や PrefabInstance が loose に漏れない。
    try testing.expectEqual(@as(usize, 0), res.loose.len);
    try testing.expectEqual(@as(usize, 1), res.roots.len);
    const plane = res.roots[0];
    try testing.expectEqualStrings("Plane", plane.name);

    // 追加された Cylinder Variant: 配置サマリのみ(Position 合成 1 行)。
    const variant = childByName(plane, "Cylinder Variant").?;
    try testing.expectEqual(model.ObjectKind.prefab_instance, variant.kind);
    try testing.expectEqual(model.Status.added, variant.status);
    try testing.expectEqual(@as(usize, 1), variant.overrides.len);
    try testing.expectEqualStrings("Transform", variant.overrides[0].group);
    try testing.expectEqualStrings("Position", variant.overrides[0].label);
    try testing.expectEqualStrings("(2.03, 3.63, 1.11797)", variant.overrides[0].after.?.scalar);

    // 変更された Cylinder: Position.x の 1 override のみ。
    const cylinder = childByName(plane, "Cylinder").?;
    try testing.expectEqual(model.ObjectKind.prefab_instance, cylinder.kind);
    try testing.expectEqual(model.Status.modified, cylinder.status);
    try testing.expectEqual(@as(usize, 1), cylinder.overrides.len);
    try testing.expectEqualStrings("Transform", cylinder.overrides[0].group);
    try testing.expectEqualStrings("Position.x", cylinder.overrides[0].label);
    try testing.expectEqualStrings("0.41646004", cylinder.overrides[0].before.?.scalar);
    try testing.expectEqualStrings("1", cylinder.overrides[0].after.?.scalar);
}

test "fixture: Cylinder.prefab shows added script and transform change" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try root.diffBytes(arena, cylinder_before, cylinder_after);
    try testing.expectEqual(@as(usize, 1), res.roots.len);
    const go = res.roots[0];
    try testing.expectEqualStrings("Cylinder", go.name);

    var saw_script = false;
    var saw_transform = false;
    for (go.components) |c| {
        if (c.class_id == 114) {
            saw_script = true;
            try testing.expectEqual(model.Status.added, c.status);
            try testing.expectEqualStrings("Cylinder1", c.class_name.?);
            // 追加コンポーネントは初期値を全列挙している(空ではない)。
            try testing.expect(c.fields.len != 0);
        }
        if (c.class_id == 4) {
            saw_transform = true;
            try testing.expectEqual(@as(usize, 1), c.fields.len);
            try testing.expectEqualStrings("Position.x", c.fields[0].path);
            try testing.expectEqualStrings("0.64596", c.fields[0].before.?.scalar);
            try testing.expectEqualStrings("1", c.fields[0].after.?.scalar);
        }
    }
    try testing.expect(saw_script and saw_transform);
}

test "fixture: new Cylinder Variant.prefab is a single added instance with Scale.y" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try root.diffBytes(arena, "", cylinder_variant_after);
    try testing.expectEqual(@as(usize, 1), res.roots.len);
    const inst = res.roots[0];
    try testing.expectEqual(model.ObjectKind.prefab_instance, inst.kind);
    try testing.expectEqualStrings("Cylinder Variant", inst.name);
    try testing.expectEqual(model.Status.added, inst.status);
    // Position (0,0,0)・identity Rotation・EulerAnglesHint・m_Name は省略され Scale.y だけ残る。
    try testing.expectEqual(@as(usize, 1), inst.overrides.len);
    try testing.expectEqualStrings("Scale.y", inst.overrides[0].label);
    try testing.expectEqualStrings("2", inst.overrides[0].after.?.scalar);
}
