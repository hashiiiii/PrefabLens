// WASM C ABI wrapper. One diff = one arena, no global mutable state.
// Returns a JSON byte string prefixed with a u32 (LE) length. The caller frees it with free(ptr, 4 + len).
const std = @import("std");
const core = @import("root.zig");
const assets_tlv = @import("assets_tlv.zig");

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
    return run(slice(before_ptr, before_len), slice(after_ptr, after_len), null);
}

// assets is a binary TLV (LE): [u32 count] repeat{ [u32 guid_len][guid][u32 data_len][data] }.
// Source prefab bytes are passed as-is to avoid JSON string escaping.
export fn diff_with_assets(
    before_ptr: ?[*]const u8,
    before_len: usize,
    after_ptr: ?[*]const u8,
    after_len: usize,
    assets_ptr: ?[*]const u8,
    assets_len: usize,
) ?[*]u8 {
    return run(slice(before_ptr, before_len), slice(after_ptr, after_len), slice(assets_ptr, assets_len));
}

export fn is_unity_yaml(ptr: ?[*]const u8, len: usize) i32 {
    return @intFromBool(core.isUnityYaml(slice(ptr, len)));
}

fn slice(ptr: ?[*]const u8, len: usize) []const u8 {
    return if (ptr) |p| p[0..len] else "";
}

fn run(before: []const u8, after: []const u8, assets_bytes: ?[]const u8) ?[*]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json = computeJson(arena, before, after, assets_bytes) catch |err| {
        const msg = std.fmt.allocPrint(
            arena,
            "{{\"schema\":\"prefablens.error.v1\",\"error\":\"{s}\"}}",
            .{@errorName(err)},
        ) catch return null;
        return packResult(msg);
    };
    return packResult(json);
}

fn computeJson(arena: std.mem.Allocator, before: []const u8, after: []const u8, assets_bytes: ?[]const u8) ![]u8 {
    const ab = assets_bytes orelse return core.diffToJson(arena, before, after);
    // A broken TLV returns an error and falls through to the error.v1 payload (no trap).
    var assets = try assets_tlv.parseAssets(arena, ab);
    return core.diffToJsonWithAssets(arena, before, after, &assets);
}

// Copy outside the arena (caller-owned) and prefix the length.
fn packResult(json: []const u8) ?[*]u8 {
    const out = gpa.alloc(u8, 4 + json.len) catch return null;
    std.mem.writeInt(u32, out[0..4], @intCast(json.len), .little);
    @memcpy(out[4..], json);
    return out.ptr;
}
