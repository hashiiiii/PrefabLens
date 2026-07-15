const std = @import("std");
const model = @import("model.zig");
const root = @import("root.zig");
const testing = std.testing;

const diffmod = @import("diff.zig");

const ComponentDiff = model.ComponentDiff;
const ObjectDiff = model.ObjectDiff;

// Index into parsed documents (union of before+after).
const Index = struct {
    // file_id -> DocDiff (status + fields). Speeds up component construction.
    diff_by_id: std.AutoHashMap(i64, diffmod.DocDiff),
    // file_id -> *Document for structural resolution (after preferred).
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

fn sourcePrefabGuid(doc: *const model.Document) ?[]const u8 {
    const s = model.findValue(doc.body.map, "m_SourcePrefab") orelse return null;
    return switch (s.*) {
        .ref => |r| r.guid,
        else => null,
    };
}

// Read one m_Modifications override value of a PrefabInstance by propertyPath
// (from the after-preferred structural doc).
fn modificationValue(idx: *Index, pi_id: i64, property_path: []const u8) ?[]const u8 {
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

// Pick up the m_Name override as the instance name.
fn instanceName(idx: *Index, pi_id: i64) []const u8 {
    return modificationValue(idx, pi_id, "m_Name") orelse "";
}

// Hop limit for walking the nesting chain. Stops even if stripped PrefabInstances
// reference each other cyclically in a broken file (real projects nest a few levels).
const max_instance_hops = 8;

// Walk the m_PrefabInstance chain of a stripped PrefabInstance outward and
// return the file_id of the real (non-stripped) PrefabInstance.
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

// From a Transform's file_id to the id of the parent node (GameObject or PrefabInstance).
// A stripped Transform bridges to its owning instance via m_PrefabInstance.
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
        const tid = refFileId(r) orelse continue;
        const owner = ownerNodeIdOfTransform(idx, tid) orelse continue;
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
fn orderChildren(arena: std.mem.Allocator, idx: *Index, parent_id: i64, list: *std.ArrayList(i64)) !void {
    const parent = idx.structuralDoc(parent_id) orelse return;
    if (parent.class_id != 1) return;
    const tr = transformOf(idx, parent_id) orelse return;
    const kids = model.findValue(tr.body.map, "m_Children") orelse return;
    if (kids.* != .seq) return;
    try orderByTransformRefs(arena, idx, kids.seq, list);
}

fn rootOrderOf(idx: *Index, id: i64) ?i64 {
    const doc = idx.structuralDoc(id) orelse return null;
    if (doc.class_id == 1001) {
        const s = modificationValue(idx, id, "m_RootOrder") orelse return null;
        return std.fmt.parseInt(i64, s, 10) catch null;
    }
    const tr = transformOf(idx, id) orelse return null;
    const v = model.findValue(tr.body.map, "m_RootOrder") orelse return null;
    return switch (v.*) {
        .scalar => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

// Scene root order: SceneRoots.m_Roots when present, else the per-transform
// m_RootOrder of older scene formats. Prefabs and .asset files carry neither,
// so they fall through untouched.
fn orderRoots(arena: std.mem.Allocator, idx: *Index, fd: diffmod.FlatDiff, roots_ids: *std.ArrayList(i64)) !void {
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
            const go_id = gameObjectIdOfComponent(doc) orelse break :blk null;
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
                const pi_id = refFileId(model.findValue(go_doc.body.map, "m_PrefabInstance")) orelse break :blk null;
                break :inner resolveInstanceChain(&idx, pi_id) orelse break :blk null;
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
        try linkToParent(arena, &obj_by_id, &children_of, &roots_ids, parentGoId(&idx, go_id), go_id);
    for (pi_ids.items) |pi_id|
        try linkToParent(arena, &obj_by_id, &children_of, &roots_ids, instanceParentId(&idx, pi_id), pi_id);

    // Reorder siblings and roots to Unity's Hierarchy order; document order in the
    // file is unrelated to it (often exactly reversed).
    var cit = children_of.iterator();
    while (cit.next()) |e| try orderChildren(arena, &idx, e.key_ptr.*, e.value_ptr);
    try orderRoots(arena, &idx, fd, &roots_ids);

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
    const parent = findRoot(res, 1).?;
    try testing.expectEqual(@as(usize, 1), parent.children.len);
    try testing.expectEqual(@as(i64, 2), parent.children[0].file_id);
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
    const parent = findRoot(res, 1).?;
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
    const parent = findRoot(res, 1).?;
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
    const parent = findRoot(res, 1).?;
    try testing.expectEqual(@as(usize, 3), parent.children.len);
    try testing.expectEqual(@as(i64, 2), parent.children[0].file_id);
    try testing.expectEqual(@as(i64, 3), parent.children[1].file_id);
    try testing.expectEqual(@as(i64, 9), parent.children[2].file_id);
    try testing.expectEqual(model.Status.removed, parent.children[2].status);
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
