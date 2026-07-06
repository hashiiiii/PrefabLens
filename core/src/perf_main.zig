const std = @import("std");
const perf = @import("perf.zig");

// 予算は CI ランナーのノイズを見込んで名目値より緩めてある。名目値は
// spec §5.7(通常 < 5ms、~10MB シーン < 150ms)。~10MB 相当のシーンを
// 生成し、CI 上限内で diff できることを検証する。
const big_objects = 50_000; // 1 オブジェクト ~200 bytes として YAML ~10 MB
const ci_ceiling_ms = 600; // 名目 150ms の 4 倍。真の退行でのみ失敗する

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
