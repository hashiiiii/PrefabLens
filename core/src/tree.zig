const std = @import("std");
const model = @import("model.zig");
const root = @import("root.zig");
const testing = std.testing;

const diffmod = @import("diff.zig");

const ComponentDiff = model.ComponentDiff;
const ObjectDiff = model.ObjectDiff;

/// Index helpers over the parsed documents (use the union of before+after).
const Index = struct {
    // file_id -> DocDiff (status + fields), for quick component construction.
    diff_by_id: std.AutoHashMap(i64, diffmod.DocDiff),
    // file_id -> *Document for the *structural* (after-preferred) version.
    doc_by_id: std.AutoHashMap(i64, *model.Document),

    fn structuralDoc(self: *Index, file_id: i64) ?*model.Document {
        return self.doc_by_id.get(file_id);
    }
};

fn refFileId(node: ?*model.Node) ?i64 {
    const n = node orelse return null;
    return switch (n.*) {
        .ref => |r| r.file_id,
        else => null,
    };
}

fn gameObjectIdOfComponent(doc: *model.Document) ?i64 {
    return refFileId(model.findValue(doc.body.map, "m_GameObject"));
}

fn transformOf(idx: *Index, go_id: i64) ?*model.Document {
    // The GameObject lists its components; find the one whose doc is a Transform/RectTransform.
    const go = idx.structuralDoc(go_id) orelse return null;
    const comps = model.findValue(go.body.map, "m_Component") orelse return null;
    if (comps.* != .seq) return null;
    for (comps.seq) |item| {
        const cref = if (item.* == .map) model.findValue(item.map, "component") else null;
        const cid = refFileId(cref) orelse continue;
        const cdoc = idx.structuralDoc(cid) orelse continue;
        if (cdoc.class_id == 4 or cdoc.class_id == 224) return cdoc;
    }
    return null;
}

fn isTransformClass(id: u32) bool {
    return id == 4 or id == 224;
}

fn sourcePrefabGuid(doc: *const model.Document) ?[]const u8 {
    const s = model.findValue(doc.body.map, "m_SourcePrefab") orelse return null;
    return switch (s.*) {
        .ref => |r| r.guid,
        else => null,
    };
}

/// m_Name override をインスタンス名として拾う(after 優先の structural doc から)。
fn instanceName(idx: *Index, pi_id: i64) []const u8 {
    const doc = idx.structuralDoc(pi_id) orelse return "";
    const m = model.findValue(doc.body.map, "m_Modification") orelse return "";
    if (m.* != .map) return "";
    const list = model.findValue(m.map, "m_Modifications") orelse return "";
    if (list.* != .seq) return "";
    for (list.seq) |item| {
        if (item.* != .map) continue;
        const pp = model.findValue(item.map, "propertyPath") orelse continue;
        if (pp.* != .scalar or !std.mem.eql(u8, pp.scalar, "m_Name")) continue;
        const v = model.findValue(item.map, "value") orelse continue;
        return switch (v.*) {
            .scalar => |s| s,
            else => "",
        };
    }
    return "";
}

/// 入れ子チェーン歩行の hop 上限。壊れたファイルで stripped PrefabInstance
/// 同士が循環参照しても停止する(実プロジェクトの入れ子深度は数段)。
const max_instance_hops = 8;

/// stripped な PrefabInstance の m_PrefabInstance チェーンを外側へ辿り、
/// 実体(非 stripped)の PrefabInstance の file_id を返す。
fn resolveInstanceChain(idx: *Index, start_id: i64) ?i64 {
    var id = start_id;
    var hops: usize = 0;
    while (hops < max_instance_hops) : (hops += 1) {
        const doc = idx.structuralDoc(id) orelse return null;
        if (doc.class_id != 1001) return null;
        if (!doc.stripped) return id;
        id = refFileId(model.findValue(doc.body.map, "m_PrefabInstance")) orelse return null;
    }
    return null;
}

