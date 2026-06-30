//! By convention, root.zig is the root source file when making a package.
const std = @import("std");

pub fn version() []const u8 {
    return "0.1.0-dev";
}

test "core builds and version is reported" {
    try std.testing.expectEqualStrings("0.1.0-dev", version());
}
