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

    // 追加された Cylinder Variant: 記録済み placement を default 含め全表示。
    const variant = childByName(plane, "Cylinder Variant").?;
    try testing.expectEqual(model.ObjectKind.prefab_instance, variant.kind);
    try testing.expectEqual(model.Status.added, variant.status);
    try testing.expectEqual(@as(usize, 2), variant.overrides.len);
    try testing.expectEqualStrings("Transform", variant.overrides[0].group);
    try testing.expectEqualStrings("Position", variant.overrides[0].label);
    try testing.expectEqualStrings("(2.03, 3.63, 1.11797)", variant.overrides[0].after.?.scalar);
    try testing.expectEqualStrings("Rotation", variant.overrides[1].label);
    try testing.expectEqualStrings("(0, 0, 0, 1)", variant.overrides[1].after.?.scalar);

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

test "fixture: new Cylinder Variant.prefab shows all recorded placement values" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try root.diffBytes(arena, "", cylinder_variant_after);
    try testing.expectEqual(@as(usize, 1), res.roots.len);
    const inst = res.roots[0];
    try testing.expectEqual(model.ObjectKind.prefab_instance, inst.kind);
    try testing.expectEqualStrings("Cylinder Variant", inst.name);
    try testing.expectEqual(model.Status.added, inst.status);
    // ファイルに記録された placement は default でも全部出す。
    // 出ないのは EulerAnglesHint(非表示)と m_Name(ノード名に吸収)のみ。
    try testing.expectEqual(@as(usize, 3), inst.overrides.len);
    try testing.expectEqualStrings("Position", inst.overrides[0].label);
    try testing.expectEqualStrings("(0, 0, 0)", inst.overrides[0].after.?.scalar);
    try testing.expectEqualStrings("Rotation", inst.overrides[1].label);
    try testing.expectEqualStrings("(0, 0, 0, 1)", inst.overrides[1].after.?.scalar);
    try testing.expectEqualStrings("Scale.y", inst.overrides[2].label);
    try testing.expectEqualStrings("2", inst.overrides[2].after.?.scalar);
}

// ---- prefab/scene 以外の UnityYAML アセット(.mat / .controller)----
// core は拡張子を見ないので既に diff できる。ここはその保証を固定する回帰点。

const material_before = @embedFile("testdata/material_before.mat");
const material_after = @embedFile("testdata/material_after.mat");
const animator_before = @embedFile("testdata/animator_before.controller");
const animator_after = @embedFile("testdata/animator_after.controller");

test "fixture: .mat diffs as a loose Material with nested property paths" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try root.diffBytes(arena, material_before, material_after);

    // GameObject 階層を持たないので roots は空、Material 本体は loose に 1 件。
    try testing.expectEqual(@as(usize, 0), res.roots.len);
    try testing.expectEqual(@as(usize, 1), res.loose.len);
    const mat = res.loose[0];
    try testing.expectEqual(@as(u32, 21), mat.class_id);
    try testing.expectEqualStrings("Material", mat.type_name);
    try testing.expectEqual(model.Status.modified, mat.status);

    // m_SavedProperties 配下の変更 2 件が Inspector 風パスで出る。
    try testing.expectEqual(@as(usize, 2), mat.fields.len);
    try testing.expectEqualStrings("Saved Properties.Floats[1]._Metallic", mat.fields[0].path);
    try testing.expectEqualStrings("0", mat.fields[0].before.?.scalar);
    try testing.expectEqualStrings("0.75", mat.fields[0].after.?.scalar);
    try testing.expectEqualStrings("Saved Properties.Colors[0]._Color.r", mat.fields[1].path);
    try testing.expectEqualStrings("1", mat.fields[1].before.?.scalar);
    try testing.expectEqualStrings("0.5", mat.fields[1].after.?.scalar);
}

test "fixture: .controller shows only the changed AnimatorState via type_name fallback" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try root.diffBytes(arena, animator_before, animator_after);

    // 3 ドキュメント(State / StateMachine / Controller)のうち変更は State のみ。
    try testing.expectEqual(@as(usize, 0), res.roots.len);
    try testing.expectEqual(@as(usize, 1), res.loose.len);
    const state = res.loose[0];
    // classid.zig のテーブルに 1102 は無く、トップレベルキーへの fallback で命名される。
    try testing.expectEqual(@as(u32, 1102), state.class_id);
    try testing.expectEqualStrings("AnimatorState", state.type_name);
    try testing.expectEqual(model.Status.modified, state.status);

    try testing.expectEqual(@as(usize, 2), state.fields.len);
    try testing.expectEqualStrings("Name", state.fields[0].path);
    try testing.expectEqualStrings("Idle", state.fields[0].before.?.scalar);
    try testing.expectEqualStrings("Idle Fast", state.fields[0].after.?.scalar);
    try testing.expectEqualStrings("Speed", state.fields[1].path);
    try testing.expectEqualStrings("1", state.fields[1].before.?.scalar);
    try testing.expectEqualStrings("2", state.fields[1].after.?.scalar);
}
