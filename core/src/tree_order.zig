// Hierarchy ordering: reorder siblings and scene roots to Unity's Hierarchy order
// (m_Children / SceneRoots.m_Roots / m_RootOrder). Document order in the file is
// unrelated to it (often exactly reversed).
const std = @import("std");
const model = @import("model.zig");
const root = @import("root.zig");
const testing = std.testing;

const diffmod = @import("diff.zig");
const tree_chain = @import("tree_chain.zig");
const treemod = @import("tree.zig");

const Index = tree_chain.Index;

// Unity 2022.2+ scenes list root transforms in Hierarchy order in a SceneRoots document.
const scene_roots_class_id = 1660057539;

fn sceneRootsDoc(fd: diffmod.FlatDiff) ?*model.Document {
    // After side preferred: it reflects the current Hierarchy.
    for (fd.after) |*d| if (d.class_id == scene_roots_class_id) return d;
    for (fd.before) |*d| if (d.class_id == scene_roots_class_id) return d;
    return null;
}

// Stable reorder of node ids against a list of transform refs (m_Children / m_Roots):
// ids matching a ref (in ref order) first, the rest in insertion order after them
// (removed objects have no position in the after-side Hierarchy anymore).
fn orderByTransformRefs(arena: std.mem.Allocator, idx: *Index, refs: []*model.Node, list: *std.ArrayList(i64)) !void {
    var members = std.AutoHashMap(i64, void).init(arena);
    for (list.items) |id| try members.put(id, {});
    var picked = std.AutoHashMap(i64, void).init(arena);
    var out: std.ArrayList(i64) = .empty;
    try out.ensureTotalCapacity(arena, list.items.len);
    for (refs) |r| {
        const tid = tree_chain.refFileId(r) orelse continue;
        const owner = tree_chain.ownerNodeIdOfTransform(idx, tid) orelse continue;
        if (!members.contains(owner) or picked.contains(owner)) continue;
        try picked.put(owner, {});
        out.appendAssumeCapacity(owner);
    }
    for (list.items) |id| {
        if (!picked.contains(id)) out.appendAssumeCapacity(id);
    }
    list.* = out;
}

// Reorder a sibling list to the parent Transform's m_Children order. A PrefabInstance
// parent keeps insertion order: its inner transforms live in the source prefab, so the
// outer document carries no sibling order for them.
pub fn orderChildren(arena: std.mem.Allocator, idx: *Index, parent_id: i64, list: *std.ArrayList(i64)) !void {
    const parent = idx.structuralDoc(parent_id) orelse return;
    if (parent.class_id != 1) return;
    const tr = tree_chain.transformOf(idx, parent_id) orelse return;
    const kids = model.findValue(tr.body.map, "m_Children") orelse return;
    if (kids.* != .seq) return;
    try orderByTransformRefs(arena, idx, kids.seq, list);
}

