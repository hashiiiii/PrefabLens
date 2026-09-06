const std = @import("std");

pub const Kind = enum { ordered, int32_array, string_dictionary, int32_dictionary };
pub const ValueType = enum { int32, string };
pub const DictionaryEquality = enum { unknown, default };
pub const Field = struct {
    path: []const u8,
    kind: Kind,
    dictionary_value: ?ValueType = null,
    dictionary_equality: DictionaryEquality = .unknown,

    // Unknown dictionary values never prove schema compatibility. The initial
    // acquisition subset is string -> int and int -> string; keep explicit
    // evidence so future supported values cannot silently change the schema.
    pub fn sameType(self: Field, other: Field) bool {
        if (self.kind != other.kind) return false;
        if (self.kind == .string_dictionary or self.kind == .int32_dictionary) {
            return self.dictionary_value != null and self.dictionary_value == other.dictionary_value;
        }
        return true;
    }
};
pub const Script = struct {
    guid: []const u8,
    class_name: []const u8,
    source_hash: []const u8,
    fields: []const Field,
};
pub const Asset = struct { guid: []const u8, path: []const u8, bytes: []const u8 };

// Each snapshot belongs to one immutable revision. An output snapshot can also
// contain explicitly selected source results from the current merge session.
pub const Snapshot = struct {
    revision: []const u8 = "",
    assets: []const Asset = &.{},
    scripts: []const Script = &.{},

    pub fn asset(self: Snapshot, guid: []const u8) ?Asset {
        var found: ?Asset = null;
        for (self.assets) |candidate| {
            if (!std.mem.eql(u8, candidate.guid, guid)) continue;
            if (found != null) return null;
            found = candidate;
        }
        return found;
    }

    pub fn kind(self: Snapshot, script_guid: []const u8, path: []const u8) ?Kind {
        const descriptor = self.field(script_guid, path) orelse return null;
        if ((descriptor.kind == .string_dictionary or descriptor.kind == .int32_dictionary) and
            (descriptor.dictionary_value == null or descriptor.dictionary_equality != .default)) return null;
        return descriptor.kind;
    }

    pub fn field(self: Snapshot, script_guid: []const u8, path: []const u8) ?Field {
        var found: ?Field = null;
        var script_found = false;
        for (self.scripts) |script| {
            if (!std.mem.eql(u8, script.guid, script_guid)) continue;
            if (script_found) return null;
            script_found = true;
            for (script.fields) |descriptor| {
                if (!std.mem.eql(u8, descriptor.path, path)) continue;
                if (found != null) return null;
                found = descriptor;
            }
        }
        return found;
    }
};

pub const Context = struct {
    base: Snapshot = .{},
    ours: Snapshot = .{},
    theirs: Snapshot = .{},
    output: Snapshot = .{},
};

test "duplicate script GUID with unknown fields cannot authorize a kind" {
    const snapshot: Snapshot = .{ .scripts = &.{
        .{ .guid = "guid", .class_name = "One", .source_hash = "a", .fields = &.{.{ .path = "values", .kind = .int32_array }} },
        .{ .guid = "guid", .class_name = "Two", .source_hash = "b", .fields = &.{} },
    } };
    try std.testing.expectEqual(null, snapshot.kind("guid", "values"));
}

test "field type evidence distinguishes dictionary values independently of key kind" {
    const before: Field = .{ .path = "values", .kind = .string_dictionary, .dictionary_value = .int32 };
    const after: Field = .{ .path = "values", .kind = .string_dictionary, .dictionary_value = .string };
    try std.testing.expect(!before.sameType(after));
    try std.testing.expect(before.sameType(before));
    const snapshot: Snapshot = .{ .scripts = &.{.{ .guid = "guid", .class_name = "Example", .source_hash = "oid", .fields = &.{before} }} };
    try std.testing.expectEqual(ValueType.int32, snapshot.field("guid", "values").?.dictionary_value.?);
}

test "unknown dictionary equality retains type evidence without authorizing keyed merge" {
    const declared: Field = .{ .path = "values", .kind = .string_dictionary, .dictionary_value = .int32, .dictionary_equality = .unknown };
    var safe = declared;
    safe.dictionary_equality = .default;
    try std.testing.expect(declared.sameType(safe));
    const snapshot: Snapshot = .{ .scripts = &.{.{ .guid = "guid", .class_name = "Example", .source_hash = "oid", .fields = &.{declared} }} };
    try std.testing.expectEqual(null, snapshot.kind("guid", "values"));
    try std.testing.expectEqual(ValueType.int32, snapshot.field("guid", "values").?.dictionary_value.?);
    try std.testing.expectEqual(DictionaryEquality.unknown, snapshot.field("guid", "values").?.dictionary_equality);
}
