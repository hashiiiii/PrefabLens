// PrefabInstance のソースプレハブ合成(親 spec: docs/superpowers/specs/2026-07-06-prefab-source-resolution-design.md)。
// 合成 = ソースを parse -> m_Modifications を Document に適用 -> 既存の片側
// compute + tree.build を再利用 -> instance ノードへ接ぎ木。core は I/O を持たず、
// ホストが guid -> bytes(Assets)を供給する。供給が無い guid は needed_sources に載る。
const std = @import("std");
const model = @import("model.zig");
const parser = @import("parser.zig");
const diffmod = @import("diff.zig");
const tree = @import("tree.zig");

pub const Assets = std.StringHashMapUnmanaged([]const u8);

// 入れ子展開の深さ上限(tree.zig の max_instance_hops と同じ思想)。
const max_depth = 8;

const Ctx = struct {
    arena: std.mem.Allocator,
    assets: *const Assets,
    // 供給が必要な guid -> side(初出順を保ち decisions を決定的にする)。
    needed: std.StringArrayHashMapUnmanaged(model.SourceSide) = .empty,
    // 参照済み guid の全体集合(unresolvedGuids へのマージ用、初出順)。
    guids: std.StringArrayHashMapUnmanaged(void) = .empty,
    // 祖先チェーンの guid(循環ガード)。兄弟同士での同一ソース再利用は許す。
    chain: std.ArrayList([]const u8) = .empty,
};

pub fn expand(arena: std.mem.Allocator, res: *model.DiffResult, fd: diffmod.FlatDiff, assets: *const Assets) !void {
    var ctx = Ctx{ .arena = arena, .assets = assets };
    // ソース由来の外部参照(script/material 等)もホスト解決の対象に
    // 含めるため、トップレベルの unresolvedGuids へマージしていく。
    for (res.unresolved_guids) |g| try ctx.guids.put(arena, g, {});

    var docs = std.AutoHashMap(i64, *model.Document).init(arena);
    // sole-status instance の生 doc(m_Modifications 読取り用)。added は after、
    // removed は before 側にしか存在しないので、両方入れれば片側が引ける。
    for (fd.before) |*d| try docs.put(d.file_id, d);
    for (fd.after) |*d| try docs.put(d.file_id, d);

    for (res.roots) |*node| try expandNode(&ctx, node, &docs, 0);

    res.unresolved_guids = ctx.guids.keys();
    res.needed_sources = try neededSlice(&ctx);
}

fn neededSlice(ctx: *Ctx) ![]model.NeededSource {
    var out: std.ArrayList(model.NeededSource) = .empty;
    var it = ctx.needed.iterator();
    while (it.next()) |e| try out.append(ctx.arena, .{ .guid = e.key_ptr.*, .side = e.value_ptr.* });
    return out.toOwnedSlice(ctx.arena);
}