/// Transform の file_id から親ノード(GameObject または PrefabInstance)の id。
/// stripped Transform は m_PrefabInstance を辿って所属インスタンスに橋渡し。
fn ownerNodeIdOfTransform(idx: *Index, tr_id: i64) ?i64 {
    if (tr_id == 0) return null;
    const tr = idx.structuralDoc(tr_id) orelse return null;
    if (!isTransformClass(tr.class_id)) return null;
    if (tr.stripped) {
        const pi_id = refFileId(model.findValue(tr.body.map, "m_PrefabInstance")) orelse return null;
        return resolveInstanceChain(idx, pi_id);
    }
    return gameObjectIdOfComponent(tr);
}

fn instanceParentId(idx: *Index, pi_id: i64) ?i64 {
    const doc = idx.structuralDoc(pi_id) orelse return null;
    const m = model.findValue(doc.body.map, "m_Modification") orelse return null;
    if (m.* != .map) return null;
    const tp = refFileId(model.findValue(m.map, "m_TransformParent")) orelse return null;
    return ownerNodeIdOfTransform(idx, tp);
}

fn parentGoId(idx: *Index, go_id: i64) ?i64 {
    const tr = transformOf(idx, go_id) orelse return null;
    const father_id = refFileId(model.findValue(tr.body.map, "m_Father")) orelse return null;
    return ownerNodeIdOfTransform(idx, father_id);
}

fn goName(idx: *Index, go_id: i64) []const u8 {
    const go = idx.structuralDoc(go_id) orelse return "";
    const n = model.findValue(go.body.map, "m_Name") orelse return "";
    return switch (n.*) {
        .scalar => |s| s,
        else => "",
    };
}

fn makeComponent(dd: diffmod.DocDiff) ComponentDiff {
    return .{
        .file_id = dd.file_id,
        .class_id = dd.class_id,
        .type_name = dd.type_name,
        .script_guid = dd.script_guid,
        .class_name = dd.class_name,
        .status = dd.status,
        .fields = dd.fields,
    };
}

