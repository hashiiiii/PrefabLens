const std = @import("std");
const model = @import("model.zig");
const testing = std.testing;

fn findDoc(fd: FlatDiff, file_id: i64) ?DocDiff {
    for (fd.docs) |d| if (d.file_id == file_id) return d;
    return null;
}

test "diff: modified scalar field is detected old->new" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_Script: {fileID: 11500000, guid: abc, type: 3}
        \\  maxHp: 100
    ;
    const after =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_Script: {fileID: 11500000, guid: abc, type: 3}
        \\  maxHp: 150
    ;
    const fd = try compute(arena, before, after);
    const d = findDoc(fd, 5).?;
    try testing.expectEqual(model.Status.modified, d.status);
    try testing.expectEqualStrings("abc", d.script_guid.?);
    try testing.expectEqual(@as(usize, 1), d.fields.len);
    try testing.expectEqualStrings("Max Hp", d.fields[0].path);
    try testing.expectEqual(model.Status.modified, d.fields[0].status);
    try testing.expectEqualStrings("100", d.fields[0].before.?.scalar);
    try testing.expectEqualStrings("150", d.fields[0].after.?.scalar);
}

test "diff: unknown classID falls back to the document top-level key" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // 999999 is an ID absent from ClassIDReference. A document that cannot be
    // resolved via the table is named by its top-level key.
    const before =
        \\--- !u!999999 &7
        \\MyCustomThing:
        \\  value: 1
    ;
    const after =
        \\--- !u!999999 &7
        \\MyCustomThing:
        \\  value: 2
    ;
    const fd = try compute(arena, before, after);
    const d = findDoc(fd, 7).?;
    try testing.expectEqualStrings("MyCustomThing", d.type_name);
    try testing.expectEqual(model.Status.modified, d.status);
}

test "diff: added and removed documents" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: A
    ;
    const after =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: A
        \\--- !u!1 &2
        \\GameObject:
        \\  m_Name: B
    ;
    const fd = try compute(arena, before, after);
    try testing.expectEqual(model.Status.unchanged, findDoc(fd, 1).?.status);
    try testing.expectEqual(model.Status.added, findDoc(fd, 2).?.status);

    const fd2 = try compute(arena, after, before);
    const removed = findDoc(fd2, 2).?;
    try testing.expectEqual(model.Status.removed, removed.status);
    // Removed side enumerates fully too: the Name visible in the hierarchy remains with its before value.
    try testing.expectEqual(@as(usize, 1), removed.fields.len);
    try testing.expectEqualStrings("Name", removed.fields[0].path);
    try testing.expectEqualStrings("B", removed.fields[0].before.?.scalar);
}

test "diff: nested field path and added field" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!4 &4
        \\Transform:
        \\  m_LocalPosition: {x: 0, y: 0, z: 0}
    ;
    const after =
        \\--- !u!4 &4
        \\Transform:
        \\  m_LocalPosition: {x: 0, y: 5, z: 0}
        \\  m_LocalScale: {x: 1, y: 1, z: 1}
    ;
    const fd = try compute(arena, before, after);
    const d = findDoc(fd, 4).?;
    try testing.expectEqual(model.Status.modified, d.status);
    // Expect: the modified leaf (m_LocalPosition.y) plus the added m_LocalScale
    // collapsed as a vector into a single "Scale" row.
    var saw_y = false;
    var saw_added_scale = false;
    for (d.fields) |f| {
        if (std.mem.eql(u8, f.path, "Position.y")) {
            saw_y = true;
            try testing.expectEqual(model.Status.modified, f.status);
            try testing.expectEqualStrings("0", f.before.?.scalar);
            try testing.expectEqualStrings("5", f.after.?.scalar);
        }
        if (std.mem.eql(u8, f.path, "Scale")) {
            saw_added_scale = true;
            try testing.expectEqual(model.Status.added, f.status);
            try testing.expectEqualStrings("(1, 1, 1)", f.after.?.scalar);
        }
    }
    try testing.expect(saw_y and saw_added_scale);
}

test "diff: duplicate before fileIDs match the first occurrence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A malformed anchor makes the parser drop file_id to 0, so duplicates do
    // actually occur. The linear scan before the index was introduced matched the
    // "first" document, so that semantics must be preserved.
    const before =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  hp: 100
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  hp: 999
    ;
    const after =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  hp: 150
    ;
    const fd = try compute(arena, before, after);
    const d = findDoc(fd, 5).?;
    try testing.expectEqual(model.Status.modified, d.status);
    try testing.expectEqual(@as(usize, 1), d.fields.len);
    // First occurrence wins: before is 100, not the duplicate's 999.
    try testing.expectEqualStrings("100", d.fields[0].before.?.scalar);
    try testing.expectEqualStrings("150", d.fields[0].after.?.scalar);
}

test "diff: unresolved guids collected from external refs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_Script: {fileID: 1, guid: aaaa, type: 3}
    ;
    const after =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_Script: {fileID: 1, guid: bbbb, type: 3}
    ;
    const fd = try compute(arena, before, after);
    // Both aaaa and bbbb are referenced external guids, so both appear.
    var saw_a = false;
    var saw_b = false;
    for (fd.unresolved_guids) |g| {
        if (std.mem.eql(u8, g, "aaaa")) saw_a = true;
        if (std.mem.eql(u8, g, "bbbb")) saw_b = true;
    }
    try testing.expect(saw_a and saw_b);
}

