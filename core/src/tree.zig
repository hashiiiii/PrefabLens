// Tree materialization: group components under their owning GameObject or
// PrefabInstance, assemble parent-child links, and materialize the pruned
// ObjectDiff tree. Reference walking lives in tree_chain.zig and Hierarchy
// ordering in tree_order.zig.
const std = @import("std");
const model = @import("model.zig");
const root = @import("root.zig");
const testing = std.testing;

const diffmod = @import("diff.zig");
const tree_chain = @import("tree_chain.zig");
const tree_order = @import("tree_order.zig");

const ComponentDiff = model.ComponentDiff;
const ObjectDiff = model.ObjectDiff;
const Index = tree_chain.Index;

fn sourcePrefabGuid(doc: *const model.Document) ?[]const u8 {
    const s = model.findValue(doc.body.map, "m_SourcePrefab") orelse return null;
    return switch (s.*) {
        .ref => |r| r.guid,
        else => null,
    };
}

// Pick up the m_Name override as the instance name.
fn instanceName(idx: *Index, pi_id: i64) []const u8 {
    return tree_chain.modificationValue(idx, pi_id, "m_Name") orelse "";
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
    // Structural-resolution docs: after preferred, removed objects fall back to before.
    for (fd.before) |*d| try idx.doc_by_id.put(d.file_id, d);
    for (fd.after) |*d| try idx.doc_by_id.put(d.file_id, d); // overwrite makes after win

    // Sort documents into: GameObject, PrefabInstance, their owned components, and loose.
    var go_ids: std.ArrayList(i64) = .empty;
    var pi_ids: std.ArrayList(i64) = .empty;
    // Components grouped by the id of their owning GameObject/PrefabInstance
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
            const go_id = tree_chain.gameObjectIdOfComponent(doc) orelse break :blk null;
            // Only a doc confirmed to be a GameObject can be an owner. Allowing an
            // unresolvable reference ({fileID: 0} or dangling) would sort the component
            // under a phantom id and make it vanish.
            const go_doc = idx.structuralDoc(go_id) orelse break :blk null;
            if (go_doc.class_id != 1) break :blk null;
            // A stripped GameObject (a nested instance's root placed in the outer
            // document) does not become a node. Bridge to its owning PrefabInstance so
            // the component doesn't silently vanish. The owning instance itself can also
            // be stripped (nested prefab), so walk the chain to the nearest instance that
            // gets materialized.
            const owner_id = if (go_doc.stripped) inner: {
                const pi_id = tree_chain.refFileId(model.findValue(go_doc.body.map, "m_PrefabInstance")) orelse break :blk null;
                break :inner tree_chain.resolveInstanceChain(&idx, pi_id) orelse break :blk null;
            } else go_id;
            // A stripped doc is excluded from fd.docs and does not become a node.
            // Only a materializing owner can take on the component.
            break :blk if (idx.diff_by_id.contains(owner_id)) owner_id else null;
        };
        if (owner) |owner_id| {
            const gop = try comps_by_owner.getOrPut(owner_id);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            // Collapse unchanged components that have no fields.
            if (d.status != .unchanged) try gop.value_ptr.append(arena, makeComponent(d));
        } else {
            // No owning GameObject/PrefabInstance -> loose (ScriptableObject etc.).
            if (d.status != .unchanged) try loose.append(arena, makeComponent(d));
        }
    }

    // Build an ObjectDiff per GameObject (children still empty).
    var obj_by_id = std.AutoHashMap(i64, ObjectDiff).init(arena);
    for (go_ids.items) |go_id| {
        const gd = idx.diff_by_id.get(go_id).?;
        const comps: []ComponentDiff = if (comps_by_owner.get(go_id)) |list| list.items else &.{};
        try obj_by_id.put(go_id, .{
            .file_id = go_id,
            .name = goName(&idx, go_id),
            .status = gd.status,
            .components = comps,
            .children = &.{},
        });
    }
    for (pi_ids.items) |pi_id| {
        const dd = idx.diff_by_id.get(pi_id).?;
        const doc = idx.structuralDoc(pi_id);
        const comps: []ComponentDiff = if (comps_by_owner.get(pi_id)) |list| list.items else &.{};
        try obj_by_id.put(pi_id, .{
            .kind = .prefab_instance,
            .file_id = pi_id,
            .name = instanceName(&idx, pi_id),
            .source_guid = if (doc) |dc| sourcePrefabGuid(dc) else null,
            .status = dd.status,
            .overrides = dd.overrides,
            .components = comps,
            .children = &.{},
        });
    }

    // Assemble parent-child links.
    var children_of = std.AutoHashMap(i64, std.ArrayList(i64)).init(arena);
    var roots_ids: std.ArrayList(i64) = .empty;
    for (go_ids.items) |go_id|
        try linkToParent(arena, &obj_by_id, &children_of, &roots_ids, tree_chain.parentGoId(&idx, go_id), go_id);
    for (pi_ids.items) |pi_id|
        try linkToParent(arena, &obj_by_id, &children_of, &roots_ids, tree_chain.instanceParentId(&idx, pi_id), pi_id);

    // Reorder siblings and roots to Unity's Hierarchy order; document order in the
    // file is unrelated to it (often exactly reversed).
    var cit = children_of.iterator();
    while (cit.next()) |e| try tree_order.orderChildren(arena, &idx, e.key_ptr.*, e.value_ptr);
    try tree_order.orderRoots(arena, &idx, fd, &roots_ids);

    // Materialize recursively, pruning unchanged subtrees with no changed descendants.
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

