const std = @import("std");
const perf = @import("perf.zig");

// The budget is loosened above the nominal value to allow for CI-runner noise. Nominal
// values are the performance targets (typically < 5ms, ~10MB scene < 150ms). Generate a scene of
// ~10MB and verify it diffs within the CI ceiling.
const big_objects = 50_000; // at ~200 bytes per object, ~10 MB of YAML
const ci_ceiling_ms = 600; // 4x the nominal 150ms. Fails only on a true regression

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