test "diff: stripped documents are excluded from docs but kept in before/after" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: A
    ;
    const after =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: A
        \\--- !u!4 &42 stripped
        \\Transform:
        \\  m_PrefabInstance: {fileID: 99}
    ;
    const fd = try compute(arena, before, after);
    try testing.expect(findDoc(fd, 42) == null);
    // Retained in the after array for structural resolution.
    var found = false;
    for (fd.after) |d| if (d.file_id == 42) {
        found = true;
        try testing.expect(d.stripped);
    };
    try testing.expect(found);
}

test "diff: removed stripped documents are skipped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: A
        \\--- !u!4 &42 stripped
        \\Transform:
        \\  m_PrefabInstance: {fileID: 99}
    ;
    const after =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: A
    ;
    const fd = try compute(arena, before, after);
    // A stripped doc is a shadow of the instance's real object, so its removal is not a removed row.
    try testing.expect(findDoc(fd, 42) == null);
}

test "diff: hidden fields are dropped and paths humanized" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_LocalPosition: {x: 0, y: 0, z: 0}
    ;
    const after =
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 2}
        \\  m_LocalPosition: {x: 1, y: 0, z: 0}
    ;
    const fd = try compute(arena, before, after);
    const d = findDoc(fd, 4).?;
    // The m_GameObject change is hidden. m_LocalPosition.x becomes "Position.x".
    try testing.expectEqual(@as(usize, 1), d.fields.len);
    try testing.expectEqualStrings("Position.x", d.fields[0].path);
}

test "diff: hidden-only changes leave the document unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!4 &4
        \\Transform:
        \\  m_LocalEulerAnglesHint: {x: 0, y: 0, z: 0}
    ;
    const after =
        \\--- !u!4 &4
        \\Transform:
        \\  m_LocalEulerAnglesHint: {x: 0, y: 90, z: 0}
    ;
    const fd = try compute(arena, before, after);
    try testing.expectEqual(model.Status.unchanged, findDoc(fd, 4).?.status);
}

test "diff: editor class identifier tail is extracted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_EditorClassIdentifier: Assembly-CSharp::Cylinder1
        \\  hp: 1
    ;
    const src2 =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_EditorClassIdentifier: Assembly-CSharp::Cylinder1
        \\  hp: 2
    ;
    const fd = try compute(arena, src, src2);
    try testing.expectEqualStrings("Cylinder1", findDoc(fd, 5).?.class_name.?);
}

test "diff: editor class identifier without separator or with empty tail" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_EditorClassIdentifier: Cylinder1
        \\--- !u!114 &6
        \\MonoBehaviour:
        \\  m_EditorClassIdentifier: Assembly-CSharp::
    ;
    const fd = try compute(arena, src, src);
    // No separator uses the whole string as the class name; an empty tail means no class_name.
    try testing.expectEqualStrings("Cylinder1", findDoc(fd, 5).?.class_name.?);
    try testing.expect(findDoc(fd, 6).?.class_name == null);
}

test "diff: unresolved guids are deduplicated in first-reference order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const after =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_Script: {fileID: 1, guid: bbb, type: 3}
        \\--- !u!114 &6
        \\MonoBehaviour:
        \\  m_Script: {fileID: 1, guid: aaa, type: 3}
        \\--- !u!114 &7
        \\MonoBehaviour:
        \\  m_Script: {fileID: 1, guid: bbb, type: 3}
    ;
    const fd = try compute(arena, "", after);
    // Duplicate bbb appears once, in first-reference order (bbb, aaa).
    // The deterministic order of JSON unresolvedGuids/resolved depends on this.
    try testing.expectEqual(@as(usize, 2), fd.unresolved_guids.len);
    try testing.expectEqualStrings("bbb", fd.unresolved_guids[0]);
    try testing.expectEqualStrings("aaa", fd.unresolved_guids[1]);
}

test "diff: sortByGroup keeps same-group rows contiguous beyond known ranks" {
    // The renderer relies on "rows of the same group are contiguous" as a core invariant.
    // Pin directly that this holds even if groupOf returns a fourth group name in the future.
    var rows = [_]model.OverrideDiff{
        .{ .group = "Overrides", .label = "a", .status = .added, .before = null, .after = null },
        .{ .group = "Custom", .label = "b", .status = .added, .before = null, .after = null },
        .{ .group = "Overrides", .label = "c", .status = .added, .before = null, .after = null },
    };
    sortByGroup(&rows);
    try testing.expectEqualStrings("Custom", rows[0].group);
    try testing.expectEqualStrings("Overrides", rows[1].group);
    try testing.expectEqualStrings("Overrides", rows[2].group);
    // Relative order within a group is stable (a before c).
    try testing.expectEqualStrings("a", rows[1].label);
    try testing.expectEqualStrings("c", rows[2].label);
}

