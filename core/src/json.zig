const std = @import("std");
const model = @import("model.zig");
const root = @import("root.zig");
const testing = std.testing;

const Node = model.Node;
const Status = model.Status;

pub const Resolver = std.StringHashMap([]const u8);

pub fn serialize(arena: std.mem.Allocator, res: model.DiffResult, resolved: ?*const Resolver) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;

    try w.writeAll("{\"schema\":\"prefablens.diff.v2\"");

    try w.writeAll(",\"unresolvedGuids\":[");
    for (res.unresolved_guids, 0..) |g, i| {
        if (i != 0) try w.writeByte(',');
        try writeJsonString(w, g);
    }
    try w.writeByte(']');

    // ホストに内容取得を求めるソースプレハブ。空なら省略(additive な拡張)。
    if (res.needed_sources.len != 0) {
        try w.writeAll(",\"neededSources\":[");
        for (res.needed_sources, 0..) |ns, i| {
            if (i != 0) try w.writeByte(',');
            try w.writeAll("{\"guid\":");
            try writeJsonString(w, ns.guid);
            try w.print(",\"side\":\"{s}\"}}", .{@tagName(ns.side)});
        }
        try w.writeByte(']');
    }

    if (resolved) |r| {
        // diff が実際に参照した guid だけに絞る(プロジェクト index 全体を
        // 出さない)。順序は unresolvedGuids と同じで決定的。
        try w.writeAll(",\"resolved\":{");
        var first = true;
        for (res.unresolved_guids) |g| {
            const path = r.get(g) orelse continue;
            if (!first) try w.writeByte(',');
            first = false;
            try writeJsonString(w, g);
            try w.writeByte(':');
            try writeJsonString(w, path);
        }
        try w.writeByte('}');
    }

    try w.writeAll(",\"roots\":[");
    for (res.roots, 0..) |o, i| {
        if (i != 0) try w.writeByte(',');
        try writeObject(w, o, resolved);
    }
    try w.writeAll("],\"loose\":[");
    for (res.loose, 0..) |c, i| {
        if (i != 0) try w.writeByte(',');
        try writeComponent(w, c, resolved);
    }
    try w.writeAll("]}");

    return aw.toOwnedSlice();
}

fn writeObject(w: *std.Io.Writer, o: model.ObjectDiff, resolved: ?*const Resolver) !void {
    const kind = switch (o.kind) {
        .game_object => "gameObject",
        .prefab_instance => "prefabInstance",
    };
    try w.print("{{\"kind\":\"{s}\",\"fileId\":", .{kind});
    try writeI64String(w, o.file_id);
    try w.writeAll(",\"name\":");
    try writeJsonString(w, o.name);
    try w.writeAll(",\"status\":");
    try writeStatus(w, o.status);
    if (o.kind == .prefab_instance) {
        try w.writeAll(",\"sourceGuid\":");
        if (o.source_guid) |g| try writeJsonString(w, g) else try w.writeAll("null");
        try w.writeAll(",\"overrides\":[");
        for (o.overrides, 0..) |ov, i| {
            if (i != 0) try w.writeByte(',');
            try writeOverride(w, ov);
        }
        try w.writeByte(']');
    }
    try w.writeAll(",\"components\":[");
    for (o.components, 0..) |c, i| {
        if (i != 0) try w.writeByte(',');
        try writeComponent(w, c, resolved);
    }
    try w.writeAll("],\"children\":[");
    for (o.children, 0..) |child, i| {
        if (i != 0) try w.writeByte(',');
        try writeObject(w, child, resolved);
    }
    try w.writeAll("]}");
}

fn writeOverride(w: *std.Io.Writer, ov: model.OverrideDiff) !void {
    try w.writeAll("{\"group\":");
    try writeJsonString(w, ov.group);
    try w.writeAll(",\"label\":");
    try writeJsonString(w, ov.label);
    try w.writeAll(",\"status\":");
    try writeStatus(w, ov.status);
    try w.writeAll(",\"before\":");
    try writeValue(w, ov.before);
    try w.writeAll(",\"after\":");
    try writeValue(w, ov.after);
    try w.writeByte('}');
}

fn writeComponent(w: *std.Io.Writer, c: model.ComponentDiff, resolved: ?*const Resolver) !void {
    try w.writeAll("{\"kind\":\"component\",\"fileId\":");
    try writeI64String(w, c.file_id);
    try w.print(",\"classId\":{d},\"typeName\":", .{c.class_id});
    try writeJsonString(w, c.type_name);
    try w.writeAll(",\"scriptGuid\":");
    if (c.script_guid) |g| try writeJsonString(w, g) else try w.writeAll("null");
    try w.writeAll(",\"className\":");
    if (c.class_name) |n| try writeJsonString(w, n) else try w.writeAll("null");
    if (resolved) |r| {
        if (c.script_guid) |g| {
            if (r.get(g)) |path| {
                try w.writeAll(",\"scriptName\":");
                try writeJsonString(w, path);
            }
        }
    }
    try w.writeAll(",\"status\":");
    try writeStatus(w, c.status);
    try w.writeAll(",\"fields\":[");
    for (c.fields, 0..) |f, i| {
        if (i != 0) try w.writeByte(',');
        try writeField(w, f);
    }
    try w.writeAll("]}");
}

