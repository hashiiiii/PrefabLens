const std = @import("std");
pub const model = @import("model.zig");
pub const classid = @import("classid.zig");
pub const parser = @import("parser.zig");
pub const diff = @import("diff.zig");
pub const tree = @import("tree.zig");
pub const json = @import("json.zig");
pub const inspector = @import("inspector.zig");
pub const perf = @import("perf.zig");

pub fn diffBytes(arena: std.mem.Allocator, before_src: []const u8, after_src: []const u8) !model.DiffResult {
    const fd = try diff.compute(arena, before_src, after_src);
    return tree.build(arena, fd);
}

pub fn diffToJson(arena: std.mem.Allocator, before_src: []const u8, after_src: []const u8) ![]u8 {
    const res = try diffBytes(arena, before_src, after_src);
    return json.serialize(arena, res, null);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("fixture_test.zig");
}