test "diff: added document enumerates fields with vector collapse" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = "";
    const after =
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_LocalPosition: {x: 4, y: 0, z: 0}
        \\  maxHp: 100
    ;
    const fd = try compute(arena, before, after);
    const d = findDoc(fd, 4).?;
    try testing.expectEqual(model.Status.added, d.status);
    // m_GameObject is hidden. Position is a single vector row, maxHp is Max Hp.
    try testing.expectEqual(@as(usize, 2), d.fields.len);
    try testing.expectEqualStrings("Position", d.fields[0].path);
    try testing.expectEqualStrings("(4, 0, 0)", d.fields[0].after.?.scalar);
    try testing.expectEqualStrings("Max Hp", d.fields[1].path);
}

test "diff: removed document enumerates fields with vector collapse" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_LocalPosition: {x: 4, y: 0, z: 0}
        \\  maxHp: 100
    ;
    const fd = try compute(arena, before, "");
    const d = findDoc(fd, 4).?;
    try testing.expectEqual(model.Status.removed, d.status);
    // Symmetric with the added side: m_GameObject hidden, Position a single vector row, values on before.
    try testing.expectEqual(@as(usize, 2), d.fields.len);
    try testing.expectEqualStrings("Position", d.fields[0].path);
    try testing.expectEqual(model.Status.removed, d.fields[0].status);
    try testing.expectEqualStrings("(4, 0, 0)", d.fields[0].before.?.scalar);
    try testing.expect(d.fields[0].after == null);
    try testing.expectEqualStrings("Max Hp", d.fields[1].path);
    try testing.expectEqualStrings("100", d.fields[1].before.?.scalar);
}

test "diff: prefab instance override keyed by target+propertyPath" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalPosition.x
        \\      value: 0.41646004
        \\      objectReference: {fileID: 0}
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: Cylinder
        \\      objectReference: {fileID: 0}
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    // Reorder while changing only x: reordering is not a diff.
    const after =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: Cylinder
        \\      objectReference: {fileID: 0}
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalPosition.x
        \\      value: 1
        \\      objectReference: {fileID: 0}
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    const fd = try compute(arena, before, after);
    const d = findDoc(fd, 1001).?;
    try testing.expectEqual(model.Status.modified, d.status);
    try testing.expectEqual(@as(usize, 0), d.fields.len);
    try testing.expectEqual(@as(usize, 1), d.overrides.len);
    try testing.expectEqualStrings("Transform", d.overrides[0].group);
    try testing.expectEqualStrings("Position.x", d.overrides[0].label);
    try testing.expectEqualStrings("0.41646004", d.overrides[0].before.?.scalar);
    try testing.expectEqualStrings("1", d.overrides[0].after.?.scalar);
}

test "diff: modified instance overrides are sorted group-contiguous, Transform first" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: rangeMin
        \\      value: 1
        \\      objectReference: {fileID: 0}
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalPosition.x
        \\      value: 0
        \\      objectReference: {fileID: 0}
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: maxHp
        \\      value: 100
        \\      objectReference: {fileID: 0}
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    // Raw YAML order is Overrides, Transform, Overrides: input with non-contiguous groups.
    const after =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: rangeMin
        \\      value: 2
        \\      objectReference: {fileID: 0}
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalPosition.x
        \\      value: 5
        \\      objectReference: {fileID: 0}
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: maxHp
        \\      value: 150
        \\      objectReference: {fileID: 0}
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    const fd = try compute(arena, before, after);
    const d = findDoc(fd, 1001).?;
    try testing.expectEqual(model.Status.modified, d.status);
    try testing.expectEqual(@as(usize, 3), d.overrides.len);
    try testing.expectEqualStrings("Transform", d.overrides[0].group);
    try testing.expectEqualStrings("Overrides", d.overrides[1].group);
    try testing.expectEqualStrings("Overrides", d.overrides[2].group);
    // Within Overrides, keep the original relative order (rangeMin before maxHp).
    try testing.expectEqualStrings("Range Min", d.overrides[1].label);
    try testing.expectEqualStrings("Max Hp", d.overrides[2].label);
}

test "diff: added prefab instance emits placement summary rows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const after =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalPosition.x
        \\      value: 2.03
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalPosition.y
        \\      value: 3.63
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalPosition.z
        \\      value: 1.11797
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalRotation.w
        \\      value: 1
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalRotation.x
        \\      value: 0
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalRotation.y
        \\      value: 0
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalRotation.z
        \\      value: 0
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalEulerAnglesHint.x
        \\      value: 0
        \\    - target: {fileID: 8, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: Cylinder Variant
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    const fd = try compute(arena, "", after);
    const d = findDoc(fd, 1001).?;
    try testing.expectEqual(model.Status.added, d.status);
    // Recorded placement is emitted as a single synthesized row even at default values (identity Rotation).
    // EulerAnglesHint (hidden in Inspector) and m_Name (absorbed into the node name) are not emitted.
    try testing.expectEqual(@as(usize, 2), d.overrides.len);
    try testing.expectEqualStrings("Transform", d.overrides[0].group);
    try testing.expectEqualStrings("Position", d.overrides[0].label);
    try testing.expectEqualStrings("(2.03, 3.63, 1.11797)", d.overrides[0].after.?.scalar);
    try testing.expectEqualStrings("Transform", d.overrides[1].group);
    try testing.expectEqualStrings("Rotation", d.overrides[1].label);
    try testing.expectEqualStrings("(0, 0, 0, 1)", d.overrides[1].after.?.scalar);
}