fn rootOrderOf(idx: *Index, id: i64) ?i64 {
    const doc = idx.structuralDoc(id) orelse return null;
    if (doc.class_id == 1001) {
        const s = tree_chain.modificationValue(idx, id, "m_RootOrder") orelse return null;
        return std.fmt.parseInt(i64, s, 10) catch null;
    }
    const tr = tree_chain.transformOf(idx, id) orelse return null;
    const v = model.findValue(tr.body.map, "m_RootOrder") orelse return null;
    return switch (v.*) {
        .scalar => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

// Scene root order: SceneRoots.m_Roots when present, else the per-transform
// m_RootOrder of older scene formats. Prefabs and .asset files carry neither,
// so they fall through untouched.
pub fn orderRoots(arena: std.mem.Allocator, idx: *Index, fd: diffmod.FlatDiff, roots_ids: *std.ArrayList(i64)) !void {
    if (sceneRootsDoc(fd)) |doc| {
        const roots = model.findValue(doc.body.map, "m_Roots") orelse return;
        if (roots.* != .seq) return;
        try orderByTransformRefs(arena, idx, roots.seq, roots_ids);
        return;
    }
    const Keyed = struct { key: i64, pos: usize, id: i64 };
    const keyed = try arena.alloc(Keyed, roots_ids.items.len);
    var any_key = false;
    for (roots_ids.items, 0..) |id, i| {
        const key = rootOrderOf(idx, id);
        if (key != null) any_key = true;
        keyed[i] = .{ .key = key orelse std.math.maxInt(i64), .pos = i, .id = id };
    }
    if (!any_key) return;
    std.mem.sort(Keyed, keyed, {}, struct {
        fn lessThan(_: void, a: Keyed, b: Keyed) bool {
            if (a.key != b.key) return a.key < b.key;
            return a.pos < b.pos;
        }
    }.lessThan);
    for (keyed, 0..) |k, i| roots_ids.items[i] = k.id;
}

test "tree: siblings follow the parent transform's m_Children order, not document order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The file lists B before A, but the parent's m_Children puts A first (Unity Hierarchy order).
    const before =
        \\--- !u!1 &3
        \\GameObject:
        \\  m_Name: B
        \\  m_Component:
        \\  - component: {fileID: 6}
        \\--- !u!4 &6
        \\Transform:
        \\  m_GameObject: {fileID: 3}
        \\  m_Father: {fileID: 4}
        \\--- !u!1 &2
        \\GameObject:
        \\  m_Name: A
        \\  m_Component:
        \\  - component: {fileID: 5}
        \\--- !u!4 &5
        \\Transform:
        \\  m_GameObject: {fileID: 2}
        \\  m_Father: {fileID: 4}
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: Parent
        \\  m_Component:
        \\  - component: {fileID: 4}
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_Father: {fileID: 0}
        \\  m_Children:
        \\  - {fileID: 5}
        \\  - {fileID: 6}
    ;
    const after =
        \\--- !u!1 &3
        \\GameObject:
        \\  m_Name: B2
        \\  m_Component:
        \\  - component: {fileID: 6}
        \\--- !u!4 &6
        \\Transform:
        \\  m_GameObject: {fileID: 3}
        \\  m_Father: {fileID: 4}
        \\--- !u!1 &2
        \\GameObject:
        \\  m_Name: A2
        \\  m_Component:
        \\  - component: {fileID: 5}
        \\--- !u!4 &5
        \\Transform:
        \\  m_GameObject: {fileID: 2}
        \\  m_Father: {fileID: 4}
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: Parent
        \\  m_Component:
        \\  - component: {fileID: 4}
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_Father: {fileID: 0}
        \\  m_Children:
        \\  - {fileID: 5}
        \\  - {fileID: 6}
    ;
    const res = try root.diffBytes(arena, before, after);
    const parent = treemod.findRoot(res, 1).?;
    try testing.expectEqual(@as(usize, 2), parent.children.len);
    try testing.expectEqual(@as(i64, 2), parent.children[0].file_id);
    try testing.expectEqual(@as(i64, 3), parent.children[1].file_id);
}

test "tree: scene roots follow SceneRoots m_Roots order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Document order is Floor, Crate, Sun; the Hierarchy order in SceneRoots is the reverse.
    const before =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: Floor
        \\  m_Component:
        \\  - component: {fileID: 4}
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_Father: {fileID: 0}
        \\--- !u!1 &2
        \\GameObject:
        \\  m_Name: Crate
        \\  m_Component:
        \\  - component: {fileID: 5}
        \\--- !u!4 &5
        \\Transform:
        \\  m_GameObject: {fileID: 2}
        \\  m_Father: {fileID: 0}
        \\--- !u!1 &3
        \\GameObject:
        \\  m_Name: Sun
        \\  m_Component:
        \\  - component: {fileID: 6}
        \\--- !u!4 &6
        \\Transform:
        \\  m_GameObject: {fileID: 3}
        \\  m_Father: {fileID: 0}
        \\--- !u!1660057539 &9223372036854775807
        \\SceneRoots:
        \\  m_Roots:
        \\  - {fileID: 6}
        \\  - {fileID: 5}
        \\  - {fileID: 4}
    ;
    const after =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: Floor2
        \\  m_Component:
        \\  - component: {fileID: 4}
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_Father: {fileID: 0}
        \\--- !u!1 &2
        \\GameObject:
        \\  m_Name: Crate2
        \\  m_Component:
        \\  - component: {fileID: 5}
        \\--- !u!4 &5
        \\Transform:
        \\  m_GameObject: {fileID: 2}
        \\  m_Father: {fileID: 0}
        \\--- !u!1 &3
        \\GameObject:
        \\  m_Name: Sun2
        \\  m_Component:
        \\  - component: {fileID: 6}
        \\--- !u!4 &6
        \\Transform:
        \\  m_GameObject: {fileID: 3}
        \\  m_Father: {fileID: 0}
        \\--- !u!1660057539 &9223372036854775807
        \\SceneRoots:
        \\  m_Roots:
        \\  - {fileID: 6}
        \\  - {fileID: 5}
        \\  - {fileID: 4}
    ;
    const res = try root.diffBytes(arena, before, after);
    try testing.expectEqual(@as(usize, 3), res.roots.len);
    try testing.expectEqual(@as(i64, 3), res.roots[0].file_id);
    try testing.expectEqual(@as(i64, 2), res.roots[1].file_id);
    try testing.expectEqual(@as(i64, 1), res.roots[2].file_id);
    // The unchanged SceneRoots document itself stays invisible.
    try testing.expectEqual(@as(usize, 0), res.loose.len);
}

