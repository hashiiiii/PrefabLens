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
    try testing.expectEqual(model.Status.removed, findDoc(fd2, 2).?.status);
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
    // 期待: modified な leaf(m_LocalPosition.y)+ added なサブツリー(m_LocalScale)。
    var saw_y = false;
    var saw_added_scale = false;
    for (d.fields) |f| {
        if (std.mem.eql(u8, f.path, "Position.y")) {
            saw_y = true;
            try testing.expectEqual(model.Status.modified, f.status);
            try testing.expectEqualStrings("0", f.before.?.scalar);
            try testing.expectEqualStrings("5", f.after.?.scalar);
        }
        if (std.mem.startsWith(u8, f.path, "Scale")) {
            saw_added_scale = true;
            try testing.expectEqual(model.Status.added, f.status);
        }
    }
    try testing.expect(saw_y and saw_added_scale);
}

test "diff: duplicate before fileIDs match the first occurrence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // 不正な anchor は parser が file_id を 0 に落とすため、重複は実際に
    // 起こる。index 導入前の線形探索は「最初の」ドキュメントに一致して
    // いたので、そのセマンティクスを維持しなければならない。
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
    // 最初の出現が勝つ: before は重複側の 999 ではなく 100。
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
    // aaaa と bbbb はどちらも参照された外部 guid なので両方現れる。
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
    // 構造解決用に after 配列には残る。
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
    // stripped はインスタンス側の実体の影なので、消えても removed 行にしない。
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
    // m_GameObject の変更は非表示。m_LocalPosition.x は "Position.x" に。
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

test "diff: sortByGroup keeps same-group rows contiguous beyond known ranks" {
    // レンダラは「同一グループの行は連続」を core の不変条件として前提にする。
    // groupOf が将来 4 つ目のグループ名を返しても壊れないことを直接固定する。
    var rows = [_]model.OverrideDiff{
        .{ .group = "Overrides", .label = "a", .status = .added, .before = null, .after = null },
        .{ .group = "Custom", .label = "b", .status = .added, .before = null, .after = null },
        .{ .group = "Overrides", .label = "c", .status = .added, .before = null, .after = null },
    };
    sortByGroup(&rows);
    try testing.expectEqualStrings("Custom", rows[0].group);
    try testing.expectEqualStrings("Overrides", rows[1].group);
    try testing.expectEqualStrings("Overrides", rows[2].group);
    // 同一グループ内の相対順は安定 (a が c より先)。
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
    // m_GameObject は非表示。Position はベクトル 1 行、maxHp は Max Hp。
    try testing.expectEqual(@as(usize, 2), d.fields.len);
    try testing.expectEqualStrings("Position", d.fields[0].path);
    try testing.expectEqualStrings("(4, 0, 0)", d.fields[0].after.?.scalar);
    try testing.expectEqualStrings("Max Hp", d.fields[1].path);
}

test "diff: added map field inside a modified document is flattened" {
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
    var saw_scale = false;
    for (d.fields) |f| {
        if (std.mem.eql(u8, f.path, "Scale")) {
            saw_scale = true;
            try testing.expectEqual(model.Status.added, f.status);
            try testing.expectEqualStrings("(1, 1, 1)", f.after.?.scalar);
        }
    }
    try testing.expect(saw_scale);
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
    // 順序を入れ替えつつ x のみ変更: 順序入れ替えは diff にならない。
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
    // 生の YAML 順は Overrides, Transform, Overrides: グループ非連続になる入力。
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
    // Overrides 内では元の相対順序(rangeMin が maxHp より先)を維持する。
    try testing.expectEqualStrings("Range Min", d.overrides[1].label);
    try testing.expectEqualStrings("Max Hp", d.overrides[2].label);
}