pub fn build(arena: std.mem.Allocator, fd: diffmod.FlatDiff) !model.DiffResult {
    var idx = Index{
        .diff_by_id = std.AutoHashMap(i64, diffmod.DocDiff).init(arena),
        .doc_by_id = std.AutoHashMap(i64, *model.Document).init(arena),
    };
    for (fd.docs) |d| try idx.diff_by_id.put(d.file_id, d);
    // Structural docs: prefer after, fall back to before (for removed objects).
    for (fd.before) |*d| try idx.doc_by_id.put(d.file_id, d);
    for (fd.after) |*d| try idx.doc_by_id.put(d.file_id, d); // overwrites -> after wins

    // Partition documents: GameObjects, PrefabInstances, their components, and loose docs.
    var go_ids: std.ArrayList(i64) = .empty;
    var pi_ids: std.ArrayList(i64) = .empty;
    // components grouped by owning GameObject/PrefabInstance id
    var comps_by_owner = std.AutoHashMap(i64, std.ArrayList(ComponentDiff)).init(arena);
    var loose: std.ArrayList(ComponentDiff) = .empty;

    for (fd.docs) |d| {
        if (d.class_id == 1) {
            try go_ids.append(arena, d.file_id);
            continue;
        }
        if (d.class_id == 1001) {
            try pi_ids.append(arena, d.file_id);
            continue;
        }
        const owner = blk: {
            const doc = idx.structuralDoc(d.file_id) orelse break :blk null;
            const go_id = gameObjectIdOfComponent(doc) orelse break :blk null;
            // Only a confirmed GameObject document owns components; an
            // unresolvable ref ({fileID: 0} or dangling) would otherwise
            // bucket the component under a phantom id and drop it.
            const go_doc = idx.structuralDoc(go_id) orelse break :blk null;
            if (go_doc.class_id != 1) break :blk null;
            // stripped GameObject (nested prefab instance's root, placed in
            // the outer document) never becomes a node itself; bridge to its
            // owning PrefabInstance so the component isn't silently dropped.
            // The owning instance may itself be stripped (nested prefab), so
            // walk the chain out to the nearest materialized instance.
            const owner_id = if (go_doc.stripped) inner: {
                const pi_id = refFileId(model.findValue(go_doc.body.map, "m_PrefabInstance")) orelse break :blk null;
                break :inner resolveInstanceChain(&idx, pi_id) orelse break :blk null;
            } else go_id;
            // Stripped docs are excluded from fd.docs and never become nodes;
            // only an owner that materializes may claim the component.
            break :blk if (idx.diff_by_id.contains(owner_id)) owner_id else null;
        };
        if (owner) |owner_id| {
            const gop = try comps_by_owner.getOrPut(owner_id);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            // Collapse unchanged components with no fields.
            if (d.status != .unchanged) try gop.value_ptr.append(arena, makeComponent(d));
        } else {
            // No owning GameObject/PrefabInstance -> loose (e.g. ScriptableObject).
            if (d.status != .unchanged) try loose.append(arena, makeComponent(d));
        }
    }

    // Build ObjectDiff per GameObject (without children yet).
    var obj_by_id = std.AutoHashMap(i64, ObjectDiff).init(arena);
    for (go_ids.items) |go_id| {
        const gd = idx.diff_by_id.get(go_id).?;
        const comps: []ComponentDiff = if (comps_by_owner.get(go_id)) |list| list.items else &[_]ComponentDiff{};
        try obj_by_id.put(go_id, .{
            .file_id = go_id,
            .name = goName(&idx, go_id),
            .status = gd.status,
            .components = comps,
            .children = &[_]ObjectDiff{},
        });
    }
    for (pi_ids.items) |pi_id| {
        const dd = idx.diff_by_id.get(pi_id).?;
        const doc = idx.structuralDoc(pi_id);
        const comps: []ComponentDiff = if (comps_by_owner.get(pi_id)) |list| list.items else &[_]ComponentDiff{};
        try obj_by_id.put(pi_id, .{
            .kind = .prefab_instance,
            .file_id = pi_id,
            .name = instanceName(&idx, pi_id),
            .source_guid = if (doc) |dc| sourcePrefabGuid(dc) else null,
            .status = dd.status,
            .overrides = dd.overrides,
            .components = comps,
            .children = &[_]ObjectDiff{},
        });
    }

    // Assemble parent/child links.
    var children_of = std.AutoHashMap(i64, std.ArrayList(i64)).init(arena);
    var roots_ids: std.ArrayList(i64) = .empty;
    for (go_ids.items) |go_id| {
        if (parentGoId(&idx, go_id)) |pid| {
            if (obj_by_id.contains(pid)) {
                const e = try children_of.getOrPut(pid);
                if (!e.found_existing) e.value_ptr.* = .empty;
                try e.value_ptr.append(arena, go_id);
                continue;
            }
        }
        try roots_ids.append(arena, go_id);
    }
    for (pi_ids.items) |pi_id| {
        if (instanceParentId(&idx, pi_id)) |pid| {
            if (obj_by_id.contains(pid)) {
                const e = try children_of.getOrPut(pid);
                if (!e.found_existing) e.value_ptr.* = .empty;
                try e.value_ptr.append(arena, pi_id);
                continue;
            }
        }
        try roots_ids.append(arena, pi_id);
    }

    // Recursively materialize, pruning unchanged subtrees with no changed descendants.
    var roots: std.ArrayList(ObjectDiff) = .empty;
    for (roots_ids.items) |rid| {
        if (try materialize(arena, &obj_by_id, &children_of, rid)) |node| {
            try roots.append(arena, node);
        }
    }

    return .{
        .roots = try roots.toOwnedSlice(arena),
        .loose = try loose.toOwnedSlice(arena),
        .unresolved_guids = fd.unresolved_guids,
    };
}

/// Build the ObjectDiff for `go_id` with its kept children. Returns null if the
/// node and its entire subtree are unchanged with no kept components.
fn materialize(
    arena: std.mem.Allocator,
    obj_by_id: *std.AutoHashMap(i64, ObjectDiff),
    children_of: *std.AutoHashMap(i64, std.ArrayList(i64)),
    go_id: i64,
) anyerror!?ObjectDiff {
    var self = obj_by_id.get(go_id).?;
    var kept_children: std.ArrayList(ObjectDiff) = .empty;
    if (children_of.get(go_id)) |kids| {
        for (kids.items) |cid| {
            if (try materialize(arena, obj_by_id, children_of, cid)) |child| {
                try kept_children.append(arena, child);
            }
        }
    }
    self.children = try kept_children.toOwnedSlice(arena);
    const has_change = self.status != .unchanged or self.components.len != 0 or
        self.children.len != 0 or self.overrides.len != 0;
    if (!has_change) return null;
    return self;
}