test "diff: added prefab instance keeps partial scale override" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const after =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalScale.y
        \\      value: 2
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    const fd = try compute(arena, "", after);
    const d = findDoc(fd, 1001).?;
    try testing.expectEqual(@as(usize, 1), d.overrides.len);
    try testing.expectEqualStrings("Scale.y", d.overrides[0].label);
    try testing.expectEqualStrings("2", d.overrides[0].after.?.scalar);
}

test "diff: removed prefab instance mirrors overrides to before" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalScale.y
        \\      value: 2
        \\    m_AddedComponents:
        \\    - targetCorrespondingSourceObject: {fileID: 7, guid: aaa, type: 3}
        \\      insertIndex: -1
        \\      addedObject: {fileID: 55}
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    const fd = try compute(arena, before, "");
    const d = findDoc(fd, 1001).?;
    try testing.expectEqual(model.Status.removed, d.status);
    // Mirror of added: values on the before side, structural summary removed with the before-side count.
    try testing.expectEqual(@as(usize, 2), d.overrides.len);
    try testing.expectEqualStrings("Scale.y", d.overrides[0].label);
    try testing.expectEqual(model.Status.removed, d.overrides[0].status);
    try testing.expectEqualStrings("2", d.overrides[0].before.?.scalar);
    try testing.expect(d.overrides[0].after == null);
    try testing.expectEqualStrings("Added Components (1)", d.overrides[1].label);
    try testing.expectEqual(model.Status.removed, d.overrides[1].status);
}

test "diff: non-empty added components produce a summary row" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications: []
        \\    m_AddedComponents: []
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    const after =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications: []
        \\    m_AddedComponents:
        \\    - targetCorrespondingSourceObject: {fileID: 7, guid: aaa, type: 3}
        \\      insertIndex: -1
        \\      addedObject: {fileID: 55}
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    const fd = try compute(arena, before, after);
    const d = findDoc(fd, 1001).?;
    try testing.expectEqual(@as(usize, 1), d.overrides.len);
    try testing.expectEqualStrings("Overrides", d.overrides[0].group);
    try testing.expectEqualStrings("Added Components (1)", d.overrides[0].label);
}

const parser = @import("parser.zig");
const classid = @import("classid.zig");
const inspector = @import("inspector.zig");
const Node = model.Node;
const Status = model.Status;
const FieldDiff = model.FieldDiff;

pub const DocDiff = struct {
    file_id: i64,
    class_id: u32,
    type_name: []const u8,
    script_guid: ?[]const u8 = null,
    class_name: ?[]const u8 = null,
    status: Status,
    fields: []FieldDiff,
    overrides: []model.OverrideDiff = &.{},
};

pub const FlatDiff = struct {
    docs: []DocDiff,
    unresolved_guids: [][]const u8,
    before: []model.Document,
    after: []model.Document,
};

fn buildIndex(arena: std.mem.Allocator, docs: []model.Document) !std.AutoHashMap(i64, *model.Document) {
    var idx = std.AutoHashMap(i64, *model.Document).init(arena);
    try idx.ensureTotalCapacity(@intCast(docs.len));
    for (docs) |*d| {
        // Duplicate fileIDs: first occurrence wins (happens with malformed anchors).
        // Same semantics as the linear scan before the index was introduced.
        const gop = idx.getOrPutAssumeCapacity(d.file_id);
        if (!gop.found_existing) gop.value_ptr.* = d;
    }
    return idx;
}

fn scriptGuid(doc: *const model.Document) ?[]const u8 {
    const s = model.findValue(doc.body.map, "m_Script") orelse return null;
    return switch (s.*) {
        .ref => |r| r.guid,
        else => null,
    };
}

// "Assembly-CSharp::Cylinder1" -> "Cylinder1" (after the last ':').
fn editorClassName(doc: *const model.Document) ?[]const u8 {
    const v = model.findValue(doc.body.map, "m_EditorClassIdentifier") orelse return null;
    const s = switch (v.*) {
        .scalar => |s| s,
        else => return null,
    };
    const tail = if (std.mem.lastIndexOfScalar(u8, s, ':')) |idx| s[idx + 1 ..] else s;
    return if (tail.len != 0) tail else null;
}

// Drop Inspector-hidden entries from the raw field diff and replace path with the display name.
fn presentFields(arena: std.mem.Allocator, raw: []FieldDiff) ![]FieldDiff {
    var kept: std.ArrayList(FieldDiff) = .empty;
    for (raw) |f| {
        if (inspector.isHidden(f.path)) continue;
        var out = f;
        out.path = try inspector.displayPath(arena, f.path);
        try kept.append(arena, out);
    }
    return kept.toOwnedSlice(arena);
}

fn resolvedTypeName(doc: *const model.Document) []const u8 {
    if (classid.typeName(doc.class_id)) |n| return n;
    // Unknown classID falls back to the document's own top-level key.
    return doc.type_name;
}

pub fn compute(arena: std.mem.Allocator, before_src: []const u8, after_src: []const u8) !FlatDiff {
    const before = try parser.parse(arena, before_src);
    const after = try parser.parse(arena, after_src);
    return computeParsed(arena, before, after);
}