fn expandNode(ctx: *Ctx, node: *model.ObjectDiff, docs: *std.AutoHashMap(i64, *model.Document), depth: usize) !void {
    for (node.children) |*child| try expandNode(ctx, child, docs, depth);
    if (node.kind != .prefab_instance) return;
    if (node.status != .added and node.status != .removed) return;
    const guid = node.source_guid orelse return;
    if (depth >= max_depth or inChain(ctx, guid)) return;
    const side: model.SourceSide = if (node.status == .added) .after else .before;
    const bytes = ctx.assets.get(guid) orelse {
        try ctx.needed.put(ctx.arena, guid, side);
        return;
    };
    const inst_doc = docs.get(node.file_id) orelse return;

    // ソースを parse し、この instance の m_RemovedComponents / m_Modifications を適用。
    const src_docs = try parser.parse(ctx.arena, bytes);
    applyRemovedComponents(inst_doc, src_docs);
    applyModifications(inst_doc, src_docs, guid);

    // 片側 diff として全列挙し、既存パイプラインで ObjectDiff 化する。
    const none = try parser.parse(ctx.arena, "");
    const sub_fd = if (node.status == .added)
        try diffmod.computeParsed(ctx.arena, none, src_docs)
    else
        try diffmod.computeParsed(ctx.arena, src_docs, none);
    const sub = try tree.build(ctx.arena, sub_fd);
    for (sub_fd.unresolved_guids) |g| try ctx.guids.put(ctx.arena, g, {});

    // 入れ子 instance を再帰展開(祖先チェーンに自分の guid を積む)。
    try ctx.chain.append(ctx.arena, guid);
    defer _ = ctx.chain.pop();
    var sub_docs = std.AutoHashMap(i64, *model.Document).init(ctx.arena);
    for (sub_fd.before) |*d| try sub_docs.put(d.file_id, d);
    for (sub_fd.after) |*d| try sub_docs.put(d.file_id, d);
    for (sub.roots) |*r| try expandNode(ctx, r, &sub_docs, depth + 1);

    // 接ぎ木: 単一 GameObject root ならその中身を instance ノードへ持ち上げる
    // (Unity の hierarchy 表示と同じ: instance = ソース root の合成)。
    if (sub.roots.len == 1 and sub.roots[0].kind == .game_object) {
        node.components = try concatComponents(ctx.arena, node.components, sub.roots[0].components, sub.loose);
        node.children = try concatObjects(ctx.arena, node.children, sub.roots[0].children);
    } else {
        node.components = try concatComponents(ctx.arena, node.components, &.{}, sub.loose);
        node.children = try concatObjects(ctx.arena, node.children, sub.roots);
    }
    node.overrides = &.{}; // 合成値に反映済み
}

fn inChain(ctx: *Ctx, guid: []const u8) bool {
    for (ctx.chain.items) |g| if (std.mem.eql(u8, g, guid)) return true;
    return false;
}

fn concatComponents(arena: std.mem.Allocator, a: []model.ComponentDiff, b: []model.ComponentDiff, c: []model.ComponentDiff) ![]model.ComponentDiff {
    var out: std.ArrayList(model.ComponentDiff) = .empty;
    try out.appendSlice(arena, a);
    try out.appendSlice(arena, b);
    try out.appendSlice(arena, c);
    return out.toOwnedSlice(arena);
}

fn concatObjects(arena: std.mem.Allocator, a: []model.ObjectDiff, b: []model.ObjectDiff) ![]model.ObjectDiff {
    var out: std.ArrayList(model.ObjectDiff) = .empty;
    try out.appendSlice(arena, a);
    try out.appendSlice(arena, b);
    return out.toOwnedSlice(arena);
}

// m_RemovedComponents の参照先(ソース内 fileID)を stripped 扱いで落とす
// (computeParsed が stripped doc を除外する)。
fn applyRemovedComponents(inst_doc: *const model.Document, src_docs: []model.Document) void {
    const m = model.findValue(inst_doc.body.map, "m_Modification") orelse return;
    if (m.* != .map) return;
    const list = model.findValue(m.map, "m_RemovedComponents") orelse return;
    if (list.* != .seq) return;
    for (list.seq) |item| {
        if (item.* != .ref) continue;
        for (src_docs) |*d| {
            if (d.file_id == item.ref.file_id) d.stripped = true;
        }
    }
}

// m_Modifications をソース Document へ適用する。target.guid が source guid の
// もののみ(入れ子ソースのオブジェクトを狙う override はスコープ外)。
fn applyModifications(inst_doc: *const model.Document, src_docs: []model.Document, source_guid: []const u8) void {
    const m = model.findValue(inst_doc.body.map, "m_Modification") orelse return;
    if (m.* != .map) return;
    const list = model.findValue(m.map, "m_Modifications") orelse return;
    if (list.* != .seq) return;
    for (list.seq) |item| {
        if (item.* != .map) continue;
        const pp = model.findValue(item.map, "propertyPath") orelse continue;
        if (pp.* != .scalar) continue;
        const target = model.findValue(item.map, "target") orelse continue;
        if (target.* != .ref) continue;
        const tguid = target.ref.guid orelse continue;
        if (!std.mem.eql(u8, tguid, source_guid)) continue;
        // objectReference が設定されていればそれ、なければ value(diff.zig の modValue と同じ規則)。
        const value = objRefIfSet(model.findValue(item.map, "objectReference")) orelse
            (model.findValue(item.map, "value") orelse continue);
        for (src_docs) |*d| {
            if (d.file_id != target.ref.file_id) continue;
            setByPropertyPath(d.body, pp.scalar, value);
            break;
        }
    }
}

