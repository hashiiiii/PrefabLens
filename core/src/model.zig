const std = @import("std");

// External or internal reference: `{fileID: N}` or `{fileID: N, guid: ..., type: N}`.
pub const Ref = struct {
    file_id: i64,
    guid: ?[]const u8 = null,
    type_id: ?i64 = null,
};

pub const Entry = struct {
    key: []const u8, // slice into the input buffer
    value: *Node,
};

// A parsed Unity YAML value. scalar/key/guid are slices into the input buffer.
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

// Look up a value by key in a map's entries (linear scan; Unity maps are small).
pub fn findValue(entries: []const Entry, key: []const u8) ?*Node {
    for (entries) |e| if (std.mem.eql(u8, e.key, key)) return e.value;
    return null;
}

// One Unity document: `--- !u!<class_id> &<file_id>` + the body mapping.
pub const Document = struct {
    class_id: u32,
    file_id: i64,
    type_name: []const u8, // the sole top-level key ("GameObject" etc.)
    stripped: bool = false,
    body: *Node, // the .map node holding the document's fields
};

pub const Status = enum { added, removed, modified, unchanged };

pub const ObjectKind = enum { game_object, prefab_instance };

// Per-(target, propertyPath) override diff for a PrefabInstance.
pub const OverrideDiff = struct {
    group: []const u8, // "Transform" | "GameObject" | "Overrides"
    label: []const u8, // humanized ("Position.x")
    status: Status,
    before: ?*const Node = null,
    after: ?*const Node = null,
};

pub const FieldDiff = struct {
    path: []const u8, // dot/index-separated path (built on the arena)
    status: Status,
    before: ?*const Node = null,
    after: ?*const Node = null,
};

pub const ComponentDiff = struct {
    file_id: i64,
    class_id: u32,
    type_name: []const u8,
    script_guid: ?[]const u8 = null,
    // Class name at the tail of m_EditorClassIdentifier ("Cylinder1"). Second candidate for guid resolution.
    class_name: ?[]const u8 = null,
    status: Status,
    fields: []FieldDiff,
};

pub const ObjectDiff = struct {
    kind: ObjectKind = .game_object,
    file_id: i64,
    name: []const u8,
    status: Status,
    // prefab_instance only: the m_SourcePrefab guid.
    source_guid: ?[]const u8 = null,
    // prefab_instance only: override diff keyed by (target, propertyPath).
    overrides: []OverrideDiff = &.{},
    components: []ComponentDiff,
    children: []ObjectDiff,
};

// A source prefab whose content the host is asked to supply. side is the ref to fetch
// (added instance -> after/head, removed instance -> before/base).
pub const SourceSide = enum { before, after };
pub const NeededSource = struct { guid: []const u8, side: SourceSide };

pub const DiffResult = struct {
    roots: []ObjectDiff,
    loose: []ComponentDiff,
    unresolved_guids: [][]const u8,
    needed_sources: []NeededSource = &.{},
};

test "Node.eql: scalars, refs, seqs, maps" {
    // scalars
    var s1 = Node{ .scalar = "100" };
    var s2 = Node{ .scalar = "100" };
    var s3 = Node{ .scalar = "150" };
    try std.testing.expect(Node.eql(&s1, &s2));
    try std.testing.expect(!Node.eql(&s1, &s3));

    // refs
    var r1 = Node{ .ref = .{ .file_id = 234, .guid = "abc", .type_id = 3 } };
    var r2 = Node{ .ref = .{ .file_id = 234, .guid = "abc", .type_id = 3 } };
    var r3 = Node{ .ref = .{ .file_id = 234, .guid = "xyz", .type_id = 3 } };
    try std.testing.expect(Node.eql(&r1, &r2));
    try std.testing.expect(!Node.eql(&r1, &r3));

    // nodes of different kinds are always unequal
    try std.testing.expect(!Node.eql(&s1, &r1));

    // sequences (compared with order)
    var seq_a = [_]*Node{ &s1, &s3 };
    var seq_b = [_]*Node{ &s2, &s3 };
    var q1 = Node{ .seq = &seq_a };
    var q2 = Node{ .seq = &seq_b };
    try std.testing.expect(Node.eql(&q1, &q2));

    // maps (key order irrelevant)
    var e_a = [_]Entry{ .{ .key = "x", .value = &s1 }, .{ .key = "y", .value = &s3 } };
    var e_b = [_]Entry{ .{ .key = "y", .value = &s3 }, .{ .key = "x", .value = &s2 } };
    var m1 = Node{ .map = &e_a };
    var m2 = Node{ .map = &e_b };
    try std.testing.expect(Node.eql(&m1, &m2));

    // maps with the same count but different key sets are unequal.
    var e_c = [_]Entry{ .{ .key = "x", .value = &s1 }, .{ .key = "z", .value = &s3 } };
    var m3 = Node{ .map = &e_c };
    try std.testing.expect(!Node.eql(&m1, &m3));
}