// Diff an already-parsed document list (instantiate feeds in mutated docs).
pub fn computeParsed(arena: std.mem.Allocator, before: []model.Document, after: []model.Document) !FlatDiff {
    var docs: std.ArrayList(DocDiff) = .empty;
    // The array hash map preserves first-insertion order, so unresolvedGuids
    // serializes deterministically in reference order.
    var guids: std.StringArrayHashMapUnmanaged(void) = .empty;

    // fileID -> *Document index. Makes the subsequent union walk O(n) instead of
    // an O(n^2) linear scan (matters at scene scale of tens of thousands of docs).
    var before_idx = try buildIndex(arena, before);
    var after_idx = try buildIndex(arena, after);

    // Walk the union of file_ids: first `after` in order (preserving after's order),
    // then process documents that exist only in `before`.
    for (after) |*ad| {
        if (ad.stripped) continue;
        try collectGuids(arena, &guids, ad.body);
        const bd = before_idx.get(ad.file_id);
        if (bd) |b| {
            try collectGuids(arena, &guids, b.body);
            if (ad.class_id == 1001) {
                const overrides = try diffOverrides(arena, b, ad);
                try docs.append(arena, .{
                    .file_id = ad.file_id,
                    .class_id = ad.class_id,
                    .type_name = resolvedTypeName(ad),
                    .script_guid = scriptGuid(ad),
                    .status = if (overrides.len == 0) .unchanged else .modified,
                    .fields = &.{},
                    .overrides = overrides,
                });
            } else {
                var raw: std.ArrayList(FieldDiff) = .empty;
                try diffNode(arena, &raw, "", b.body, ad.body);
                const fields = try presentFields(arena, raw.items);
                try docs.append(arena, .{
                    .file_id = ad.file_id,
                    .class_id = ad.class_id,
                    .type_name = resolvedTypeName(ad),
                    .script_guid = scriptGuid(ad),
                    .class_name = editorClassName(ad),
                    .status = if (fields.len == 0) .unchanged else .modified,
                    .fields = fields,
                });
            }
        } else {
            if (ad.class_id == 1001) {
                try docs.append(arena, .{
                    .file_id = ad.file_id,
                    .class_id = ad.class_id,
                    .type_name = resolvedTypeName(ad),
                    .script_guid = scriptGuid(ad),
                    .status = .added,
                    .fields = &.{},
                    .overrides = try soleInstanceOverrides(arena, ad, .added),
                });
            } else {
                var raw: std.ArrayList(FieldDiff) = .empty;
                for (ad.body.map) |e| try flattenSubtree(arena, &raw, e.key, e.value, .added);
                try docs.append(arena, .{
                    .file_id = ad.file_id,
                    .class_id = ad.class_id,
                    .type_name = resolvedTypeName(ad),
                    .script_guid = scriptGuid(ad),
                    .class_name = editorClassName(ad),
                    .status = .added,
                    .fields = try presentFields(arena, raw.items),
                });
            }
        }
    }
    for (before) |*bd| {
        if (bd.stripped) continue;
        if (after_idx.contains(bd.file_id)) continue;
        try collectGuids(arena, &guids, bd.body);
        if (bd.class_id == 1001) {
            try docs.append(arena, .{
                .file_id = bd.file_id,
                .class_id = bd.class_id,
                .type_name = resolvedTypeName(bd),
                .script_guid = scriptGuid(bd),
                .class_name = editorClassName(bd),
                .status = .removed,
                .fields = &.{},
                .overrides = try soleInstanceOverrides(arena, bd, .removed),
            });
        } else {
            // Full enumeration symmetric with the added side (flattenSubtree ~ presentFields).
            var raw: std.ArrayList(FieldDiff) = .empty;
            for (bd.body.map) |e| try flattenSubtree(arena, &raw, e.key, e.value, .removed);
            try docs.append(arena, .{
                .file_id = bd.file_id,
                .class_id = bd.class_id,
                .type_name = resolvedTypeName(bd),
                .script_guid = scriptGuid(bd),
                .class_name = editorClassName(bd),
                .status = .removed,
                .fields = try presentFields(arena, raw.items),
            });
        }
    }

    return .{
        .docs = try docs.toOwnedSlice(arena),
        .unresolved_guids = guids.keys(),
        .before = before,
        .after = after,
    };
}

// Recursive field diff. `prefix` is the dot/index-separated path into `a`/`b`.
fn diffNode(
    arena: std.mem.Allocator,
    out: *std.ArrayList(FieldDiff),
    prefix: []const u8,
    a: *const Node,
    b: *const Node,
) anyerror!void {
    // Recurse if the same kind.
    if (a.* == .map and b.* == .map) {
        try diffMap(arena, out, prefix, a.map, b.map);
        return;
    }
    if (a.* == .seq and b.* == .seq) {
        try diffSeq(arena, out, prefix, a.seq, b.seq);
        return;
    }
    // Leaf (scalar/ref) or a change of kind.
    if (!Node.eql(a, b)) {
        try out.append(arena, .{ .path = prefix, .status = .modified, .before = a, .after = b });
    }
}