fn findRoot(res: model.DiffResult, file_id: i64) ?model.ObjectDiff {
    for (res.roots) |o| if (o.file_id == file_id) return o;
    return null;
}

test "tree: GameObject groups its components; modified component bubbles up" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: Player
        \\  m_Component:
        \\  - component: {fileID: 4}
        \\  - component: {fileID: 5}
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_Father: {fileID: 0}
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_GameObject: {fileID: 1}
        \\  m_Script: {fileID: 0, guid: abc, type: 3}
        \\  hp: 100
    ;
    const after =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: Player
        \\  m_Component:
        \\  - component: {fileID: 4}
        \\  - component: {fileID: 5}
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_Father: {fileID: 0}
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_GameObject: {fileID: 1}
        \\  m_Script: {fileID: 0, guid: abc, type: 3}
        \\  hp: 250
    ;
    const res = try root.diffBytes(arena, before, after);
    const go = findRoot(res, 1).?;
    try testing.expectEqualStrings("Player", go.name);
    // Player itself is structurally unchanged but kept because a child component changed.
    try testing.expectEqual(model.Status.unchanged, go.status);
    // Components: the Transform (unchanged, no fields) is collapsed; MonoBehaviour kept.
    var saw_modified_mb = false;
    for (go.components) |c| {
        if (c.file_id == 5) {
            saw_modified_mb = true;
            try testing.expectEqual(model.Status.modified, c.status);
            try testing.expectEqualStrings("MonoBehaviour", c.type_name);
        }
    }
    try testing.expect(saw_modified_mb);
}

test "tree: child GameObject nests under parent via Transform m_Father" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src_before =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: Parent
        \\  m_Component:
        \\  - component: {fileID: 4}
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_Father: {fileID: 0}
        \\--- !u!1 &2
        \\GameObject:
        \\  m_Name: Child
        \\  m_Component:
        \\  - component: {fileID: 5}
        \\--- !u!4 &5
        \\Transform:
        \\  m_GameObject: {fileID: 2}
        \\  m_Father: {fileID: 4}
    ;
    // after: child renamed
    const src_after =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: Parent
        \\  m_Component:
        \\  - component: {fileID: 4}
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_Father: {fileID: 0}
        \\--- !u!1 &2
        \\GameObject:
        \\  m_Name: ChildRenamed
        \\  m_Component:
        \\  - component: {fileID: 5}
        \\--- !u!4 &5
        \\Transform:
        \\  m_GameObject: {fileID: 2}
        \\  m_Father: {fileID: 4}
    ;
    const res = try root.diffBytes(arena, src_before, src_after);
    const parent = findRoot(res, 1).?;
    try testing.expectEqual(@as(usize, 1), parent.children.len);
    try testing.expectEqual(@as(i64, 2), parent.children[0].file_id);
}

test "tree: ScriptableObject .asset becomes a loose component" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!114 &11400000
        \\MonoBehaviour:
        \\  m_Script: {fileID: 0, guid: def, type: 3}
        \\  volume: 0.5
    ;
    const after =
        \\--- !u!114 &11400000
        \\MonoBehaviour:
        \\  m_Script: {fileID: 0, guid: def, type: 3}
        \\  volume: 0.8
    ;
    const res = try root.diffBytes(arena, before, after);
    try testing.expectEqual(@as(usize, 0), res.roots.len);
    try testing.expectEqual(@as(usize, 1), res.loose.len);
    try testing.expectEqual(model.Status.modified, res.loose[0].status);
}

test "tree: component with unresolvable m_GameObject ref becomes loose, not dropped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!114 &7
        \\MonoBehaviour:
        \\  m_GameObject: {fileID: 0}
        \\  m_Script: {fileID: 0, guid: ghi, type: 3}
        \\  speed: 1
    ;
    const after =
        \\--- !u!114 &7
        \\MonoBehaviour:
        \\  m_GameObject: {fileID: 0}
        \\  m_Script: {fileID: 0, guid: ghi, type: 3}
        \\  speed: 2
    ;
    const res = try root.diffBytes(arena, before, after);
    try testing.expectEqual(@as(usize, 0), res.roots.len);
    try testing.expectEqual(@as(usize, 1), res.loose.len);
    try testing.expectEqual(@as(i64, 7), res.loose[0].file_id);
    try testing.expectEqual(model.Status.modified, res.loose[0].status);
}

