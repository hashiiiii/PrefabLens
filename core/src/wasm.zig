//! WASM C ABI ラッパ(親仕様 §5.6)。diff 1 回 = 1 arena、グローバル可変状態なし。
//! 戻り値は u32(LE)長さ前置の JSON バイト列。呼び出し側が free(ptr, 4 + len) で解放する。
const std = @import("std");
const core = @import("root.zig");

const gpa = std.heap.wasm_allocator;

export fn alloc(len: usize) ?[*]u8 {
    if (len == 0) return null;
    const buf = gpa.alloc(u8, len) catch return null;
    return buf.ptr;
}

export fn free(ptr: ?[*]u8, len: usize) void {
    const p = ptr orelse return;
    if (len == 0) return;
    gpa.free(p[0..len]);
}

export fn diff(
    before_ptr: ?[*]const u8,
    before_len: usize,
    after_ptr: ?[*]const u8,
    after_len: usize,
) ?[*]u8 {
    const before: []const u8 = if (before_ptr) |p| p[0..before_len] else "";
    const after: []const u8 = if (after_ptr) |p| p[0..after_len] else "";

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json = core.diffToJson(arena, before, after) catch |err| {
        const msg = std.fmt.allocPrint(
            arena,
            "{{\"schema\":\"prefablens.error.v1\",\"error\":\"{s}\"}}",
            .{@errorName(err)},
        ) catch return null;
        return packResult(msg);
    };
    return packResult(json);
}

// arena の外(呼び出し側所有)へコピーして長さ前置する。
fn packResult(json: []const u8) ?[*]u8 {
    const out = gpa.alloc(u8, 4 + json.len) catch return null;
    std.mem.writeInt(u32, out[0..4], @intCast(json.len), .little);
    @memcpy(out[4..], json);
    return out.ptr;
}