fn diffMap(
    arena: std.mem.Allocator,
    out: *std.ArrayList(FieldDiff),
    prefix: []const u8,
    a: []model.Entry,
    b: []model.Entry,
) anyerror!void {
    // Keys in a: modified/removed or recurse
    for (a) |ea| {
        const path = try joinKey(arena, prefix, ea.key);
        if (model.findValue(b, ea.key)) |bv| {
            try diffNode(arena, out, path, ea.value, bv);
        } else {
            try flattenSubtree(arena, out, path, ea.value, .removed);
        }
    }
    // Keys only in b: added
    for (b) |eb| {
        if (model.findValue(a, eb.key) == null) {
            const path = try joinKey(arena, prefix, eb.key);
            try flattenSubtree(arena, out, path, eb.value, .added);
        }
    }
}

fn diffSeq(
    arena: std.mem.Allocator,
    out: *std.ArrayList(FieldDiff),
    prefix: []const u8,
    a: []*Node,
    b: []*Node,
) anyerror!void {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n], 0..) |ea, eb, i| {
        const path = try std.fmt.allocPrint(arena, "{s}[{d}]", .{ prefix, i });
        try diffNode(arena, out, path, ea, eb);
    }
    for (a[n..], n..) |ea, i| {
        const path = try std.fmt.allocPrint(arena, "{s}[{d}]", .{ prefix, i });
        try flattenSubtree(arena, out, path, ea, .removed);
    }
    for (b[n..], n..) |eb, i| {
        const path = try std.fmt.allocPrint(arena, "{s}[{d}]", .{ prefix, i });
        try flattenSubtree(arena, out, path, eb, .added);
    }
}

fn joinKey(arena: std.mem.Allocator, prefix: []const u8, key: []const u8) ![]const u8 {
    if (prefix.len == 0) return key;
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ prefix, key });
}

fn isVectorMap(entries: []model.Entry) bool {
    if (entries.len < 2 or entries.len > 4) return false;
    for (entries) |e| {
        if (e.value.* != .scalar) return false;
        if (e.key.len != 1) return false;
        if (std.mem.indexOfScalar(u8, "xyzwrgba", e.key[0]) == null) return false;
    }
    return true;
}

// Synthesized scalar Node of the form "(a, b, c)" (for single-row display like "Position: (2, 3, 1)").
fn parenJoinNode(arena: std.mem.Allocator, vals: []const []const u8) !*Node {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '(');
    for (vals, 0..) |v, i| {
        if (i != 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, v);
    }
    try out.append(arena, ')');
    const n = try arena.create(Node);
    n.* = .{ .scalar = try out.toOwnedSlice(arena) };
    return n;
}

fn vectorNode(arena: std.mem.Allocator, entries: []model.Entry) !*Node {
    var vals: [4][]const u8 = undefined;
    for (entries, 0..) |e, i| vals[i] = e.value.scalar;
    return parenJoinNode(arena, vals[0..entries.len]);
}

fn appendLeaf(arena: std.mem.Allocator, out: *std.ArrayList(FieldDiff), path: []const u8, status: Status, node: *const Node) !void {
    try out.append(arena, switch (status) {
        .added => .{ .path = path, .status = .added, .before = null, .after = node },
        .removed => .{ .path = path, .status = .removed, .before = node, .after = null },
        else => unreachable,
    });
}

// Expand an added/removed subtree into leaves. A vector-like map collapses to one row.
fn flattenSubtree(
    arena: std.mem.Allocator,
    out: *std.ArrayList(FieldDiff),
    prefix: []const u8,
    node: *const Node,
    status: Status,
) anyerror!void {
    switch (node.*) {
        .map => |entries| {
            if (isVectorMap(entries)) {
                try appendLeaf(arena, out, prefix, status, try vectorNode(arena, entries));
                return;
            }
            for (entries) |e| try flattenSubtree(arena, out, try joinKey(arena, prefix, e.key), e.value, status);
        },
        .seq => |items| for (items, 0..) |it, i| {
            const path = try std.fmt.allocPrint(arena, "{s}[{d}]", .{ prefix, i });
            try flattenSubtree(arena, out, path, it, status);
        },
        else => try appendLeaf(arena, out, prefix, status, node),
    }
}

// ---- PrefabInstance override diff ----

const Mod = struct { target: i64, path: []const u8, value: ?*Node, obj_ref: ?*Node };

fn collectMods(arena: std.mem.Allocator, doc: *const model.Document) ![]Mod {
    var mods: std.ArrayList(Mod) = .empty;
    const m = model.findValue(doc.body.map, "m_Modification") orelse return mods.toOwnedSlice(arena);
    if (m.* != .map) return mods.toOwnedSlice(arena);
    const list = model.findValue(m.map, "m_Modifications") orelse return mods.toOwnedSlice(arena);
    if (list.* != .seq) return mods.toOwnedSlice(arena);
    for (list.seq) |item| {
        if (item.* != .map) continue;
        const pp = model.findValue(item.map, "propertyPath") orelse continue;
        if (pp.* != .scalar) continue;
        const target: i64 = blk: {
            const t = model.findValue(item.map, "target") orelse break :blk 0;
            break :blk switch (t.*) {
                .ref => |r| r.file_id,
                else => 0,
            };
        };
        try mods.append(arena, .{
            .target = target,
            .path = pp.scalar,
            .value = model.findValue(item.map, "value"),
            .obj_ref = objRefIfSet(model.findValue(item.map, "objectReference")),
        });
    }
    return mods.toOwnedSlice(arena);
}