test "tree: prefab instance nests under parent GameObject with name from m_Name override" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: Plane
        \\  m_Component:
        \\  - component: {fileID: 4}
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_Father: {fileID: 0}
    ;
    const after =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: Plane
        \\  m_Component:
        \\  - component: {fileID: 4}
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_Father: {fileID: 0}
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_TransformParent: {fileID: 4}
        \\    m_Modifications:
        \\    - target: {fileID: 8, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: Cylinder Variant
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalScale.y
        \\      value: 2
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
        \\--- !u!4 &42 stripped
        \\Transform:
        \\  m_CorrespondingSourceObject: {fileID: 7, guid: aaa, type: 3}
        \\  m_PrefabInstance: {fileID: 1001}
        \\  m_PrefabAsset: {fileID: 0}
    ;
    const res = try root.diffBytes(arena, before, after);
    try testing.expectEqual(@as(usize, 1), res.roots.len);
    try testing.expectEqual(@as(usize, 0), res.loose.len);
    const plane = res.roots[0];
    try testing.expectEqual(@as(usize, 1), plane.children.len);
    const inst = plane.children[0];
    try testing.expectEqual(model.ObjectKind.prefab_instance, inst.kind);
    try testing.expectEqualStrings("Cylinder Variant", inst.name);
    try testing.expectEqualStrings("aaa", inst.source_guid.?);
    try testing.expectEqual(model.Status.added, inst.status);
    try testing.expect(inst.overrides.len != 0);
    // stripped Transform はどこにも現れない。
    try testing.expectEqual(@as(usize, 0), inst.components.len);
}

test "tree: component class name passes through to the tree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: Player
        \\  m_Component:
        \\  - component: {fileID: 5}
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_GameObject: {fileID: 1}
        \\  m_EditorClassIdentifier: Assembly-CSharp::Cylinder1
        \\  hp: 1
    ;
    const after =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: Player
        \\  m_Component:
        \\  - component: {fileID: 5}
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_GameObject: {fileID: 1}
        \\  m_EditorClassIdentifier: Assembly-CSharp::Cylinder1
        \\  hp: 2
    ;
    const res = try root.diffBytes(arena, before, after);
    try testing.expectEqual(@as(usize, 1), res.roots.len);
    try testing.expectEqual(@as(usize, 1), res.roots[0].components.len);
    try testing.expectEqualStrings("Cylinder1", res.roots[0].components[0].class_name.?);
}

test "tree: prefab instance with root transform parent becomes a root" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const after =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_TransformParent: {fileID: 0}
        \\    m_Modifications:
        \\    - target: {fileID: 8, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: Cylinder Variant
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    const res = try root.diffBytes(arena, "", after);
    try testing.expectEqual(@as(usize, 1), res.roots.len);
    try testing.expectEqual(model.ObjectKind.prefab_instance, res.roots[0].kind);
    try testing.expectEqualStrings("Cylinder Variant", res.roots[0].name);
}

test "tree: nested prefab instance bridges through stripped transform to parent instance" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const after =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_TransformParent: {fileID: 0}
        \\    m_Modifications:
        \\    - target: {fileID: 8, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: Outer
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
        \\--- !u!4 &42 stripped
        \\Transform:
        \\  m_PrefabInstance: {fileID: 1001}
        \\--- !u!1001 &2002
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_TransformParent: {fileID: 42}
        \\    m_Modifications:
        \\    - target: {fileID: 9, guid: bbb, type: 3}
        \\      propertyPath: m_Name
        \\      value: Inner
        \\  m_SourcePrefab: {fileID: 100100000, guid: bbb, type: 3}
    ;
    const res = try root.diffBytes(arena, "", after);
    try testing.expectEqual(@as(usize, 1), res.roots.len);
    try testing.expectEqualStrings("Outer", res.roots[0].name);
    try testing.expectEqual(@as(usize, 1), res.roots[0].children.len);
    try testing.expectEqualStrings("Inner", res.roots[0].children[0].name);
}

