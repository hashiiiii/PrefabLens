const std = @import("std");
const root = @import("root.zig");

// n 個の GameObject(各 Transform + MonoBehaviour つき)からなる合成シーンを
// 1 つの YAML バッファとして生成する。
fn buildScene(arena: std.mem.Allocator, n: usize, hp: usize) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    for (0..n) |i| {
        const go: i64 = @intCast(1 + i * 3);
        const tr: i64 = go + 1;
        const mb: i64 = go + 2;
        try w.print(
            \\--- !u!1 &{d}
            \\GameObject:
            \\  m_Name: GO{d}
            \\  m_Component:
            \\  - component: {{fileID: {d}}}
            \\  - component: {{fileID: {d}}}
            \\--- !u!4 &{d}
            \\Transform:
            \\  m_GameObject: {{fileID: {d}}}
            \\  m_Father: {{fileID: 0}}
            \\--- !u!114 &{d}
            \\MonoBehaviour:
            \\  m_GameObject: {{fileID: {d}}}
            \\  m_Script: {{fileID: 0, guid: abc, type: 3}}
            \\  hp: {d}
            \\
        , .{ go, i, tr, mb, tr, go, mb, go, hp });
    }
    return aw.toOwnedSlice();
}

// n オブジェクトの before/after diff 1 回の所要ナノ秒を返す。
pub fn timeDiff(io: std.Io, arena: std.mem.Allocator, n: usize) !u64 {
    const before = try buildScene(arena, n, 1);
    const after = try buildScene(arena, n, 2);
    const start = std.Io.Clock.Timestamp.now(io, .boot);
    const res = try root.diffBytes(arena, before, after);
    std.mem.doNotOptimizeAway(&res);
    const end = std.Io.Clock.Timestamp.now(io, .boot);
    return @intCast(start.durationTo(end).raw.toNanoseconds());
}

test "perf: small scene diff completes well under budget" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ns = try timeDiff(std.testing.io, arena, 200); // 200 オブジェクト ≒ 小さめの prefab
    // debug ビルドのテスト向けの緩い上限(本来の予算は `zig build perf` が強制する)。
    try std.testing.expect(ns < 500 * std.time.ns_per_ms);
}
