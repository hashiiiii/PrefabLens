const std = @import("std");
const perf = @import("perf.zig");

// Budget multipliers leave headroom for CI runner noise; nominal targets are
// spec §5.7 (typical < 5ms, ~10MB scene < 150ms). We size a ~10MB scene and
// assert it diffs under a generous CI ceiling.
const big_objects = 50_000; // ~10 MB of YAML at ~200 bytes/object
const ci_ceiling_ms = 600; // 4x the 150ms nominal; fails only on real regressions

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ns = try perf.timeDiff(init.io, arena, big_objects);
    const ms = @divTrunc(ns, std.time.ns_per_ms);

    var buf: [128]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "perf: {d} objects diffed in {d} ms (ceiling {d} ms)\n", .{ big_objects, ms, ci_ceiling_ms });
    try std.Io.File.stdout().writeStreamingAll(init.io, msg);

    if (ms > ci_ceiling_ms) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "PERF BUDGET EXCEEDED\n");
        std.process.exit(1);
    }
}