test "tree: component whose m_GameObject resolves to a non-GameObject document becomes loose, not dropped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // fileID 999 exists but is a MonoBehaviour, not a GameObject: a dangling
    // reference in spirit (no GameObject there), distinct from fileID: 0.
    const before =
        \\--- !u!114 &7
        \\MonoBehaviour:
        \\  m_GameObject: {fileID: 999}
        \\  speed: 1
        \\--- !u!114 &999
        \\MonoBehaviour:
        \\  hp: 1
    ;
    const after =
        \\--- !u!114 &7
        \\MonoBehaviour:
        \\  m_GameObject: {fileID: 999}
        \\  speed: 2
        \\--- !u!114 &999
        \\MonoBehaviour:
        \\  hp: 1
    ;
    const res = try root.diffBytes(arena, before, after);
    try testing.expectEqual(@as(usize, 0), res.roots.len);
    // Component 999 is unchanged (collapsed); component 7 is loose, not dropped.
    try testing.expectEqual(@as(usize, 1), res.loose.len);
    try testing.expectEqual(@as(i64, 7), res.loose[0].file_id);
    try testing.expectEqual(model.Status.modified, res.loose[0].status);
}

test "tree: component of a stripped GameObject attaches to the owning prefab instance" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A component added to a prefab instance's placed GameObject: the
    // instance's root GameObject is `stripped` in the outer document, and
    // the real MonoBehaviour doc points m_GameObject at it.
    const before =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_TransformParent: {fileID: 0}
        \\    m_Modifications:
        \\    - target: {fileID: 8, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: Outer
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
        \\--- !u!1 &2 stripped
        \\GameObject:
        \\  m_PrefabInstance: {fileID: 1001}
        \\--- !u!114 &3
        \\MonoBehaviour:
        \\  m_GameObject: {fileID: 2}
        \\  m_Script: {fileID: 0, guid: abc, type: 3}
        \\  hp: 1
    ;
    const after =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_TransformParent: {fileID: 0}
        \\    m_Modifications:
        \\    - target: {fileID: 8, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: Outer
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
        \\--- !u!1 &2 stripped
        \\GameObject:
        \\  m_PrefabInstance: {fileID: 1001}
        \\--- !u!114 &3
        \\MonoBehaviour:
        \\  m_GameObject: {fileID: 2}
        \\  m_Script: {fileID: 0, guid: abc, type: 3}
        \\  hp: 2
    ;
    const res = try root.diffBytes(arena, before, after);
    try testing.expectEqual(@as(usize, 1), res.roots.len);
    try testing.expectEqual(@as(usize, 0), res.loose.len);
    const inst = res.roots[0];
    try testing.expectEqual(model.ObjectKind.prefab_instance, inst.kind);
    try testing.expectEqual(@as(usize, 1), inst.components.len);
    try testing.expectEqual(model.Status.modified, inst.components[0].status);
    var saw_hp = false;
    for (inst.components[0].fields) |f| {
        if (std.mem.eql(u8, f.path, "Hp")) saw_hp = true;
    }
    try testing.expect(saw_hp);
}

test "tree: component of a stripped GameObject with unresolvable m_PrefabInstance becomes loose" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The stripped GameObject's m_PrefabInstance points nowhere resolvable
    // (fileID 9999 doesn't exist): the component must not be dropped.
    const before =
        \\--- !u!1 &2 stripped
        \\GameObject:
        \\  m_PrefabInstance: {fileID: 9999}
        \\--- !u!114 &3
        \\MonoBehaviour:
        \\  m_GameObject: {fileID: 2}
        \\  m_Script: {fileID: 0, guid: abc, type: 3}
        \\  hp: 1
    ;
    const after =
        \\--- !u!1 &2 stripped
        \\GameObject:
        \\  m_PrefabInstance: {fileID: 9999}
        \\--- !u!114 &3
        \\MonoBehaviour:
        \\  m_GameObject: {fileID: 2}
        \\  m_Script: {fileID: 0, guid: abc, type: 3}
        \\  hp: 2
    ;
    const res = try root.diffBytes(arena, before, after);
    try testing.expectEqual(@as(usize, 0), res.roots.len);
    try testing.expectEqual(@as(usize, 1), res.loose.len);
    try testing.expectEqual(@as(i64, 3), res.loose[0].file_id);
    try testing.expectEqual(model.Status.modified, res.loose[0].status);
}