fn objRefIfSet(n: ?*Node) ?*Node {
    const node = n orelse return null;
    return switch (node.*) {
        .ref => |r| if (r.file_id != 0 or r.guid != null) node else null,
        else => null,
    };
}

// objectReference if set, otherwise value.
fn modValue(m: Mod) ?*Node {
    return m.obj_ref orelse m.value;
}

// Mod identity key shared with instantiate (target fileID + propertyPath).
pub fn modKeyOf(arena: std.mem.Allocator, target: i64, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{d}:{s}", .{ target, path });
}

fn modKey(arena: std.mem.Allocator, m: Mod) ![]const u8 {
    return modKeyOf(arena, m.target, m.path);
}

fn nodeEqlOpt(a: ?*const Node, b: ?*const Node) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return Node.eql(a.?, b.?);
}

fn makeOverride(arena: std.mem.Allocator, property_path: []const u8, status: Status, before: ?*const Node, after: ?*const Node) !model.OverrideDiff {
    return .{
        .group = inspector.groupOf(property_path),
        .label = try inspector.displayPath(arena, property_path),
        .status = status,
        .before = before,
        .after = after,
    };
}

fn diffOverrides(arena: std.mem.Allocator, before_doc: ?*const model.Document, after_doc: *const model.Document) ![]model.OverrideDiff {
    var out: std.ArrayList(model.OverrideDiff) = .empty;
    const after_mods = try collectMods(arena, after_doc);
    const before_mods: []Mod = if (before_doc) |bd| try collectMods(arena, bd) else &.{};

    var before_map = std.StringHashMap(Mod).init(arena);
    for (before_mods) |m| try before_map.put(try modKey(arena, m), m);

    var seen = std.StringHashMap(void).init(arena);
    for (after_mods) |am| {
        const key = try modKey(arena, am);
        try seen.put(key, {});
        if (inspector.isHidden(am.path)) continue;
        const av: ?*const Node = modValue(am);
        if (before_map.get(key)) |bm| {
            const bv: ?*const Node = modValue(bm);
            if (nodeEqlOpt(bv, av)) continue;
            try out.append(arena, try makeOverride(arena, am.path, .modified, bv, av));
        } else {
            try out.append(arena, try makeOverride(arena, am.path, .added, null, av));
        }
    }
    // removed: deterministic in before-side order.
    for (before_mods) |bm| {
        if (seen.contains(try modKey(arena, bm))) continue;
        if (inspector.isHidden(bm.path)) continue;
        try out.append(arena, try makeOverride(arena, bm.path, .removed, modValue(bm), null));
    }
    try appendStructuralSummaries(arena, &out, before_doc, after_doc);
    sortByGroup(out.items);
    return out.toOwnedSlice(arena);
}

// Stable sort by group (Transform → GameObject → Overrides).
// The renderer emits headings assuming rows of the same group are contiguous, so
// rebundle the raw m_Modifications order by group.
fn groupRank(group: []const u8) u2 {
    if (std.mem.eql(u8, group, "Transform")) return 0;
    if (std.mem.eql(u8, group, "GameObject")) return 1;
    return 2;
}

fn sortByGroup(overrides: []model.OverrideDiff) void {
    const Ctx = struct {
        fn lessThan(_: void, a: model.OverrideDiff, b: model.OverrideDiff) bool {
            const ra = groupRank(a.group);
            const rb = groupRank(b.group);
            if (ra != rb) return ra < rb;
            // Equal rank (catch-all) tie-breaks by group name, keeping same-group
            // contiguity even as groupOf gains unknown group names.
            return std.mem.order(u8, a.group, b.group) == .lt;
        }
    };
    std.sort.block(model.OverrideDiff, overrides, {}, Ctx.lessThan);
}

const Placement = struct { prefix: []const u8, label: []const u8, comps: []const []const u8 };
const placements = [_]Placement{
    .{ .prefix = "m_LocalPosition", .label = "Position", .comps = &.{ "x", "y", "z" } },
    .{ .prefix = "m_LocalRotation", .label = "Rotation", .comps = &.{ "x", "y", "z", "w" } },
    .{ .prefix = "m_LocalScale", .label = "Scale", .comps = &.{ "x", "y", "z" } },
};

fn scalarOf(n: ?*Node) ?[]const u8 {
    const node = n orelse return null;
    return switch (node.*) {
        .scalar => |s| s,
        else => null,
    };
}

fn findMod(mods: []Mod, path: []const u8) ?Mod {
    for (mods) |m| if (std.mem.eql(u8, m.path, path)) return m;
    return null;
}

// Full override enumeration for an instance present on only one side (added/removed).
// Values go on after if added, on before if removed.
fn soleInstanceOverrides(arena: std.mem.Allocator, doc: *const model.Document, status: Status) ![]model.OverrideDiff {
    return soleOverridesFromMods(arena, doc, try dedupModsLastWins(arena, try collectMods(arena, doc)), status);
}

