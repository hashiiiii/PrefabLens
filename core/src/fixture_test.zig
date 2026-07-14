// Integration tests against real data from the verification PR (hashiiiii/unity-yaml-playground#1).
// Expected values are the approved reference mocks for the inspector diff model.
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

    // stripped Transform and PrefabInstance do not leak into loose.
    try testing.expectEqual(@as(usize, 0), res.loose.len);
    try testing.expectEqual(@as(usize, 1), res.roots.len);
    const plane = res.roots[0];
    try testing.expectEqualStrings("Plane", plane.name);

    // Added Cylinder Variant: all recorded placement shown, including defaults.
    const variant = childByName(plane, "Cylinder Variant").?;
    try testing.expectEqual(model.ObjectKind.prefab_instance, variant.kind);
    try testing.expectEqual(model.Status.added, variant.status);
    try testing.expectEqual(@as(usize, 2), variant.overrides.len);
    try testing.expectEqualStrings("Transform", variant.overrides[0].group);
    try testing.expectEqualStrings("Position", variant.overrides[0].label);
    try testing.expectEqualStrings("(2.03, 3.63, 1.11797)", variant.overrides[0].after.?.scalar);
    try testing.expectEqualStrings("Rotation", variant.overrides[1].label);
    try testing.expectEqualStrings("(0, 0, 0, 1)", variant.overrides[1].after.?.scalar);

    // Modified Cylinder: only the single Position.x override.
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
            // The added component enumerates its initial values in full (not empty).
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
    // Placement recorded in the file is all emitted, even at defaults.
    // The only omissions are EulerAnglesHint (hidden) and m_Name (absorbed into the node name).
    try testing.expectEqual(@as(usize, 3), inst.overrides.len);
    try testing.expectEqualStrings("Position", inst.overrides[0].label);
    try testing.expectEqualStrings("(0, 0, 0)", inst.overrides[0].after.?.scalar);
    try testing.expectEqualStrings("Rotation", inst.overrides[1].label);
    try testing.expectEqualStrings("(0, 0, 0, 1)", inst.overrides[1].after.?.scalar);
    try testing.expectEqualStrings("Scale.y", inst.overrides[2].label);
    try testing.expectEqualStrings("2", inst.overrides[2].after.?.scalar);
}

test "fixture: deleted Cylinder Variant.prefab mirrors the added enumeration" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Mirror of added (the previous test): the same 3 rows appear with before values and removed.
    const res = try root.diffBytes(arena, cylinder_variant_after, "");
    try testing.expectEqual(@as(usize, 1), res.roots.len);
    const inst = res.roots[0];
    try testing.expectEqual(model.ObjectKind.prefab_instance, inst.kind);
    try testing.expectEqualStrings("Cylinder Variant", inst.name);
    try testing.expectEqual(model.Status.removed, inst.status);
    try testing.expectEqual(@as(usize, 3), inst.overrides.len);
    try testing.expectEqualStrings("Position", inst.overrides[0].label);
    try testing.expectEqualStrings("(0, 0, 0)", inst.overrides[0].before.?.scalar);
    try testing.expectEqualStrings("Rotation", inst.overrides[1].label);
    try testing.expectEqualStrings("(0, 0, 0, 1)", inst.overrides[1].before.?.scalar);
    try testing.expectEqualStrings("Scale.y", inst.overrides[2].label);
    try testing.expectEqualStrings("2", inst.overrides[2].before.?.scalar);
}

test "fixture: variant merged with source shows Scale (1, 2, 1) and all components" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Supplying the source (equivalent to Cylinder.prefab) yields the same merged state as the Inspector.
    var assets: root.Assets = .empty;
    try assets.put(arena, "05ba59bdbdf954600a21005e3b7bf963", cylinder_after);
    const res = try root.diffBytesWithAssets(arena, "", cylinder_variant_after, &assets);
    try testing.expectEqual(@as(usize, 0), res.needed_sources.len);
    try testing.expectEqual(@as(usize, 1), res.roots.len);
    const inst = res.roots[0];
    try testing.expectEqualStrings("Cylinder Variant", inst.name);
    try testing.expectEqual(model.Status.added, inst.status);
    // Expansion succeeds: overrides vanish, all source components appear as added.
    try testing.expectEqual(@as(usize, 0), inst.overrides.len);
    var saw = [_]bool{false} ** 4; // Transform / MeshFilter / MeshRenderer / CapsuleCollider
    for (inst.components) |c| {
        try testing.expectEqual(model.Status.added, c.status);
        switch (c.class_id) {
            4 => {
                saw[0] = true;
                // Overrides applied: Scale.y=2 becomes (1, 2, 1), Position is (0, 0, 0).
                var saw_scale = false;
                var saw_pos = false;
                for (c.fields) |f| {
                    if (std.mem.eql(u8, f.path, "Scale")) {
                        saw_scale = true;
                        try testing.expectEqualStrings("(1, 2, 1)", f.after.?.scalar);
                    }
                    if (std.mem.eql(u8, f.path, "Position")) {
                        saw_pos = true;
                        try testing.expectEqualStrings("(0, 0, 0)", f.after.?.scalar);
                    }
                }
                try testing.expect(saw_scale and saw_pos);
            },
            33 => saw[1] = true,
            23 => saw[2] = true,
            136 => saw[3] = true,
            else => {},
        }
    }
    for (saw) |s| try testing.expect(s);
}

