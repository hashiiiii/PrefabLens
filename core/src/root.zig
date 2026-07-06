const std = @import("std");
pub const model = @import("model.zig");
pub const classid = @import("classid.zig");
pub const parser = @import("parser.zig");
pub const diff = @import("diff.zig");
pub const tree = @import("tree.zig");
pub const json = @import("json.zig");
pub const inspector = @import("inspector.zig");
pub const perf = @import("perf.zig");
pub const instantiate = @import("instantiate.zig");

pub const Assets = instantiate.Assets;
const no_assets: Assets = .empty;

pub fn diffBytes(arena: std.mem.Allocator, before_src: []const u8, after_src: []const u8) !model.DiffResult {
    return diffBytesWithAssets(arena, before_src, after_src, &no_assets);
}

// assets(guid -> ソース prefab bytes)を供給された sole-status instance は
// 合成ツリーへ展開される。供給が無い guid は needed_sources に載る。
pub fn diffBytesWithAssets(arena: std.mem.Allocator, before_src: []const u8, after_src: []const u8, assets: *const Assets) !model.DiffResult {
    const fd = try diff.compute(arena, before_src, after_src);
    var res = try tree.build(arena, fd);
    try instantiate.expand(arena, &res, fd, assets);
    return res;
}

pub fn diffToJson(arena: std.mem.Allocator, before_src: []const u8, after_src: []const u8) ![]u8 {
    return diffToJsonWithAssets(arena, before_src, after_src, &no_assets);
}

pub fn diffToJsonWithAssets(arena: std.mem.Allocator, before_src: []const u8, after_src: []const u8, assets: *const Assets) ![]u8 {
    const res = try diffBytesWithAssets(arena, before_src, after_src, assets);
    return json.serialize(arena, res, null);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("fixture_test.zig");
}