fn writeField(w: *std.Io.Writer, f: model.FieldDiff) !void {
    try w.writeAll("{\"path\":");
    try writeJsonString(w, f.path);
    try w.writeAll(",\"status\":");
    try writeStatus(w, f.status);
    try w.writeAll(",\"before\":");
    try writeValue(w, f.before);
    try w.writeAll(",\"after\":");
    try writeValue(w, f.after);
    try w.writeByte('}');
}

fn writeValue(w: *std.Io.Writer, node: ?*const Node) !void {
    const n = node orelse {
        try w.writeAll("null");
        return;
    };
    switch (n.*) {
        .scalar => |s| try writeJsonString(w, s),
        .ref => |r| {
            try w.writeAll("{\"ref\":{\"fileId\":");
            try writeI64String(w, r.file_id);
            try w.writeAll(",\"guid\":");
            if (r.guid) |g| try writeJsonString(w, g) else try w.writeAll("null");
            try w.writeAll(",\"type\":");
            if (r.type_id) |t| try w.print("{d}", .{t}) else try w.writeAll("null");
            try w.writeAll("}}");
        },
        // map/seq が leaf に来るのは稀(通常は再帰される)。コンパクトに表現する。
        .map => try w.writeAll("\"<map>\""),
        .seq => try w.writeAll("\"<seq>\""),
    }
}

fn writeStatus(w: *std.Io.Writer, s: Status) !void {
    const text = switch (s) {
        .added => "\"added\"",
        .removed => "\"removed\"",
        .modified => "\"modified\"",
        .unchanged => "\"unchanged\"",
    };
    try w.writeAll(text);
}

fn writeI64String(w: *std.Io.Writer, v: i64) !void {
    try w.print("\"{d}\"", .{v});
}

pub fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

test "json: v2 prefab instance node with overrides" {
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
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalScale.y
        \\      value: 2
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    const out = try root.diffToJson(arena, "", after);
    try testing.expect(std.mem.indexOf(u8, out, "\"schema\":\"prefablens.diff.v2\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"prefabInstance\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"name\":\"Cylinder Variant\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"sourceGuid\":\"aaa\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"overrides\":[{\"group\":\"Transform\",\"label\":\"Scale.y\",\"status\":\"added\",\"before\":null,\"after\":\"2\"}]") != null);
}

test "json: needed sources are emitted only when unresolved" {
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
    // assets 未供給: ホストへの取得要求として neededSources が載る。
    const out = try root.diffToJson(arena, "", after);
    try testing.expect(std.mem.indexOf(u8, out, "\"neededSources\":[{\"guid\":\"aaa\",\"side\":\"after\"}]") != null);

    // 供給済み: 展開されて neededSources は emit されない(空なら省略)。
    var assets: root.Assets = .empty;
    try assets.put(arena, "aaa", "--- !u!1 &10\nGameObject:\n  m_Name: Src\n");
    const merged = try root.diffToJsonWithAssets(arena, "", after, &assets);
    try testing.expect(std.mem.indexOf(u8, merged, "neededSources") == null);
}

test "json: v2 root node shape matches golden" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: Plane
        \\  m_Component:
        \\  - component: {fileID: 4}
        \\  - component: {fileID: 5}
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_GameObject: {fileID: 1}
        \\  m_Script: {fileID: 0, guid: def, type: 3}
        \\  hp: 1
    ;
    const after =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: Plane
        \\  m_Component:
        \\  - component: {fileID: 4}
        \\  - component: {fileID: 5}
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_GameObject: {fileID: 1}
        \\  m_Script: {fileID: 0, guid: def, type: 3}
        \\  hp: 2
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_TransformParent: {fileID: 4}
        \\    m_Modifications:
        \\    - target: {fileID: 8, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: Cylinder
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalScale.y
        \\      value: 2
        \\    m_AddedComponents:
        \\    - targetCorrespondingSourceObject: {fileID: 8, guid: aaa, type: 3}
        \\      addedObject: {fileID: 9}
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    const out = try root.diffToJson(arena, before, after);
    // roots 側のノード全形状 (gameObject + components + 子 prefabInstance +
    // overrides + 構造サマリ) を byte-for-byte で固定する回帰ピン。
    const golden =
        \\{"schema":"prefablens.diff.v2","unresolvedGuids":["def","aaa"],"neededSources":[{"guid":"aaa","side":"after"}],"roots":[{"kind":"gameObject","fileId":"1","name":"Plane","status":"unchanged","components":[{"kind":"component","fileId":"5","classId":114,"typeName":"MonoBehaviour","scriptGuid":"def","className":null,"status":"modified","fields":[{"path":"Hp","status":"modified","before":"1","after":"2"}]}],"children":[{"kind":"prefabInstance","fileId":"1001","name":"Cylinder","status":"added","sourceGuid":"aaa","overrides":[{"group":"Transform","label":"Scale.y","status":"added","before":null,"after":"2"},{"group":"Overrides","label":"Added Components (1)","status":"added","before":null,"after":null}],"components":[],"children":[]}]}],"loose":[]}
    ;
    try testing.expectEqualStrings(golden, out);
}