fn objRefIfSet(n: ?*model.Node) ?*model.Node {
    const node = n orelse return null;
    return switch (node.*) {
        .ref => |r| if (r.file_id != 0 or r.guid != null) node else null,
        else => null,
    };
}

// "m_LocalScale.y" / "m_Materials.Array.data[0]" 形式のパスで leaf を差し替える。
// 途中が見つからない・型が合わないパスは黙って捨てる(表示合成なので安全側)。
fn setByPropertyPath(body: *model.Node, path: []const u8, value: *model.Node) void {
    var cur: *model.Node = body;
    var it = std.mem.splitScalar(u8, path, '.');
    var pending: ?[]const u8 = it.next();
    while (pending) |seg| {
        const next = it.next();
        if (std.mem.eql(u8, seg, "Array")) {
            pending = next;
            continue; // Unity の仮想セグメント
        }
        if (std.mem.startsWith(u8, seg, "data[")) {
            const close = std.mem.indexOfScalar(u8, seg, ']') orelse return;
            const idx = std.fmt.parseInt(usize, seg["data[".len..close], 10) catch return;
            if (cur.* != .seq or idx >= cur.seq.len) return;
            if (next == null) {
                cur.seq[idx] = value;
                return;
            }
            cur = cur.seq[idx];
            pending = next;
            continue;
        }
        if (cur.* != .map) return;
        var advanced = false;
        for (cur.map) |*e| {
            if (!std.mem.eql(u8, e.key, seg)) continue;
            if (next == null) {
                e.value = value;
                return;
            }
            cur = e.value;
            advanced = true;
            break;
        }
        if (!advanced) return;
        pending = next;
    }
}

const testing = std.testing;
const root = @import("root.zig");

const test_source =
    \\--- !u!1 &10
    \\GameObject:
    \\  m_Name: Cyl
    \\  m_Component:
    \\  - component: {fileID: 40}
    \\--- !u!4 &40
    \\Transform:
    \\  m_GameObject: {fileID: 10}
    \\  m_LocalScale: {x: 1, y: 1, z: 1}
;

const test_variant =
    \\--- !u!1001 &1001
    \\PrefabInstance:
    \\  m_Modification:
    \\    m_Modifications:
    \\    - target: {fileID: 40, guid: srcguid, type: 3}
    \\      propertyPath: m_LocalScale.y
    \\      value: 2
    \\    - target: {fileID: 10, guid: srcguid, type: 3}
    \\      propertyPath: m_Name
    \\      value: Cyl Variant
    \\  m_SourcePrefab: {fileID: 100100000, guid: srcguid, type: 3}
;

test "instantiate: merged variant shows full source values with overrides applied" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var assets: Assets = .empty;
    try assets.put(arena, "srcguid", test_source);
    const res = try root.diffBytesWithAssets(arena, "", test_variant, &assets);
    try testing.expectEqual(@as(usize, 1), res.roots.len);
    const inst = res.roots[0];
    try testing.expectEqualStrings("Cyl Variant", inst.name);
    // 展開成功: overrides は空、ソースの Transform が component として現れ、
    // override 適用済みの Scale (1, 2, 1) を全列挙で持つ。
    try testing.expectEqual(@as(usize, 0), res.needed_sources.len);
    try testing.expectEqual(@as(usize, 0), inst.overrides.len);
    try testing.expectEqual(@as(usize, 1), inst.components.len);
    const tr = inst.components[0];
    try testing.expectEqual(@as(u32, 4), tr.class_id);
    try testing.expectEqual(model.Status.added, tr.status);
    try testing.expectEqual(@as(usize, 1), tr.fields.len);
    try testing.expectEqualStrings("Scale", tr.fields[0].path);
    try testing.expectEqualStrings("(1, 2, 1)", tr.fields[0].after.?.scalar);
}

