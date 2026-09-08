const std = @import("std");
const perf = @import("perf.zig");

// Keep the workload and ceiling stable so changes remain comparable across revisions.
const big_objects = 50_000;
const ci_ceiling_ms = 600;

pub fn main(init: std.process.Init) !void {
    // Warm up before sampling to keep one-time startup costs out of the budget.
    _ = try measure(init.io);

    var samples: [5]u64 = undefined;
    var buf: [128]u8 = undefined;
    for (&samples, 0..) |*sample, i| {
        sample.* = try measure(init.io);
        const msg = try std.fmt.bufPrint(&buf, "perf: sample {d}/{d}: {d} ms\n", .{ i + 1, samples.len, @divTrunc(sample.*, std.time.ns_per_ms) });
        try std.Io.File.stdout().writeStreamingAll(init.io, msg);
    }

    const ms = @divTrunc(perf.medianSample(samples), std.time.ns_per_ms);
    const msg = try std.fmt.bufPrint(&buf, "perf: {d} objects diffed in {d} ms median (ceiling {d} ms)\n", .{ big_objects, ms, ci_ceiling_ms });
    try std.Io.File.stdout().writeStreamingAll(init.io, msg);

    if (ms > ci_ceiling_ms) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "PERF BUDGET EXCEEDED\n");
        std.process.exit(1);
    }
}

fn measure(io: std.Io) !u64 {
    // Each diff needs its own arena so samples do not accumulate hundreds of megabytes.
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    return perf.timeDiff(io, arena_state.allocator(), big_objects);
}
