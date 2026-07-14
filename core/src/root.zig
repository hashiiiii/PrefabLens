const std = @import("std");
pub const model = @import("model.zig");
pub const json = @import("json.zig");

const classid = @import("classid.zig");
const parser = @import("parser.zig");
const diff = @import("diff.zig");
const tree = @import("tree.zig");
const inspector = @import("inspector.zig");
const perf = @import("perf.zig");
const instantiate = @import("instantiate.zig");

pub const Assets = instantiate.Assets;
const no_assets: Assets = .empty;

pub fn diffBytes(arena: std.mem.Allocator, before_src: []const u8, after_src: []const u8) !model.DiffResult {
    return diffBytesWithAssets(arena, before_src, after_src, &no_assets);
}

// A sole-status instance supplied with assets (guid -> source prefab bytes) is
// expanded into the merged tree. Guids with no supply go into needed_sources.
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
    // refAllDecls only references pub decls; reference the internal modules
    // explicitly so their tests are still discovered.
    _ = classid;
    _ = parser;
    _ = diff;
    _ = tree;
    _ = inspector;
    _ = perf;
    _ = instantiate;
    _ = @import("fixture_test.zig");
}
