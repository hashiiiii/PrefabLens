// Transform-chain resolution: walk m_Father / m_PrefabInstance / m_TransformParent
// references through the structural index to the node (GameObject or PrefabInstance)
// that owns a transform, bridging stripped documents to the nearest real instance.
const std = @import("std");
const model = @import("model.zig");
const root = @import("root.zig");
const testing = std.testing;

const diffmod = @import("diff.zig");
const treemod = @import("tree.zig");

// Index into parsed documents (union of before+after).
pub const Index = struct {
    // file_id -> DocDiff (status + fields). Speeds up component construction.
    diff_by_id: std.AutoHashMap(i64, diffmod.DocDiff),
    // file_id -> *Document for structural resolution (after preferred).
    doc_by_id: std.AutoHashMap(i64, *model.Document),

    pub fn structuralDoc(self: *Index, file_id: i64) ?*model.Document {
        return self.doc_by_id.get(file_id);
    }
};

pub fn refFileId(node: ?*model.Node) ?i64 {
    const n = node orelse return null;
    return switch (n.*) {
        .ref => |r| r.file_id,
        else => null,
    };
}

pub fn gameObjectIdOfComponent(doc: *model.Document) ?i64 {
    return refFileId(model.findValue(doc.body.map, "m_GameObject"));
}

pub fn transformOf(idx: *Index, go_id: i64) ?*model.Document {
    // Find the Transform/RectTransform among the components the GameObject lists.
    const go = idx.structuralDoc(go_id) orelse return null;
    const comps = model.findValue(go.body.map, "m_Component") orelse return null;
    if (comps.* != .seq) return null;
    for (comps.seq) |item| {
        const cref = if (item.* == .map) model.findValue(item.map, "component") else null;
        const cid = refFileId(cref) orelse continue;
        const cdoc = idx.structuralDoc(cid) orelse continue;
        if (isTransformClass(cdoc.class_id)) return cdoc;
    }
    return null;
}

fn isTransformClass(id: u32) bool {
    return id == 4 or id == 224;
}

// Read one m_Modifications override value of a PrefabInstance by propertyPath
// (from the after-preferred structural doc).
pub fn modificationValue(idx: *Index, pi_id: i64, property_path: []const u8) ?[]const u8 {
    const doc = idx.structuralDoc(pi_id) orelse return null;
    const m = model.findValue(doc.body.map, "m_Modification") orelse return null;
    if (m.* != .map) return null;
    const list = model.findValue(m.map, "m_Modifications") orelse return null;
    if (list.* != .seq) return null;
    for (list.seq) |item| {
        if (item.* != .map) continue;
        const pp = model.findValue(item.map, "propertyPath") orelse continue;
        if (pp.* != .scalar or !std.mem.eql(u8, pp.scalar, property_path)) continue;
        const v = model.findValue(item.map, "value") orelse continue;
        return switch (v.*) {
            .scalar => |s| s,
            else => null,
        };
    }
    return null;
}

// Walk the m_PrefabInstance chain of a stripped PrefabInstance outward and
// return the file_id of the real (non-stripped) PrefabInstance.
pub fn resolveInstanceChain(idx: *Index, start_id: i64) ?i64 {
    var id = start_id;
    var hops: usize = 0;
    while (hops < model.max_prefab_nesting) : (hops += 1) {
        const doc = idx.structuralDoc(id) orelse return null;
        if (doc.class_id != 1001) return null;
        if (!doc.stripped) return id;
        id = refFileId(model.findValue(doc.body.map, "m_PrefabInstance")) orelse return null;
    }
    return null;
}

// From a Transform's file_id to the id of the parent node (GameObject or PrefabInstance).
// A stripped Transform bridges to its owning instance via m_PrefabInstance.
pub fn ownerNodeIdOfTransform(idx: *Index, tr_id: i64) ?i64 {
    if (tr_id == 0) return null;
    const tr = idx.structuralDoc(tr_id) orelse return null;
    if (!isTransformClass(tr.class_id)) return null;
    if (tr.stripped) {
        const pi_id = refFileId(model.findValue(tr.body.map, "m_PrefabInstance")) orelse return null;
        return resolveInstanceChain(idx, pi_id);
    }
    return gameObjectIdOfComponent(tr);
}

pub fn instanceParentId(idx: *Index, pi_id: i64) ?i64 {
    const doc = idx.structuralDoc(pi_id) orelse return null;
    const m = model.findValue(doc.body.map, "m_Modification") orelse return null;
    if (m.* != .map) return null;
    const tp = refFileId(model.findValue(m.map, "m_TransformParent")) orelse return null;
    return ownerNodeIdOfTransform(idx, tp);
}

pub fn parentGoId(idx: *Index, go_id: i64) ?i64 {
    const tr = transformOf(idx, go_id) orelse return null;
    const father_id = refFileId(model.findValue(tr.body.map, "m_Father")) orelse return null;
    return ownerNodeIdOfTransform(idx, father_id);
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
    // after: rename the child
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
    const parent = treemod.findRoot(res, 1).?;
    try testing.expectEqual(@as(usize, 1), parent.children.len);
    try testing.expectEqual(@as(i64, 2), parent.children[0].file_id);
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
    // The stripped Transform appears nowhere.
    try testing.expectEqual(@as(usize, 0), inst.components.len);
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

test "tree: component of a stripped GameObject attaches to the owning prefab instance" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A component added to a GameObject placed by a prefab instance:
    // the instance's root GameObject is stripped in the outer document, and the real
    // MonoBehaviour doc points to it via m_GameObject.
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
    // A stripped GameObject's m_PrefabInstance points to an unresolvable target
    // (nonexistent fileID 9999): the component must still not vanish.
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
    // The bridged-to stripped nested PrefabInstance has no m_PrefabInstance reference
    // of its own: the chain to the outer instance is broken, so the component falls to
    // loose rather than vanishing.
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
    // The outer instance is unchanged so it is pruned as usual, and the component stays visible.
    try testing.expectEqual(@as(usize, 0), res.roots.len);
    try testing.expectEqual(@as(usize, 1), res.loose.len);
    try testing.expectEqual(@as(i64, 3), res.loose[0].file_id);
    try testing.expectEqual(model.Status.modified, res.loose[0].status);
}

test "tree: component of a nested stripped chain attaches to the outer prefab instance" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A component added to a GameObject inside a nested instance: the inner
    // PrefabInstance is stripped in the outer document and holds its own m_PrefabInstance
    // reference to the outer instance. Walk this chain and reattach the component to the
    // outer (materialized) instance node rather than dropping it to loose.
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
    // Broken file: two stripped PrefabInstances reference each other.
    // The hop limit breaks the cycle, and the component holds the loose floor.
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
    // A real PrefabInstance's m_TransformParent points to a stripped Transform belonging
    // to a stripped nested instance: walk the chain to the outer real instance, and don't
    // flatten the child to a root.
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
