const std = @import("std");
const core = @import("core");

pub fn main(init: std.process.Init) !void {
    var buf: [64]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "prefablens {s}\n", .{core.version()});
    try std.Io.File.stdout().writeStreamingAll(init.io, msg);
}

test "cli links core module" {
    // 今はコンパイルとリンクができれば OK
    _ = core.version();
}