// Collapse duplicate (target, propertyPath) to one, last-wins (display position is the first occurrence). Real files
// have no duplicates, but instantiate's push-down appends the outer mod at the tail, so
// align the degraded view with the same "outer wins" semantics as application.
fn dedupModsLastWins(arena: std.mem.Allocator, mods: []Mod) ![]Mod {
    var map: std.StringArrayHashMapUnmanaged(Mod) = .empty;
    for (mods) |m| try map.put(arena, try modKey(arena, m), m);
    var out: std.ArrayList(Mod) = .empty;
    for (map.values()) |m| try out.append(arena, m);
    return out.toOwnedSlice(arena);
}

// Leftover rows of an expanded instance (for instantiate): drop mods applied to the
// synthesis, keep only the unapplied ones in the usual degraded view (don't drop silently).
pub fn soleInstanceOverridesSkipping(arena: std.mem.Allocator, doc: *const model.Document, status: Status, applied: *const std.StringHashMapUnmanaged(void)) ![]model.OverrideDiff {
    const all = try dedupModsLastWins(arena, try collectMods(arena, doc));
    var kept: std.ArrayList(Mod) = .empty;
    for (all) |m| {
        if (applied.contains(try modKey(arena, m))) continue;
        try kept.append(arena, m);
    }
    return soleOverridesFromMods(arena, doc, kept.items, status);
}

fn soleOverridesFromMods(arena: std.mem.Allocator, doc: *const model.Document, mods: []Mod, status: Status) ![]model.OverrideDiff {
    var out: std.ArrayList(model.OverrideDiff) = .empty;

    // Placement summary: a single synthesized row if all components are present.
    var consumed = [_]bool{false} ** placements.len;
    for (placements, 0..) |p, pi| {
        var vals: [4][]const u8 = undefined;
        var all = true;
        for (p.comps, 0..) |c, i| {
            const path = try std.fmt.allocPrint(arena, "{s}.{s}", .{ p.prefix, c });
            const m = findMod(mods, path) orelse {
                all = false;
                break;
            };
            const v = scalarOf(m.value) orelse {
                all = false;
                break;
            };
            vals[i] = v;
        }
        if (!all) continue;
        consumed[pi] = true;
        const n = try parenJoinNode(arena, vals[0..p.comps.len]);
        try out.append(arena, .{
            .group = "Transform",
            .label = p.label,
            .status = status,
            .before = if (status == .removed) n else null,
            .after = if (status == .added) n else null,
        });
    }

    for (mods) |m| {
        if (inspector.isHidden(m.path)) continue;
        if (std.mem.eql(u8, m.path, "m_Name")) continue; // absorbed into the node name
        const in_consumed = blk: {
            for (placements, 0..) |p, pi| {
                if (consumed[pi] and std.mem.startsWith(u8, m.path, p.prefix) and
                    m.path.len > p.prefix.len and m.path[p.prefix.len] == '.') break :blk true;
            }
            break :blk false;
        };
        if (in_consumed) continue;
        const v = modValue(m);
        try out.append(arena, try makeOverride(
            arena,
            m.path,
            status,
            if (status == .removed) v else null,
            if (status == .added) v else null,
        ));
    }
    if (status == .added) {
        try appendStructuralSummaries(arena, &out, null, doc);
    } else {
        try appendStructuralSummaries(arena, &out, doc, null);
    }
    sortByGroup(out.items);
    return out.toOwnedSlice(arena);
}

fn modificationSeqLen(doc: *const model.Document, key: []const u8) usize {
    const m = model.findValue(doc.body.map, "m_Modification") orelse return 0;
    if (m.* != .map) return 0;
    const v = model.findValue(m.map, key) orelse return 0;
    return switch (v.*) {
        .seq => |s| s.len,
        else => 0,
    };
}

// Full expansion of m_Added*/m_Removed* is out of scope. A single count-summary row prevents information from silently vanishing.
fn appendStructuralSummaries(arena: std.mem.Allocator, out: *std.ArrayList(model.OverrideDiff), before_doc: ?*const model.Document, after_doc: ?*const model.Document) !void {
    const keys = [_]struct { key: []const u8, label: []const u8 }{
        .{ .key = "m_AddedGameObjects", .label = "Added GameObjects" },
        .{ .key = "m_AddedComponents", .label = "Added Components" },
        .{ .key = "m_RemovedComponents", .label = "Removed Components" },
        .{ .key = "m_RemovedGameObjects", .label = "Removed GameObjects" },
    };
    for (keys) |e| {
        const alen = if (after_doc) |ad| modificationSeqLen(ad, e.key) else 0;
        const blen = if (before_doc) |bd| modificationSeqLen(bd, e.key) else 0;
        if (alen == blen) continue;
        // Count from the surviving side: if the whole instance is removed, emit the before count.
        const count = if (after_doc != null) alen else blen;
        try out.append(arena, .{
            .group = "Overrides",
            .label = try std.fmt.allocPrint(arena, "{s} ({d})", .{ e.label, count }),
            .status = if (alen > blen) .added else .removed,
            .before = null,
            .after = null,
        });
    }
}

// ---- guid collection ----

fn collectGuids(arena: std.mem.Allocator, set: *std.StringArrayHashMapUnmanaged(void), node: *const Node) anyerror!void {
    switch (node.*) {
        .ref => |r| if (r.guid) |g| try set.put(arena, g, {}),
        .map => |entries| for (entries) |e| try collectGuids(arena, set, e.value),
        .seq => |items| for (items) |it| try collectGuids(arena, set, it),
        .scalar => {},
    }
}
