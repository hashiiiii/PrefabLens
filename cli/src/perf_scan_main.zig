const std = @import("std");
const resolve = @import("resolve.zig");

// Performance budget gate for the default guid-resolution scan, mirroring
// core/src/perf_main.zig's convention: a nominal target with CI-noise headroom.
// Nominal: a full 50k-.meta scan (no early exit — the wanted guid never
// appears) measures ~350 ms on a dev laptop. The ceiling fails only on a true
// regression, e.g. the scan going serial again.
const meta_files = 50_000;
const files_per_dir = 100;
const scratch = ".zig-cache/tmp/prefablens-perf-scan";
const ci_ceiling_ms = 1200;

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    cwd.deleteTree(io, scratch) catch {};
    var i: usize = 0;
    while (i < meta_files) : (i += 1) {
        if (i % files_per_dir == 0) {
            const dir = try std.fmt.allocPrint(arena, "{s}/Assets/Dir{d:0>4}", .{ scratch, i / files_per_dir });
            try cwd.createDirPath(io, dir);
        }
        const path = try std.fmt.allocPrint(arena, "{s}/Assets/Dir{d:0>4}/A{d:0>3}.asset.meta", .{ scratch, i / files_per_dir, i % files_per_dir });
        const data = try std.fmt.allocPrint(arena, "fileFormatVersion: 2\nguid: {x:0>32}\nNativeFormatImporter:\n", .{i});
        try cwd.writeFile(io, .{ .sub_path = path, .data = data });
    }

    const t0 = std.Io.Clock.Timestamp.now(io, .boot);
    var index = try resolve.buildIndexFor(io, arena, scratch, &.{"guid-that-never-appears"});
    const t1 = std.Io.Clock.Timestamp.now(io, .boot);
    const ms: u64 = @intCast(@divTrunc(t0.durationTo(t1).raw.toNanoseconds(), std.time.ns_per_ms));
    cwd.deleteTree(io, scratch) catch {};

    var buf: [128]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "perf: {d} .meta scanned in {d} ms (ceiling {d} ms)\n", .{ index.count(), ms, ci_ceiling_ms });
    try std.Io.File.stdout().writeStreamingAll(io, msg);

    if (index.count() != meta_files) {
        try std.Io.File.stdout().writeStreamingAll(io, "SCAN LOST FILES\n");
        std.process.exit(1);
    }
    if (ms > ci_ceiling_ms) {
        try std.Io.File.stdout().writeStreamingAll(io, "PERF BUDGET EXCEEDED\n");
        std.process.exit(1);
    }
    return 0;
}