test "instantiate: missing asset degrades and reports neededSources with side" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const empty: Assets = .empty;

    // added 方向: 縮退表示(override 全列挙)のまま、side は after。
    const added = try root.diffBytesWithAssets(arena, "", test_variant, &empty);
    try testing.expectEqual(@as(usize, 1), added.needed_sources.len);
    try testing.expectEqualStrings("srcguid", added.needed_sources[0].guid);
    try testing.expectEqual(model.SourceSide.after, added.needed_sources[0].side);
    try testing.expect(added.roots[0].overrides.len != 0);

    // removed 方向: side は before。
    const removed = try root.diffBytesWithAssets(arena, test_variant, "", &empty);
    try testing.expectEqual(@as(usize, 1), removed.needed_sources.len);
    try testing.expectEqual(model.SourceSide.before, removed.needed_sources[0].side);
}

test "instantiate: cyclic source reference terminates" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // ソース自身が同じ guid の PrefabInstance を含む(壊れたデータ)。
    // 祖先チェーンの循環ガードで停止し、needed にも載らないことだけを確認する。
    const cyclic_source =
        \\--- !u!1001 &7
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications: []
        \\  m_SourcePrefab: {fileID: 100100000, guid: loopguid, type: 3}
    ;
    const variant =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications: []
        \\  m_SourcePrefab: {fileID: 100100000, guid: loopguid, type: 3}
    ;
    var assets: Assets = .empty;
    try assets.put(arena, "loopguid", cyclic_source);
    const res = try root.diffBytesWithAssets(arena, "", variant, &assets);
    try testing.expectEqual(@as(usize, 1), res.roots.len);
    try testing.expectEqual(@as(usize, 0), res.needed_sources.len);
}

test "instantiate: removed components are dropped from the merged tree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source =
        \\--- !u!1 &10
        \\GameObject:
        \\  m_Name: Cyl
        \\  m_Component:
        \\  - component: {fileID: 40}
        \\  - component: {fileID: 50}
        \\--- !u!4 &40
        \\Transform:
        \\  m_GameObject: {fileID: 10}
        \\--- !u!65 &50
        \\BoxCollider:
        \\  m_GameObject: {fileID: 10}
        \\  m_IsTrigger: 0
    ;
    const variant =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications: []
        \\    m_RemovedComponents:
        \\    - {fileID: 50, guid: srcguid, type: 3}
        \\  m_SourcePrefab: {fileID: 100100000, guid: srcguid, type: 3}
    ;
    var assets: Assets = .empty;
    try assets.put(arena, "srcguid", source);
    const res = try root.diffBytesWithAssets(arena, "", variant, &assets);
    const inst = res.roots[0];
    // BoxCollider (fileID 50) は除去済み: Transform だけが残る。
    for (inst.components) |c| try testing.expect(c.class_id != 65);
}

test "instantiate: setByPropertyPath handles nested and array paths" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const docs = try parser.parse(arena,
        \\--- !u!23 &5
        \\MeshRenderer:
        \\  m_Materials:
        \\  - {fileID: 2100000, guid: mat0, type: 2}
        \\  - {fileID: 2100000, guid: mat1, type: 2}
        \\  m_LocalScale: {x: 1, y: 1, z: 1}
    );
    var value = model.Node{ .scalar = "9" };

    // ネストしたパス。
    setByPropertyPath(docs[0].body, "m_LocalScale.y", &value);
    const scale = model.findValue(docs[0].body.map, "m_LocalScale").?;
    try testing.expectEqualStrings("9", model.findValue(scale.map, "y").?.scalar);

    // Array.data[i] パス(leaf 差し替え)。
    setByPropertyPath(docs[0].body, "m_Materials.Array.data[1]", &value);
    const mats = model.findValue(docs[0].body.map, "m_Materials").?;
    try testing.expectEqualStrings("9", mats.seq[1].scalar);

    // 不在パスと範囲外 index は no-op(panic しない)。
    setByPropertyPath(docs[0].body, "m_Missing.x", &value);
    setByPropertyPath(docs[0].body, "m_Materials.Array.data[99]", &value);
}