// If the parent is a real node, route to children_of; otherwise to the roots.
fn linkToParent(
    arena: std.mem.Allocator,
    obj_by_id: *std.AutoHashMap(i64, ObjectDiff),
    children_of: *std.AutoHashMap(i64, std.ArrayList(i64)),
    roots_ids: *std.ArrayList(i64),
    parent_id: ?i64,
    id: i64,
) !void {
    if (parent_id) |pid| {
        if (obj_by_id.contains(pid)) {
            const e = try children_of.getOrPut(pid);
            if (!e.found_existing) e.value_ptr.* = .empty;
            try e.value_ptr.append(arena, id);
            return;
        }
    }
    try roots_ids.append(arena, id);
}

// Build the ObjectDiff for `go_id` together with its surviving children. Returns null
// if the node and its whole subtree are unchanged with no components to keep.
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

// pub: tree_chain's and tree_order's tests use it too.
pub fn findRoot(res: model.DiffResult, file_id: i64) ?model.ObjectDiff {
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
    // Player itself is unchanged but survives because a child component changed.
    try testing.expectEqual(model.Status.unchanged, go.status);
    // Components: the unchanged, field-less Transform is collapsed; the MonoBehaviour remains.
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

test "tree: removed GameObject surfaces as a removed root with its name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: Player
        \\  m_Component:
        \\  - component: {fileID: 4}
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_Father: {fileID: 0}
    ;
    // Even with no doc on the after side, structural resolution falls back to before, so
    // name resolution and component ownership work (they don't leak into loose).
    const res = try root.diffBytes(arena, before, "");
    try testing.expectEqual(@as(usize, 1), res.roots.len);
    try testing.expectEqual(@as(usize, 0), res.loose.len);
    try testing.expectEqualStrings("Player", res.roots[0].name);
    try testing.expectEqual(model.Status.removed, res.roots[0].status);
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

test "tree: component whose m_GameObject resolves to a non-GameObject document becomes loose, not dropped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // fileID 999 exists but is a MonoBehaviour, not a GameObject. A different kind of
    // effectively dangling reference from fileID: 0 (there's no GameObject there).
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
    // Component 999 is collapsed as unchanged; 7 goes to loose instead of vanishing.
    try testing.expectEqual(@as(usize, 1), res.loose.len);
    try testing.expectEqual(@as(i64, 7), res.loose[0].file_id);
    try testing.expectEqual(model.Status.modified, res.loose[0].status);
}