test "fixture: Plane variant instance merges nested sources with outer placement" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Two-level resolution: Plane -> Cylinder Variant.prefab -> Cylinder.prefab.
    // Plane's placement (2.03, 3.63, 1.11797) reaches the Transform via XOR push-down,
    // and Scale keeps the variant's override (1, 2, 1) = the same merge as the Inspector.
    var assets: root.Assets = .empty;
    try assets.put(arena, "b01772ea746dd4b869440c40c8b1f48e", cylinder_variant_after);
    try assets.put(arena, "05ba59bdbdf954600a21005e3b7bf963", cylinder_after);
    const res = try root.diffBytesWithAssets(arena, plane_before, plane_after, &assets);
    try testing.expectEqual(@as(usize, 0), res.needed_sources.len);
    const plane = res.roots[0];
    const variant = childByName(plane, "Cylinder Variant").?;
    try testing.expectEqual(model.Status.added, variant.status);
    // No duplicate node; all overrides are applied and none remain as rows.
    try testing.expectEqual(@as(usize, 0), variant.children.len);
    try testing.expectEqual(@as(usize, 0), variant.overrides.len);
    var saw_transform = false;
    for (variant.components) |c| {
        if (c.class_id != 4) continue;
        saw_transform = true;
        var saw_pos = false;
        var saw_scale = false;
        for (c.fields) |f| {
            if (std.mem.eql(u8, f.path, "Position")) {
                saw_pos = true;
                try testing.expectEqualStrings("(2.03, 3.63, 1.11797)", f.after.?.scalar);
            }
            if (std.mem.eql(u8, f.path, "Scale")) {
                saw_scale = true;
                try testing.expectEqualStrings("(1, 2, 1)", f.after.?.scalar);
            }
        }
        try testing.expect(saw_pos and saw_scale);
    }
    try testing.expect(saw_transform);
}

// ---- UnityYAML assets other than prefab/scene (.mat / .controller) ----
// core does not look at extensions, so these already diff. This is the regression point that pins that guarantee.

const material_before = @embedFile("testdata/material_before.mat");
const material_after = @embedFile("testdata/material_after.mat");
const animator_before = @embedFile("testdata/animator_before.controller");
const animator_after = @embedFile("testdata/animator_after.controller");

test "fixture: .mat diffs as a loose Material with nested property paths" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try root.diffBytes(arena, material_before, material_after);

    // No GameObject hierarchy, so roots is empty and the Material itself is a single loose entry.
    try testing.expectEqual(@as(usize, 0), res.roots.len);
    try testing.expectEqual(@as(usize, 1), res.loose.len);
    const mat = res.loose[0];
    try testing.expectEqual(@as(u32, 21), mat.class_id);
    try testing.expectEqualStrings("Material", mat.type_name);
    try testing.expectEqual(model.Status.modified, mat.status);

    // Two changes under m_SavedProperties appear with Inspector-style paths.
    try testing.expectEqual(@as(usize, 2), mat.fields.len);
    try testing.expectEqualStrings("Saved Properties.Floats[1]._Metallic", mat.fields[0].path);
    try testing.expectEqualStrings("0", mat.fields[0].before.?.scalar);
    try testing.expectEqualStrings("0.75", mat.fields[0].after.?.scalar);
    try testing.expectEqualStrings("Saved Properties.Colors[0]._Color.r", mat.fields[1].path);
    try testing.expectEqualStrings("1", mat.fields[1].before.?.scalar);
    try testing.expectEqualStrings("0.5", mat.fields[1].after.?.scalar);
}

test "fixture: .controller shows only the changed AnimatorState" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try root.diffBytes(arena, animator_before, animator_after);

    // Of the 3 documents (State / StateMachine / Controller), only State changed.
    try testing.expectEqual(@as(usize, 0), res.roots.len);
    try testing.expectEqual(@as(usize, 1), res.loose.len);
    const state = res.loose[0];
    // 1102 resolves to AnimatorState via the classid.zig table.
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