test "json: component carries className" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_EditorClassIdentifier: Assembly-CSharp::Cylinder1
        \\  hp: 1
    ;
    const after =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_EditorClassIdentifier: Assembly-CSharp::Cylinder1
        \\  hp: 2
    ;
    const out = try root.diffToJson(arena, before, after);
    try testing.expect(std.mem.indexOf(u8, out, "\"className\":\"Cylinder1\"") != null);
}

test "json: modified loose component matches golden" {
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
    const out = try root.diffToJson(arena, before, after);
    const golden =
        \\{"schema":"prefablens.diff.v2","unresolvedGuids":["def"],"roots":[],"loose":[{"kind":"component","fileId":"11400000","classId":114,"typeName":"MonoBehaviour","scriptGuid":"def","className":null,"status":"modified","fields":[{"path":"Volume","status":"modified","before":"0.5","after":"0.8"}]}]}
    ;
    try testing.expectEqualStrings(golden, out);
}

test "json: fileId is a string, ref value serialized as object" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_Target: {fileID: 100}
    ;
    const after =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_Target: {fileID: 200}
    ;
    const out = try root.diffToJson(arena, before, after);
    try testing.expect(std.mem.indexOf(u8, out, "\"fileId\":\"5\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"after\":{\"ref\":{\"fileId\":\"200\",\"guid\":null,\"type\":null}}") != null);
}

test "json: resolved is scoped to referenced guids, ordered like unresolvedGuids" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 2 つの .meta から構築したプロジェクト index。guidA と guidC はどちらも
    // 解決可能だが、diff が参照するのは guidA のみ。
    var resolver = Resolver.init(arena);
    try resolver.put("guidA", "Assets/Scripts/A.cs");
    try resolver.put("guidC", "Assets/Scripts/C.cs");

    var unresolved_guids = [_][]const u8{"guidA"};
    const res: model.DiffResult = .{
        .roots = &.{},
        .loose = &.{},
        .unresolved_guids = &unresolved_guids,
    };

    const out = try serialize(arena, res, &resolver);
    // "resolved" には参照された guid だけが載り、
    try testing.expect(std.mem.indexOf(u8, out, "\"resolved\":{\"guidA\":\"Assets/Scripts/A.cs\"}") != null);
    // 参照されていない guidC は解決可能でも出力に漏れない。
    try testing.expect(std.mem.indexOf(u8, out, "guidC") == null);
}

test "json: resolved follows unresolvedGuids order, skipping guids the resolver can't find" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var resolver = Resolver.init(arena);
    try resolver.put("guidA", "Assets/Scripts/A.cs");
    try resolver.put("guidB", "Assets/Scripts/B.cs");

    // 参照順は B, A。guidX は参照されているがプロジェクト index に存在しない。
    var unresolved_guids = [_][]const u8{ "guidB", "guidA", "guidX" };
    const res: model.DiffResult = .{
        .roots = &.{},
        .loose = &.{},
        .unresolved_guids = &unresolved_guids,
    };

    const out = try serialize(arena, res, &resolver);
    try testing.expect(std.mem.indexOf(u8, out, "\"resolved\":{\"guidB\":\"Assets/Scripts/B.cs\",\"guidA\":\"Assets/Scripts/A.cs\"}") != null);
    try testing.expect(std.mem.indexOf(u8, out, "guidX\":") == null);
    // guidX は unresolved のまま残る。
    try testing.expect(std.mem.indexOf(u8, out, "\"unresolvedGuids\":[\"guidB\",\"guidA\",\"guidX\"]") != null);
}

test "json: control characters are escaped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var aw: std.Io.Writer.Allocating = .init(arena);
    // 名前つきエスケープ(\n 等)はそれを、その他の制御文字は \u00XX を使う。
    try writeJsonString(&aw.writer, "a\nb\x01c");
    try testing.expectEqualStrings("\"a\\nb\\u0001c\"", aw.written());
}

test "json: string escaping" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: a
    ;
    const after =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: "a\"b"
    ;
    const out = try root.diffToJson(arena, before, after);
    // 値の中の引用符は JSON 出力でエスケープされる。
    try testing.expect(std.mem.indexOf(u8, out, "a\\\"b") != null);
}
