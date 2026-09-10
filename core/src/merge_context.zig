const std = @import("std");

pub const Kind = enum { ordered, int32_array, dictionary };
pub const Field = struct {
    path: []const u8,
    kind: Kind,
    pub fn sameType(self: Field, other: Field) bool {
        return self.kind == other.kind;
    }
};
pub const Script = struct {
    guid: []const u8,
    fields: []const Field,
};

// Each snapshot belongs to one immutable revision so array types follow the
// source used by that side of the merge.
pub const Snapshot = struct {
    revision: []const u8 = "",
    scripts: []const Script = &.{},

    pub fn kind(self: Snapshot, script_guid: []const u8, path: []const u8) ?Kind {
        const descriptor = self.field(script_guid, path) orelse return null;
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
        .{ .guid = "guid", .fields = &.{.{ .path = "values", .kind = .int32_array }} },
        .{ .guid = "guid", .fields = &.{} },
    } };
    try std.testing.expectEqual(null, snapshot.kind("guid", "values"));
}
