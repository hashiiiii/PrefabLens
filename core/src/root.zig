//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
pub const model = @import("model.zig");
pub const classid = @import("classid.zig");
pub const parser = @import("parser.zig");
pub const diff = @import("diff.zig");
pub const tree = @import("tree.zig");

pub fn version() []const u8 {
    return "0.1.0-dev";
}

pub fn diffBytes(arena: std.mem.Allocator, before_src: []const u8, after_src: []const u8) !model.DiffResult {
    const fd = try diff.compute(arena, before_src, after_src);
    return tree.build(arena, fd);
}

test "core builds and version is reported" {
    try std.testing.expectEqualStrings("0.1.0-dev", version());
}

test {
    std.testing.refAllDecls(@This());
}
