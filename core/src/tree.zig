const std = @import("std");
const model = @import("model.zig");
const root = @import("root.zig");
const testing = std.testing;

const diffmod = @import("diff.zig");

const ComponentDiff = model.ComponentDiff;
const ObjectDiff = model.ObjectDiff;

// パース済みドキュメント(before+after の和集合)への索引。
const Index = struct {
    // file_id -> DocDiff(status + fields)。コンポーネント構築を速くする。
    diff_by_id: std.AutoHashMap(i64, diffmod.DocDiff),
    // file_id -> 構造解決用(after 優先)の *Document。
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
    // GameObject が列挙するコンポーネントから Transform/RectTransform のものを探す。
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

// m_Name override をインスタンス名として拾う(after 優先の structural doc から)。
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

// 入れ子チェーン歩行の hop 上限。壊れたファイルで stripped PrefabInstance
// 同士が循環参照しても停止する(実プロジェクトの入れ子深度は数段)。
const max_instance_hops = 8;

// stripped な PrefabInstance の m_PrefabInstance チェーンを外側へ辿り、
// 実体(非 stripped)の PrefabInstance の file_id を返す。
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

// Transform の file_id から親ノード(GameObject または PrefabInstance)の id。
// stripped Transform は m_PrefabInstance を辿って所属インスタンスに橋渡し。
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
    // 構造解決用 doc: after 優先、removed オブジェクトは before に fallback。
    for (fd.before) |*d| try idx.doc_by_id.put(d.file_id, d);
    for (fd.after) |*d| try idx.doc_by_id.put(d.file_id, d); // 上書きにより after が勝つ

    // ドキュメントを仕分ける: GameObject、PrefabInstance、その所属コンポーネント、loose。
    var go_ids: std.ArrayList(i64) = .empty;
    var pi_ids: std.ArrayList(i64) = .empty;
    // 所属先 GameObject/PrefabInstance の id でグループ化したコンポーネント
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
            // 所有者になれるのは GameObject と確認できた doc のみ。解決不能な
            // 参照({fileID: 0} や宙ぶらりん)を許すと、コンポーネントが
            // 幻の id の下に仕分けられて消えてしまう。
            const go_doc = idx.structuralDoc(go_id) orelse break :blk null;
            if (go_doc.class_id != 1) break :blk null;
            // stripped GameObject(入れ子インスタンスの root が外側ドキュメントに
            // 置かれたもの)はノードにならない。所属 PrefabInstance に橋渡しして
            // コンポーネントが黙って消えないようにする。所属インスタンス自体も
            // stripped の場合(入れ子 prefab)があるため、チェーンを実体化される
            // 最寄りのインスタンスまで辿る。
            const owner_id = if (go_doc.stripped) inner: {
                const pi_id = refFileId(model.findValue(go_doc.body.map, "m_PrefabInstance")) orelse break :blk null;
                break :inner resolveInstanceChain(&idx, pi_id) orelse break :blk null;
            } else go_id;
            // stripped doc は fd.docs から除外されノードにならない。
            // コンポーネントを引き取れるのは実体化する所有者だけ。
            break :blk if (idx.diff_by_id.contains(owner_id)) owner_id else null;
        };
        if (owner) |owner_id| {
            const gop = try comps_by_owner.getOrPut(owner_id);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            // fields を持たない unchanged コンポーネントは畳む。
            if (d.status != .unchanged) try gop.value_ptr.append(arena, makeComponent(d));
        } else {
            // 所属 GameObject/PrefabInstance なし -> loose(ScriptableObject 等)。
            if (d.status != .unchanged) try loose.append(arena, makeComponent(d));
        }
    }

    // GameObject ごとの ObjectDiff を構築する(children はまだ空)。
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

    // 親子リンクを組み立てる。
    var children_of = std.AutoHashMap(i64, std.ArrayList(i64)).init(arena);
    var roots_ids: std.ArrayList(i64) = .empty;
    for (go_ids.items) |go_id|
        try linkToParent(arena, &obj_by_id, &children_of, &roots_ids, parentGoId(&idx, go_id), go_id);
    for (pi_ids.items) |pi_id|
        try linkToParent(arena, &obj_by_id, &children_of, &roots_ids, instanceParentId(&idx, pi_id), pi_id);

    // 再帰的に実体化し、変更された子孫を持たない unchanged な部分木を刈る。
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

// 親が実在ノードなら children_of へ、そうでなければ root へ振り分ける。
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

// `go_id` の ObjectDiff を残った children ごと構築する。ノードと部分木全体が
// unchanged で残すコンポーネントもなければ null を返す。
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
    // Player 自体は unchanged だが、子コンポーネントに変更があるので残る。
    try testing.expectEqual(model.Status.unchanged, go.status);
    // コンポーネント: unchanged で fields もない Transform は畳まれ、MonoBehaviour は残る。
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
    // after: 子をリネーム
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
    // fileID 999 は存在するが GameObject ではなく MonoBehaviour。fileID: 0 とは
    // 別種の、実質的に宙ぶらりんな参照(そこに GameObject はいない)。
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
    // コンポーネント 999 は unchanged で畳まれ、7 は消えずに loose へ。
    try testing.expectEqual(@as(usize, 1), res.loose.len);
    try testing.expectEqual(@as(i64, 7), res.loose[0].file_id);
    try testing.expectEqual(model.Status.modified, res.loose[0].status);
}

test "tree: component of a stripped GameObject attaches to the owning prefab instance" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // prefab インスタンスが配置した GameObject に追加されたコンポーネント:
    // インスタンスの root GameObject は外側ドキュメントでは stripped で、
    // 実体の MonoBehaviour doc が m_GameObject でそれを指す。
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
    // stripped GameObject の m_PrefabInstance が解決不能な先(存在しない
    // fileID 9999)を指す: それでもコンポーネントを消してはならない。
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
    // 橋渡し先の stripped な入れ子 PrefabInstance が自身の m_PrefabInstance
    // 参照を持たないケース: 外側インスタンスへのチェーンが切れているので、
    // コンポーネントは消えるのではなく loose に落ちる。
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
    // 外側インスタンスは unchanged なので通常どおり刈られ、コンポーネントは見え続ける。
    try testing.expectEqual(@as(usize, 0), res.roots.len);
    try testing.expectEqual(@as(usize, 1), res.loose.len);
    try testing.expectEqual(@as(i64, 3), res.loose[0].file_id);
    try testing.expectEqual(model.Status.modified, res.loose[0].status);
}

test "tree: component of a nested stripped chain attaches to the outer prefab instance" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // 入れ子インスタンス内の GameObject に追加されたコンポーネント: 内側の
    // PrefabInstance は外側ドキュメントでは stripped で、外側インスタンスへの
    // m_PrefabInstance 参照を自身が持つ。このチェーンを辿って、loose に落とす
    // のではなく外側の(実体化される)インスタンスノードに付け替える。
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
    // 壊れたファイル: stripped な PrefabInstance 2 つが互いを参照する。
    // hop 上限が循環を断ち切り、コンポーネントは loose の床を維持する。
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
    // 実体の PrefabInstance の m_TransformParent が、stripped な入れ子
    // インスタンスに属する stripped Transform を指すケース: チェーンを外側の
    // 実体インスタンスまで辿り、子を root に平坦化しない。
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
