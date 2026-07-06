const std = @import("std");

// 外部または内部への参照: `{fileID: N}` または `{fileID: N, guid: ..., type: N}`。
pub const Ref = struct {
    file_id: i64,
    guid: ?[]const u8 = null,
    type_id: ?i64 = null,
};

pub const Entry = struct {
    key: []const u8, // 入力バッファへのスライス
    value: *Node,
};

// パース済み Unity YAML の値。scalar/key/guid は入力バッファへのスライス。
pub const Node = union(enum) {
    map: []Entry,
    seq: []*Node,
    scalar: []const u8,
    ref: Ref,

    pub fn eql(a: *const Node, b: *const Node) bool {
        if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
        return switch (a.*) {
            .scalar => |sa| std.mem.eql(u8, sa, b.scalar),
            .ref => |ra| blk: {
                const rb = b.ref;
                if (ra.file_id != rb.file_id) break :blk false;
                if (ra.type_id != rb.type_id) break :blk false;
                break :blk strEqOpt(ra.guid, rb.guid);
            },
            .seq => |sa| blk: {
                const sb = b.seq;
                if (sa.len != sb.len) break :blk false;
                for (sa, sb) |ea, eb| if (!eql(ea, eb)) break :blk false;
                break :blk true;
            },
            .map => |ma| blk: {
                const mb = b.map;
                if (ma.len != mb.len) break :blk false;
                for (ma) |entry| {
                    const other = findValue(mb, entry.key) orelse break :blk false;
                    if (!eql(entry.value, other)) break :blk false;
                }
                break :blk true;
            },
        };
    }
};

fn strEqOpt(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

// map のエントリからキーで値を引く(線形探索。Unity の map は小さい)。
pub fn findValue(entries: []const Entry, key: []const u8) ?*Node {
    for (entries) |e| if (std.mem.eql(u8, e.key, key)) return e.value;
    return null;
}

// Unity の 1 ドキュメント: `--- !u!<class_id> &<file_id>` + 本体の mapping。
pub const Document = struct {
    class_id: u32,
    file_id: i64,
    type_name: []const u8, // 唯一のトップレベルキー("GameObject" 等)
    stripped: bool = false,
    body: *Node, // ドキュメントのフィールドを持つ .map ノード
};

pub const Status = enum { added, removed, modified, unchanged };

pub const ObjectKind = enum { game_object, prefab_instance };

// PrefabInstance の (target, propertyPath) 単位の override diff。
pub const OverrideDiff = struct {
    group: []const u8, // "Transform" | "GameObject" | "Overrides"
    label: []const u8, // humanize 済み ("Position.x")
    status: Status,
    before: ?*const Node = null,
    after: ?*const Node = null,
};

pub const FieldDiff = struct {
    path: []const u8, // ドット/添字区切りのパス(arena 上に構築)
    status: Status,
    before: ?*const Node = null,
    after: ?*const Node = null,
};

pub const ComponentDiff = struct {
    file_id: i64,
    class_id: u32,
    type_name: []const u8,
    script_guid: ?[]const u8 = null,
    // m_EditorClassIdentifier 末尾のクラス名 ("Cylinder1")。guid 解決の第 2 候補。
    class_name: ?[]const u8 = null,
    status: Status,
    fields: []FieldDiff,
};

pub const ObjectDiff = struct {
    kind: ObjectKind = .game_object,
    file_id: i64,
    name: []const u8,
    status: Status,
    // prefab_instance のみ: m_SourcePrefab の guid。
    source_guid: ?[]const u8 = null,
    // prefab_instance のみ: (target, propertyPath) キーの override diff。
    overrides: []OverrideDiff = &.{},
    components: []ComponentDiff,
    children: []ObjectDiff,
};

pub const DiffResult = struct {
    roots: []ObjectDiff,
    loose: []ComponentDiff,
    unresolved_guids: [][]const u8,
};

test "Node.eql: scalars, refs, seqs, maps" {
    // スカラー
    var s1 = Node{ .scalar = "100" };
    var s2 = Node{ .scalar = "100" };
    var s3 = Node{ .scalar = "150" };
    try std.testing.expect(Node.eql(&s1, &s2));
    try std.testing.expect(!Node.eql(&s1, &s3));

    // 参照
    var r1 = Node{ .ref = .{ .file_id = 234, .guid = "abc", .type_id = 3 } };
    var r2 = Node{ .ref = .{ .file_id = 234, .guid = "abc", .type_id = 3 } };
    var r3 = Node{ .ref = .{ .file_id = 234, .guid = "xyz", .type_id = 3 } };
    try std.testing.expect(Node.eql(&r1, &r2));
    try std.testing.expect(!Node.eql(&r1, &r3));

    // 種別が異なるノードは常に不等
    try std.testing.expect(!Node.eql(&s1, &r1));

    // シーケンス(順序込みで比較)
    var seq_a = [_]*Node{ &s1, &s3 };
    var seq_b = [_]*Node{ &s2, &s3 };
    var q1 = Node{ .seq = &seq_a };
    var q2 = Node{ .seq = &seq_b };
    try std.testing.expect(Node.eql(&q1, &q2));

    // マップ(キー順序は不問)
    var e_a = [_]Entry{ .{ .key = "x", .value = &s1 }, .{ .key = "y", .value = &s3 } };
    var e_b = [_]Entry{ .{ .key = "y", .value = &s3 }, .{ .key = "x", .value = &s2 } };
    var m1 = Node{ .map = &e_a };
    var m2 = Node{ .map = &e_b };
    try std.testing.expect(Node.eql(&m1, &m2));
}