test "diff: added prefab instance collapses placement to summary" {
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
    // Position のみ: 合成 1 行。identity Rotation・EulerAnglesHint・m_Name は省略。
    try testing.expectEqual(@as(usize, 1), d.overrides.len);
    try testing.expectEqualStrings("Transform", d.overrides[0].group);
    try testing.expectEqualStrings("Position", d.overrides[0].label);
    try testing.expectEqualStrings("(2.03, 3.63, 1.11797)", d.overrides[0].after.?.scalar);
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
        // fileID 重複は最初の出現が勝つ(不正な anchor で発生する)。
        // index 導入前の線形探索と同じセマンティクス。
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

// "Assembly-CSharp::Cylinder1" -> "Cylinder1"(最後の ':' より後)。
fn editorClassName(doc: *const model.Document) ?[]const u8 {
    const v = model.findValue(doc.body.map, "m_EditorClassIdentifier") orelse return null;
    const s = switch (v.*) {
        .scalar => |s| s,
        else => return null,
    };
    const tail = if (std.mem.lastIndexOfScalar(u8, s, ':')) |idx| s[idx + 1 ..] else s;
    return if (tail.len != 0) tail else null;
}

// 生の field diff から Inspector 非表示を落とし、path を表示名に置換する。
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
    // 未知の classID はドキュメント自身のトップレベルキーに fallback。
    return doc.type_name;
}

pub fn compute(arena: std.mem.Allocator, before_src: []const u8, after_src: []const u8) !FlatDiff {
    const before = try parser.parse(arena, before_src);
    const after = try parser.parse(arena, after_src);

    var docs: std.ArrayList(DocDiff) = .empty;
    // array hash map は初回挿入順を保持するので、unresolvedGuids が
    // 参照順で決定的にシリアライズされる。
    var guids: std.StringArrayHashMapUnmanaged(void) = .empty;

    // fileID -> *Document の索引。以降の和集合の走査を O(n^2) の線形探索
    // ではなく O(n) にする(数万 doc のシーン規模で効く)。
    var before_idx = try buildIndex(arena, before);
    var after_idx = try buildIndex(arena, after);

    // file_id の和集合を歩く: まず `after` を順に(after の順序を保つ)、
    // 次に `before` にしかないドキュメントを処理する。
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
                    .overrides = try addedInstanceOverrides(arena, ad),
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
        try docs.append(arena, .{
            .file_id = bd.file_id,
            .class_id = bd.class_id,
            .type_name = resolvedTypeName(bd),
            .script_guid = scriptGuid(bd),
            .class_name = editorClassName(bd),
            .status = .removed,
            .fields = &.{},
        });
    }

    return .{
        .docs = try docs.toOwnedSlice(arena),
        .unresolved_guids = guids.keys(),
        .before = before,
        .after = after,
    };
}