test "tree: roots follow m_RootOrder when SceneRoots is absent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Old scene format: no SceneRoots document, each root transform carries m_RootOrder.
    const before =
        \\--- !u!1 &2
        \\GameObject:
        \\  m_Name: Y
        \\  m_Component:
        \\  - component: {fileID: 5}
        \\--- !u!4 &5
        \\Transform:
        \\  m_GameObject: {fileID: 2}
        \\  m_Father: {fileID: 0}
        \\  m_RootOrder: 1
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: X
        \\  m_Component:
        \\  - component: {fileID: 4}
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_Father: {fileID: 0}
        \\  m_RootOrder: 0
    ;
    const after =
        \\--- !u!1 &2
        \\GameObject:
        \\  m_Name: Y2
        \\  m_Component:
        \\  - component: {fileID: 5}
        \\--- !u!4 &5
        \\Transform:
        \\  m_GameObject: {fileID: 2}
        \\  m_Father: {fileID: 0}
        \\  m_RootOrder: 1
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: X2
        \\  m_Component:
        \\  - component: {fileID: 4}
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_Father: {fileID: 0}
        \\  m_RootOrder: 0
    ;
    const res = try root.diffBytes(arena, before, after);
    try testing.expectEqual(@as(usize, 2), res.roots.len);
    try testing.expectEqual(@as(i64, 1), res.roots[0].file_id);
    try testing.expectEqual(@as(i64, 2), res.roots[1].file_id);
}

test "tree: prefab instance ranks among siblings via its stripped transform" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // m_Children lists the instance's stripped transform (42) before the plain child (5).
    const after =
        \\--- !u!1 &2
        \\GameObject:
        \\  m_Name: C
        \\  m_Component:
        \\  - component: {fileID: 5}
        \\--- !u!4 &5
        \\Transform:
        \\  m_GameObject: {fileID: 2}
        \\  m_Father: {fileID: 4}
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_TransformParent: {fileID: 4}
        \\    m_Modifications:
        \\    - target: {fileID: 8, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: Inst
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
        \\--- !u!4 &42 stripped
        \\Transform:
        \\  m_PrefabInstance: {fileID: 1001}
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: Parent
        \\  m_Component:
        \\  - component: {fileID: 4}
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_Father: {fileID: 0}
        \\  m_Children:
        \\  - {fileID: 42}
        \\  - {fileID: 5}
    ;
    const res = try root.diffBytes(arena, "", after);
    const parent = treemod.findRoot(res, 1).?;
    try testing.expectEqual(@as(usize, 2), parent.children.len);
    try testing.expectEqual(@as(i64, 1001), parent.children[0].file_id);
    try testing.expectEqual(@as(i64, 2), parent.children[1].file_id);
}

test "tree: removed child sorts after siblings present in m_Children" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // R only exists on the before side; the after-side m_Children ranks A before B,
    // and the deleted R has no Hierarchy position anymore so it goes last.
    const before =
        \\--- !u!1 &9
        \\GameObject:
        \\  m_Name: R
        \\  m_Component:
        \\  - component: {fileID: 7}
        \\--- !u!4 &7
        \\Transform:
        \\  m_GameObject: {fileID: 9}
        \\  m_Father: {fileID: 4}
        \\--- !u!1 &3
        \\GameObject:
        \\  m_Name: B
        \\  m_Component:
        \\  - component: {fileID: 6}
        \\--- !u!4 &6
        \\Transform:
        \\  m_GameObject: {fileID: 3}
        \\  m_Father: {fileID: 4}
        \\--- !u!1 &2
        \\GameObject:
        \\  m_Name: A
        \\  m_Component:
        \\  - component: {fileID: 5}
        \\--- !u!4 &5
        \\Transform:
        \\  m_GameObject: {fileID: 2}
        \\  m_Father: {fileID: 4}
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: Parent
        \\  m_Component:
        \\  - component: {fileID: 4}
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_Father: {fileID: 0}
        \\  m_Children:
        \\  - {fileID: 5}
        \\  - {fileID: 7}
        \\  - {fileID: 6}
    ;
    const after =
        \\--- !u!1 &3
        \\GameObject:
        \\  m_Name: B2
        \\  m_Component:
        \\  - component: {fileID: 6}
        \\--- !u!4 &6
        \\Transform:
        \\  m_GameObject: {fileID: 3}
        \\  m_Father: {fileID: 4}
        \\--- !u!1 &2
        \\GameObject:
        \\  m_Name: A2
        \\  m_Component:
        \\  - component: {fileID: 5}
        \\--- !u!4 &5
        \\Transform:
        \\  m_GameObject: {fileID: 2}
        \\  m_Father: {fileID: 4}
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: Parent
        \\  m_Component:
        \\  - component: {fileID: 4}
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_Father: {fileID: 0}
        \\  m_Children:
        \\  - {fileID: 5}
        \\  - {fileID: 6}
    ;
    const res = try root.diffBytes(arena, before, after);
    const parent = treemod.findRoot(res, 1).?;
    try testing.expectEqual(@as(usize, 3), parent.children.len);
    try testing.expectEqual(@as(i64, 2), parent.children[0].file_id);
    try testing.expectEqual(@as(i64, 3), parent.children[1].file_id);
    try testing.expectEqual(@as(i64, 9), parent.children[2].file_id);
    try testing.expectEqual(model.Status.removed, parent.children[2].status);
}