test "tree: component bridged to a stripped nested prefab instance becomes loose, not dropped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Component bridged to a stripped nested PrefabInstance that carries NO
    // m_PrefabInstance ref of its own: the chain out to the outer instance
    // is broken, so the component must fall back to loose, not vanish.
    const before =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_TransformParent: {fileID: 0}
        \\    m_Modifications:
        \\    - target: {fileID: 8, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: Outer
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
        \\--- !u!1001 &2002 stripped
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_TransformParent: {fileID: 0}
        \\  m_SourcePrefab: {fileID: 100100000, guid: bbb, type: 3}
        \\--- !u!1 &2 stripped
        \\GameObject:
        \\  m_PrefabInstance: {fileID: 2002}
        \\--- !u!114 &3
        \\MonoBehaviour:
        \\  m_GameObject: {fileID: 2}
        \\  m_Script: {fileID: 0, guid: abc, type: 3}
        \\  hp: 1
    ;
    const after =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_TransformParent: {fileID: 0}
        \\    m_Modifications:
        \\    - target: {fileID: 8, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: Outer
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
        \\--- !u!1001 &2002 stripped
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_TransformParent: {fileID: 0}
        \\  m_SourcePrefab: {fileID: 100100000, guid: bbb, type: 3}
        \\--- !u!1 &2 stripped
        \\GameObject:
        \\  m_PrefabInstance: {fileID: 2002}
        \\--- !u!114 &3
        \\MonoBehaviour:
        \\  m_GameObject: {fileID: 2}
        \\  m_Script: {fileID: 0, guid: abc, type: 3}
        \\  hp: 2
    ;
    const res = try root.diffBytes(arena, before, after);
    // Outer instance is unchanged -> pruned as usual; the component stays visible.
    try testing.expectEqual(@as(usize, 0), res.roots.len);
    try testing.expectEqual(@as(usize, 1), res.loose.len);
    try testing.expectEqual(@as(i64, 3), res.loose[0].file_id);
    try testing.expectEqual(model.Status.modified, res.loose[0].status);
}

test "tree: component of a nested stripped chain attaches to the outer prefab instance" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Component added to a GameObject inside a NESTED instance: the inner
    // PrefabInstance is stripped in the outer document and carries its own
    // m_PrefabInstance ref to the outer instance. Walking that chain must
    // attach the component to the outer (materialized) instance node
    // instead of dropping it to loose.
    const before =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_TransformParent: {fileID: 0}
        \\    m_Modifications:
        \\    - target: {fileID: 8, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: Outer
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
        \\--- !u!1001 &2002 stripped
        \\PrefabInstance:
        \\  m_CorrespondingSourceObject: {fileID: 9, guid: bbb, type: 3}
        \\  m_PrefabInstance: {fileID: 1001}
        \\  m_PrefabAsset: {fileID: 0}
        \\--- !u!1 &2 stripped
        \\GameObject:
        \\  m_CorrespondingSourceObject: {fileID: 10, guid: bbb, type: 3}
        \\  m_PrefabInstance: {fileID: 2002}
        \\  m_PrefabAsset: {fileID: 0}
        \\--- !u!114 &3
        \\MonoBehaviour:
        \\  m_GameObject: {fileID: 2}
        \\  m_Script: {fileID: 0, guid: abc, type: 3}
        \\  hp: 1
    ;
    const after =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_TransformParent: {fileID: 0}
        \\    m_Modifications:
        \\    - target: {fileID: 8, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: Outer
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
        \\--- !u!1001 &2002 stripped
        \\PrefabInstance:
        \\  m_CorrespondingSourceObject: {fileID: 9, guid: bbb, type: 3}
        \\  m_PrefabInstance: {fileID: 1001}
        \\  m_PrefabAsset: {fileID: 0}
        \\--- !u!1 &2 stripped
        \\GameObject:
        \\  m_CorrespondingSourceObject: {fileID: 10, guid: bbb, type: 3}
        \\  m_PrefabInstance: {fileID: 2002}
        \\  m_PrefabAsset: {fileID: 0}
        \\--- !u!114 &3
        \\MonoBehaviour:
        \\  m_GameObject: {fileID: 2}
        \\  m_Script: {fileID: 0, guid: abc, type: 3}
        \\  hp: 2
    ;
    const res = try root.diffBytes(arena, before, after);
    try testing.expectEqual(@as(usize, 1), res.roots.len);
    try testing.expectEqual(@as(usize, 0), res.loose.len);
    const inst = res.roots[0];
    try testing.expectEqual(model.ObjectKind.prefab_instance, inst.kind);
    try testing.expectEqual(@as(i64, 1001), inst.file_id);
    try testing.expectEqual(@as(usize, 1), inst.components.len);
    try testing.expectEqual(@as(i64, 3), inst.components[0].file_id);
    try testing.expectEqual(model.Status.modified, inst.components[0].status);
}

test "tree: cyclic stripped instance chain falls back to loose, not an infinite loop" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Corrupt file: two stripped PrefabInstances reference each other. The
    // hop cap must break the cycle and the component keeps the loose floor.
    const before =
        \\--- !u!1001 &2002 stripped
        \\PrefabInstance:
        \\  m_PrefabInstance: {fileID: 3003}
        \\--- !u!1001 &3003 stripped
        \\PrefabInstance:
        \\  m_PrefabInstance: {fileID: 2002}
        \\--- !u!1 &2 stripped
        \\GameObject:
        \\  m_PrefabInstance: {fileID: 2002}
        \\--- !u!114 &3
        \\MonoBehaviour:
        \\  m_GameObject: {fileID: 2}
        \\  m_Script: {fileID: 0, guid: abc, type: 3}
        \\  hp: 1
    ;
    const after =
        \\--- !u!1001 &2002 stripped
        \\PrefabInstance:
        \\  m_PrefabInstance: {fileID: 3003}
        \\--- !u!1001 &3003 stripped
        \\PrefabInstance:
        \\  m_PrefabInstance: {fileID: 2002}
        \\--- !u!1 &2 stripped
        \\GameObject:
        \\  m_PrefabInstance: {fileID: 2002}
        \\--- !u!114 &3
        \\MonoBehaviour:
        \\  m_GameObject: {fileID: 2}
        \\  m_Script: {fileID: 0, guid: abc, type: 3}
        \\  hp: 2
    ;
    const res = try root.diffBytes(arena, before, after);
    try testing.expectEqual(@as(usize, 0), res.roots.len);
    try testing.expectEqual(@as(usize, 1), res.loose.len);
    try testing.expectEqual(@as(i64, 3), res.loose[0].file_id);
    try testing.expectEqual(model.Status.modified, res.loose[0].status);
}

test "tree: instance parented inside a nested instance nests under the outer instance" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A real PrefabInstance whose m_TransformParent is a stripped Transform
    // belonging to a stripped NESTED instance: the chain walks out to the
    // outer real instance instead of flattening the child to a root.
    const after =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_TransformParent: {fileID: 0}
        \\    m_Modifications:
        \\    - target: {fileID: 8, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: Outer
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
        \\--- !u!1001 &2002 stripped
        \\PrefabInstance:
        \\  m_CorrespondingSourceObject: {fileID: 9, guid: bbb, type: 3}
        \\  m_PrefabInstance: {fileID: 1001}
        \\  m_PrefabAsset: {fileID: 0}
        \\--- !u!4 &42 stripped
        \\Transform:
        \\  m_CorrespondingSourceObject: {fileID: 7, guid: bbb, type: 3}
        \\  m_PrefabInstance: {fileID: 2002}
        \\  m_PrefabAsset: {fileID: 0}
        \\--- !u!1001 &3003
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_TransformParent: {fileID: 42}
        \\    m_Modifications:
        \\    - target: {fileID: 8, guid: ccc, type: 3}
        \\      propertyPath: m_Name
        \\      value: Inner
        \\  m_SourcePrefab: {fileID: 100100000, guid: ccc, type: 3}
    ;
    const res = try root.diffBytes(arena, "", after);
    try testing.expectEqual(@as(usize, 1), res.roots.len);
    try testing.expectEqualStrings("Outer", res.roots[0].name);
    try testing.expectEqual(@as(usize, 1), res.roots[0].children.len);
    try testing.expectEqualStrings("Inner", res.roots[0].children[0].name);
}