// 再帰的な field diff。`prefix` は `a`/`b` へのドット/添字区切りパス。
fn diffNode(
    arena: std.mem.Allocator,
    out: *std.ArrayList(FieldDiff),
    prefix: []const u8,
    a: *const Node,
    b: *const Node,
) anyerror!void {
    // 同じ種別なら再帰。
    if (a.* == .map and b.* == .map) {
        try diffMap(arena, out, prefix, a.map, b.map);
        return;
    }
    if (a.* == .seq and b.* == .seq) {
        try diffSeq(arena, out, prefix, a.seq, b.seq);
        return;
    }
    // leaf(scalar/ref)または種別の変化。
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
    // a にあるキー: modified/removed または再帰
    for (a) |ea| {
        const path = try joinKey(arena, prefix, ea.key);
        if (model.findValue(b, ea.key)) |bv| {
            try diffNode(arena, out, path, ea.value, bv);
        } else {
            try flattenSubtree(arena, out, path, ea.value, .removed);
        }
    }
    // b にしかないキー: added
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

// "(a, b, c)" 形の合成スカラー Node("Position: (2, 3, 1)" 等の 1 行表示用)。
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

// added/removed サブツリーを leaf 単位に展開する。ベクトル風 map は 1 行に縮約。
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

// objectReference が設定されていればそれ、なければ value。
fn modValue(m: Mod) ?*Node {
    return m.obj_ref orelse m.value;
}

fn modKey(arena: std.mem.Allocator, m: Mod) ![]const u8 {
    return std.fmt.allocPrint(arena, "{d}:{s}", .{ m.target, m.path });
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
    // removed: before 側の順序で決定的に。
    for (before_mods) |bm| {
        if (seen.contains(try modKey(arena, bm))) continue;
        if (inspector.isHidden(bm.path)) continue;
        try out.append(arena, try makeOverride(arena, bm.path, .removed, modValue(bm), null));
    }
    try appendStructuralSummaries(arena, &out, before_doc, after_doc);
    sortByGroup(out.items);
    return out.toOwnedSlice(arena);
}

// group 単位で安定ソート(Transform → GameObject → Overrides)。
// レンダラは同一グループの行が連続することを前提に見出しを出すため、
// 生の m_Modifications 順を group ごとに束ね直す。
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
            // rank 同値 (catch-all) はグループ名で tie-break し、groupOf に
            // 未知のグループ名が増えても同一グループの連続性を保つ。
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

// 意図的な厳密一致: ほぼデフォルトに近い値も実在する override であり、
// 表示され続けるべき(epsilon 比較は検討のうえ見送り済み)。
fn numEql(s: []const u8, want: f64) bool {
    const v = std.fmt.parseFloat(f64, std.mem.trim(u8, s, " ")) catch return false;
    return v == want;
}

fn findMod(mods: []Mod, path: []const u8) ?Mod {
    for (mods) |m| if (std.mem.eql(u8, m.path, path)) return m;
    return null;
}

fn addedInstanceOverrides(arena: std.mem.Allocator, doc: *const model.Document) ![]model.OverrideDiff {
    const mods = try collectMods(arena, doc);
    var out: std.ArrayList(model.OverrideDiff) = .empty;

    // Placement サマリ: 全成分が揃っていれば合成 1 行(デフォルト値なら省略)。
    var consumed = [_]bool{false} ** placements.len;
    for (placements, 0..) |p, pi| {
        var vals: [4][]const u8 = undefined;
        var all = true;
        var is_default = true;
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
            // デフォルト: Position/Scale の各成分は 0/1、Rotation は (0,0,0,1)。
            const want: f64 = if (std.mem.eql(u8, p.label, "Scale"))
                1
            else if (std.mem.eql(u8, p.label, "Rotation") and std.mem.eql(u8, c, "w"))
                1
            else
                0;
            if (!numEql(v, want)) is_default = false;
        }
        if (!all) continue;
        consumed[pi] = true;
        if (is_default) continue;
        const n = try parenJoinNode(arena, vals[0..p.comps.len]);
        try out.append(arena, .{ .group = "Transform", .label = p.label, .status = .added, .before = null, .after = n });
    }

    for (mods) |m| {
        if (inspector.isHidden(m.path)) continue;
        if (std.mem.eql(u8, m.path, "m_Name")) continue; // ノード名に吸収
        const in_consumed = blk: {
            for (placements, 0..) |p, pi| {
                if (consumed[pi] and std.mem.startsWith(u8, m.path, p.prefix) and
                    m.path.len > p.prefix.len and m.path[p.prefix.len] == '.') break :blk true;
            }
            break :blk false;
        };
        if (in_consumed) continue;
        try out.append(arena, try makeOverride(arena, m.path, .added, null, modValue(m)));
    }
    try appendStructuralSummaries(arena, &out, null, doc);
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

// m_Added*/m_Removed* の完全展開はスコープ外。件数の要約 1 行で情報が黙って消えるのを防ぐ。
fn appendStructuralSummaries(arena: std.mem.Allocator, out: *std.ArrayList(model.OverrideDiff), before_doc: ?*const model.Document, after_doc: *const model.Document) !void {
    const keys = [_]struct { key: []const u8, label: []const u8 }{
        .{ .key = "m_AddedGameObjects", .label = "Added GameObjects" },
        .{ .key = "m_AddedComponents", .label = "Added Components" },
        .{ .key = "m_RemovedComponents", .label = "Removed Components" },
        .{ .key = "m_RemovedGameObjects", .label = "Removed GameObjects" },
    };
    for (keys) |e| {
        const alen = modificationSeqLen(after_doc, e.key);
        const blen = if (before_doc) |bd| modificationSeqLen(bd, e.key) else 0;
        if (alen == blen) continue;
        try out.append(arena, .{
            .group = "Overrides",
            .label = try std.fmt.allocPrint(arena, "{s} ({d})", .{ e.label, alen }),
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
