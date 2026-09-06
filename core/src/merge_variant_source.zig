const std = @import("std");
const model = @import("model.zig");
const context = @import("merge_context.zig");
const parser = @import("parser.zig");
const source = @import("source.zig");
const testing = std.testing;

pub const Error = parser.Error || error{ MissingSource, MissingTarget, AmbiguousSource, InvalidSource, SourceCycle };

pub const Layer = struct {
    file: source.ParsedFile,
    instance: *const model.Document,
    target: model.Ref,
};

pub const Resolved = struct {
    file: source.ParsedFile,
    document: *const model.Document,
    layers: []const Layer = &.{},
    // This ID uses the requested asset's namespace, including stripped IDs.
    owner_file_id: ?i64 = null,

    pub fn scriptGuid(self: Resolved) ?[]const u8 {
        const script = reference(field(self.document.body, "m_Script")) orelse return null;
        return script.guid;
    }
};

// The arena owns parsed files and their layers. Immutable snapshots keep one
// merge side's source graph independent from worktree and output sources.
pub const Graph = struct {
    arena: std.mem.Allocator,
    snapshot: context.Snapshot,
    parsed: std.StringHashMapUnmanaged(source.ParsedFile) = .empty,

    pub fn init(arena: std.mem.Allocator, snapshot: context.Snapshot) Graph {
        return .{ .arena = arena, .snapshot = snapshot };
    }

    pub fn resolve(self: *Graph, target: model.Ref) Error!Resolved {
        return self.resolveInner(target, &.{});
    }

    pub fn targets(self: *Graph, guid: []const u8) Error![]const model.Ref {
        return self.targetsInner(guid, &.{});
    }

    fn targetsInner(self: *Graph, guid: []const u8, ancestors: []const []const u8) Error![]const model.Ref {
        if (ancestors.len >= model.max_prefab_nesting) return error.SourceCycle;
        for (ancestors) |ancestor| if (std.mem.eql(u8, ancestor, guid)) return error.SourceCycle;
        const chain = try self.arena.alloc([]const u8, ancestors.len + 1);
        @memcpy(chain[0..ancestors.len], ancestors);
        chain[ancestors.len] = guid;
        const parsed = try self.file(guid);
        var result: std.ArrayList(model.Ref) = .empty;
        for (parsed.documents) |*doc| {
            if (doc.class_id != 1001) {
                if (!doc.stripped) try result.append(self.arena, .{ .file_id = doc.file_id, .guid = guid, .type_id = 3 });
                continue;
            }
            const inner_guid = sourceGuid(doc) orelse return error.InvalidSource;
            const inner = try self.targetsInner(inner_guid, chain);
            for (inner) |target| {
                var file_id = target.file_id ^ doc.file_id;
                for (parsed.documents) |*stripped| {
                    if (!stripped.stripped) continue;
                    const owner = reference(field(stripped.body, "m_PrefabInstance")) orelse return error.InvalidSource;
                    const corresponding = reference(field(stripped.body, "m_CorrespondingSourceObject")) orelse return error.InvalidSource;
                    if (owner.file_id == doc.file_id and corresponding.file_id == target.file_id and corresponding.guid != null and std.mem.eql(u8, corresponding.guid.?, inner_guid)) file_id = stripped.file_id;
                }
                try result.append(self.arena, .{ .file_id = file_id, .guid = guid, .type_id = 3 });
            }
        }
        return result.toOwnedSlice(self.arena);
    }

    fn file(self: *Graph, guid: []const u8) Error!source.ParsedFile {
        if (self.parsed.get(guid)) |cached| return cached;
        var asset: ?context.Asset = null;
        for (self.snapshot.assets) |candidate| {
            if (!std.mem.eql(u8, candidate.guid, guid)) continue;
            if (asset != null) return error.AmbiguousSource;
            asset = candidate;
        }
        const bytes = (asset orelse return error.MissingSource).bytes;
        const parsed = try parser.parseSpanned(self.arena, bytes);
        if (parsed.diagnostics.len != 0 or parsed.documents.len == 0) return error.InvalidSource;
        var ids: std.AutoHashMapUnmanaged(i64, void) = .empty;
        for (parsed.documents) |document| {
            if (document.body.* != .map) return error.InvalidSource;
            const entry = try ids.getOrPut(self.arena, document.file_id);
            if (entry.found_existing) return error.AmbiguousSource;
        }
        try self.parsed.put(self.arena, guid, parsed);
        return parsed;
    }

    fn resolveInner(self: *Graph, target: model.Ref, ancestors: []const []const u8) Error!Resolved {
        const guid = target.guid orelse return error.MissingSource;
        if (ancestors.len >= model.max_prefab_nesting) return error.SourceCycle;
        for (ancestors) |ancestor| if (std.mem.eql(u8, ancestor, guid)) return error.SourceCycle;
        const chain = try self.arena.alloc([]const u8, ancestors.len + 1);
        @memcpy(chain[0..ancestors.len], ancestors);
        chain[ancestors.len] = guid;
        const parsed = try self.file(guid);
        for (parsed.documents) |*document| {
            if (document.file_id != target.file_id) continue;
            if (!document.stripped) {
                if (document.class_id == 1001) return error.MissingTarget;
                const owner = reference(field(document.body, "m_GameObject"));
                if (owner != null and owner.?.guid != null) return error.InvalidSource;
                return .{ .file = parsed, .document = document, .owner_file_id = if (document.class_id == 1) document.file_id else if (owner) |value| value.file_id else null };
            }
            const corresponding = reference(field(document.body, "m_CorrespondingSourceObject")) orelse return error.InvalidSource;
            const owner = reference(field(document.body, "m_PrefabInstance")) orelse return error.InvalidSource;
            if (owner.guid != null) return error.InvalidSource;
            const instance = findDocument(parsed, owner.file_id) orelse return error.InvalidSource;
            const source_guid = sourceGuid(instance) orelse return error.InvalidSource;
            if (corresponding.guid == null or !std.mem.eql(u8, corresponding.guid.?, source_guid)) return error.InvalidSource;
            const resolved = try self.resolveInner(corresponding, chain);
            if (try targetRemoved(instance, corresponding, resolved.owner_file_id)) return error.MissingTarget;
            return self.appendLayer(resolved, .{ .file = parsed, .instance = instance, .target = corresponding });
        }
        var found: ?Resolved = null;
        for (parsed.documents) |*instance| {
            const source_guid = sourceGuid(instance) orelse continue;
            const inner: model.Ref = .{ .file_id = target.file_id ^ instance.file_id, .guid = source_guid, .type_id = 3 };
            const resolved = self.resolveInner(inner, chain) catch |err| switch (err) {
                error.MissingTarget => continue,
                else => return err,
            };
            if (try targetRemoved(instance, inner, resolved.owner_file_id)) continue;
            if (found != null) return error.AmbiguousSource;
            found = try self.appendLayer(resolved, .{ .file = parsed, .instance = instance, .target = inner });
        }
        return found orelse error.MissingTarget;
    }

    fn appendLayer(self: *Graph, resolved: Resolved, layer: Layer) Error!Resolved {
        const layers = try self.arena.alloc(Layer, resolved.layers.len + 1);
        @memcpy(layers[0..resolved.layers.len], resolved.layers);
        layers[resolved.layers.len] = layer;
        var result = resolved;
        result.layers = layers;
        if (resolved.owner_file_id) |owner_id| {
            var explicit: ?i64 = null;
            for (layer.file.documents) |document| {
                if (!document.stripped or document.class_id != 1) continue;
                const owner = reference(field(document.body, "m_PrefabInstance")) orelse return error.InvalidSource;
                if (owner.guid != null or owner.file_id != layer.instance.file_id) continue;
                const corresponding = reference(field(document.body, "m_CorrespondingSourceObject")) orelse return error.InvalidSource;
                if (corresponding.file_id != owner_id) continue;
                if (corresponding.guid == null or layer.target.guid == null or !std.mem.eql(u8, corresponding.guid.?, layer.target.guid.?)) continue;
                if (explicit != null) return error.AmbiguousSource;
                explicit = document.file_id;
            }
            result.owner_file_id = explicit orelse (owner_id ^ layer.instance.file_id);
        }
        return result;
    }
};

fn field(node: *const model.Node, key: []const u8) ?*const model.Node {
    return if (node.* == .map) model.findValue(node.map, key) else null;
}

fn reference(node: ?*const model.Node) ?model.Ref {
    const present = node orelse return null;
    return if (present.* == .ref) present.ref else null;
}

fn findDocument(parsed: source.ParsedFile, file_id: i64) ?*const model.Document {
    for (parsed.documents) |*document| if (document.file_id == file_id) return document;
    return null;
}

fn sourceGuid(document: *const model.Document) ?[]const u8 {
    if (document.class_id != 1001 or document.stripped) return null;
    return (reference(field(document.body, "m_SourcePrefab")) orelse return null).guid;
}

pub fn targetRemoved(instance: *const model.Document, target: model.Ref, owner_file_id: ?i64) Error!bool {
    const modification = field(instance.body, "m_Modification") orelse return false;
    if (modification.* != .map) return error.InvalidSource;
    const component_removed = try removedRef(field(modification, "m_RemovedComponents"), target);
    const owner: ?model.Ref = if (owner_file_id) |owner_id| .{
        .file_id = owner_id,
        .guid = target.guid,
        .type_id = target.type_id,
    } else null;
    const owner_removed = try removedRef(field(modification, "m_RemovedGameObjects"), owner);
    return component_removed or owner_removed;
}

fn removedRef(list: ?*const model.Node, target: ?model.Ref) Error!bool {
    const present = list orelse return false;
    if (present.* != .seq) return error.InvalidSource;
    var found = false;
    for (present.seq) |item| {
        const value = reference(item) orelse return error.InvalidSource;
        if (value.file_id == 0) return error.InvalidSource;
        const expected = target orelse continue;
        if (value.file_id != expected.file_id) continue;
        if (value.guid == null or (expected.guid != null and std.mem.eql(u8, value.guid.?, expected.guid.?))) found = true;
    }
    return found;
}

test "variant source lookup returns nested override layers in inheritance order" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const base = "--- !u!114 &40\nMonoBehaviour:\n  m_Script: {fileID: 11500000, guid: 00000000000000000000000000000004, type: 3}\n  items: [A, B]\n";
    const middle = "--- !u!1001 &100\nPrefabInstance:\n  m_SourcePrefab: {fileID: 100100000, guid: 00000000000000000000000000000001, type: 3}\n  m_Modification:\n    m_Modifications:\n    - target: {fileID: 40, guid: 00000000000000000000000000000001, type: 3}\n      propertyPath: items.Array.data[1]\n      value: Middle\n      objectReference: {fileID: 0}\n";
    const outer = "--- !u!1001 &1000\nPrefabInstance:\n  m_SourcePrefab: {fileID: 100100000, guid: 00000000000000000000000000000002, type: 3}\n  m_Modification:\n    m_Modifications: []\n";
    var graph = Graph.init(arena, .{ .assets = &.{
        .{ .guid = "00000000000000000000000000000001", .path = "Base.prefab", .bytes = base },
        .{ .guid = "00000000000000000000000000000002", .path = "Middle.prefab", .bytes = middle },
        .{ .guid = "00000000000000000000000000000003", .path = "Outer.prefab", .bytes = outer },
    } });
    // Unity's instance namespace composes with XOR at each nesting level.
    const result = try graph.resolve(.{ .guid = "00000000000000000000000000000003", .file_id = 1000 ^ 100 ^ 40, .type_id = 3 });
    try testing.expectEqual(@as(i64, 40), result.document.file_id);
    try testing.expectEqualStrings("00000000000000000000000000000004", result.scriptGuid().?);
    try testing.expectEqual(@as(usize, 2), result.layers.len);
    try testing.expectEqual(@as(i64, 100), result.layers[0].instance.file_id);
    try testing.expectEqual(@as(i64, 40), result.layers[0].target.file_id);
    try testing.expectEqual(@as(i64, 1000), result.layers[1].instance.file_id);
    try testing.expectEqual(@as(i64, 100 ^ 40), result.layers[1].target.file_id);
    try testing.expectEqualStrings("00000000000000000000000000000002", result.layers[1].target.guid.?);
}

test "variant source lookup follows explicit stripped object correspondence" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const base = "--- !u!114 &40\nMonoBehaviour:\n  items: [A, B]\n";
    const variant = "--- !u!1001 &100\nPrefabInstance:\n  m_SourcePrefab: {fileID: 100100000, guid: 00000000000000000000000000000001, type: 3}\n  m_Modification:\n    m_Modifications: []\n--- !u!114 &200 stripped\nMonoBehaviour:\n  m_CorrespondingSourceObject: {fileID: 40, guid: 00000000000000000000000000000001, type: 3}\n  m_PrefabInstance: {fileID: 100}\n";
    var graph = Graph.init(arena, .{ .assets = &.{
        .{ .guid = "00000000000000000000000000000001", .path = "Base.prefab", .bytes = base },
        .{ .guid = "00000000000000000000000000000005", .path = "Variant.prefab", .bytes = variant },
    } });
    // An explicit source mapping has priority over an inferred virtual file ID.
    const result = try graph.resolve(.{ .guid = "00000000000000000000000000000005", .file_id = 200, .type_id = 3 });
    try testing.expectEqual(@as(i64, 40), result.document.file_id);
    try testing.expectEqual(@as(usize, 1), result.layers.len);
    try testing.expectEqual(@as(i64, 40), result.layers[0].target.file_id);
}

test "variant source lookup rejects missing cyclic and ambiguous targets" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const base = "--- !u!114 &40\nMonoBehaviour:\n  items: []\n--- !u!114 &44\nMonoBehaviour:\n  items: []\n";
    const ambiguous = "--- !u!1001 &100\nPrefabInstance:\n  m_SourcePrefab: {fileID: 100100000, guid: 00000000000000000000000000000001, type: 3}\n--- !u!1001 &96\nPrefabInstance:\n  m_SourcePrefab: {fileID: 100100000, guid: 00000000000000000000000000000001, type: 3}\n";
    const cyclic = "--- !u!1001 &100\nPrefabInstance:\n  m_SourcePrefab: {fileID: 100100000, guid: 00000000000000000000000000000008, type: 3}\n";
    var graph = Graph.init(arena, .{ .assets = &.{
        .{ .guid = "00000000000000000000000000000001", .path = "Base.prefab", .bytes = base },
        .{ .guid = "00000000000000000000000000000007", .path = "Ambiguous.prefab", .bytes = ambiguous },
        .{ .guid = "00000000000000000000000000000008", .path = "Cycle.prefab", .bytes = cyclic },
    } });
    try testing.expectError(error.MissingSource, graph.resolve(.{ .guid = "00000000000000000000000000000006", .file_id = 40 }));
    try testing.expectError(error.MissingTarget, graph.resolve(.{ .guid = "00000000000000000000000000000001", .file_id = 999 }));
    // Both nested instance namespaces resolve this ID, so neither is evidence.
    try testing.expectError(error.AmbiguousSource, graph.resolve(.{ .guid = "00000000000000000000000000000007", .file_id = 100 ^ 40 }));
    try testing.expectError(error.SourceCycle, graph.resolve(.{ .guid = "00000000000000000000000000000008", .file_id = 40 }));
}

test "variant source lookup rejects duplicate documents and removed components" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const duplicate = "--- !u!114 &40\nMonoBehaviour:\n  items: []\n--- !u!114 &40\nMonoBehaviour:\n  items: []\n";
    const base = "--- !u!114 &40\nMonoBehaviour:\n  items: [A]\n";
    const removed = "--- !u!1001 &100\nPrefabInstance:\n  m_SourcePrefab: {fileID: 100100000, guid: 00000000000000000000000000000001, type: 3}\n  m_Modification:\n    m_RemovedComponents:\n    - {fileID: 40, guid: 00000000000000000000000000000001, type: 3}\n";
    var graph = Graph.init(arena, .{ .assets = &.{
        .{ .guid = "00000000000000000000000000000009", .path = "Duplicate.prefab", .bytes = duplicate },
        .{ .guid = "00000000000000000000000000000001", .path = "Base.prefab", .bytes = base },
        .{ .guid = "0000000000000000000000000000000a", .path = "Removed.prefab", .bytes = removed },
    } });
    try testing.expectError(error.AmbiguousSource, graph.resolve(.{ .guid = "00000000000000000000000000000009", .file_id = 40 }));
    // A leftover override must not resurrect a component removed by its source.
    try testing.expectError(error.MissingTarget, graph.resolve(.{ .guid = "0000000000000000000000000000000a", .file_id = 100 ^ 40 }));
}

test "variant source lookup follows actual nested Unity collection targets" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var graph = Graph.init(arena, .{ .assets = &.{
        .{ .guid = "0464d347790434a4898eef837430e91e", .path = "Source.prefab", .bytes = @embedFile("testdata/collections/nested/Source.prefab") },
        .{ .guid = "ab1c296b655d64e63bb3c72575e8eed7", .path = "NestedFirst.prefab", .bytes = @embedFile("testdata/collections/nested/NestedFirst.prefab") },
    } });
    const outer = try parser.parseSpanned(arena, @embedFile("testdata/collections/nested/NestedSecond.prefab"));
    const instance = &outer.documents[0];
    const modifications = field(field(instance.body, "m_Modification").?, "m_Modifications").?;
    const target = reference(field(modifications.seq[0], "target")).?;
    const result = try graph.resolve(target);
    // This file ID comes from Unity 6000.7.0a2, not a hand-written XOR fixture.
    try testing.expectEqual(@as(i64, 6274539545266883574), result.document.file_id);
    try testing.expectEqualStrings("2fa164009c127473f99613ff893ebea2", result.scriptGuid().?);
    try testing.expectEqual(@as(usize, 1), result.layers.len);
    try testing.expectEqual(@as(i64, 1846275229663862621), result.layers[0].instance.file_id);
}

const review_base_guid = "00000000000000000000000000000001";
const review_middle_guid = "00000000000000000000000000000002";
const review_outer_guid = "00000000000000000000000000000003";
const review_base =
    \\--- !u!1 &10
    \\GameObject:
    \\  m_Name: Owner
    \\--- !u!114 &40
    \\MonoBehaviour:
    \\  m_GameObject: {fileID: 10}
    \\  items: [A]
    \\
;

test "variant source rejects directly removed owner reached through explicit stripped ids" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const middle =
        \\--- !u!1001 &100
        \\PrefabInstance:
        \\  m_SourcePrefab: {fileID: 100100000, guid: 00000000000000000000000000000001, type: 3}
        \\  m_Modification:
        \\    m_Modifications: []
        \\    m_RemovedComponents: []
        \\    m_RemovedGameObjects: []
        \\--- !u!114 &200 stripped
        \\MonoBehaviour:
        \\  m_CorrespondingSourceObject: {fileID: 40, guid: 00000000000000000000000000000001, type: 3}
        \\  m_PrefabInstance: {fileID: 100}
        \\  m_GameObject: {fileID: 300}
        \\--- !u!1 &300 stripped
        \\GameObject:
        \\  m_CorrespondingSourceObject: {fileID: 10, guid: 00000000000000000000000000000001, type: 3}
        \\  m_PrefabInstance: {fileID: 100}
        \\
    ;
    const outer =
        \\--- !u!1001 &1000
        \\PrefabInstance:
        \\  m_SourcePrefab: {fileID: 100100000, guid: 00000000000000000000000000000002, type: 3}
        \\  m_Modification:
        \\    m_Modifications: []
        \\    m_RemovedComponents: []
        \\    m_RemovedGameObjects:
        \\    - {fileID: 300, guid: 00000000000000000000000000000002, type: 3}
        \\
    ;
    var graph = Graph.init(memory.allocator(), .{ .assets = &.{
        .{ .guid = review_base_guid, .path = "Base.prefab", .bytes = review_base },
        .{ .guid = review_middle_guid, .path = "Middle.prefab", .bytes = middle },
        .{ .guid = review_outer_guid, .path = "Outer.prefab", .bytes = outer },
    } });
    // Stripped component and owner IDs are explicit correspondences, not one XOR offset.
    const component = try graph.resolve(.{ .guid = review_middle_guid, .file_id = 200 });
    try testing.expectEqual(@as(?i64, 300), component.owner_file_id);
    try std.testing.expectError(error.MissingTarget, graph.resolve(.{ .guid = review_outer_guid, .file_id = 1000 ^ 200 }));
}

test "variant source rejects malformed removal list" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const malformed =
        \\--- !u!1001 &100
        \\PrefabInstance:
        \\  m_SourcePrefab: {fileID: 100100000, guid: 00000000000000000000000000000001, type: 3}
        \\  m_Modification:
        \\    m_Modifications: []
        \\    m_RemovedComponents: not-a-sequence
        \\    m_RemovedGameObjects: []
        \\
    ;
    var graph = Graph.init(memory.allocator(), .{ .assets = &.{
        .{ .guid = review_base_guid, .path = "Base.prefab", .bytes = review_base },
        .{ .guid = review_middle_guid, .path = "Malformed.prefab", .bytes = malformed },
    } });
    // Unknown removal state cannot establish that the inherited component still exists.
    try std.testing.expectError(error.InvalidSource, graph.resolve(.{ .guid = review_middle_guid, .file_id = 100 ^ 40 }));
    for ([_][]const u8{ "[bogus]", "[{fileID: 0}]" }) |bad_list| {
        const bytes = try std.mem.replaceOwned(u8, memory.allocator(), malformed, "not-a-sequence", bad_list);
        var bad = Graph.init(memory.allocator(), .{ .assets = &.{
            .{ .guid = review_base_guid, .path = "Base.prefab", .bytes = review_base },
            .{ .guid = review_middle_guid, .path = "Malformed.prefab", .bytes = bytes },
        } });
        try testing.expectError(error.InvalidSource, bad.resolve(.{ .guid = review_middle_guid, .file_id = 100 ^ 40 }));
    }
    const invalid_modification = "--- !u!1001 &100\nPrefabInstance:\n  m_SourcePrefab: {fileID: 100100000, guid: 00000000000000000000000000000001, type: 3}\n  m_Modification: unknown\n";
    var bad = Graph.init(memory.allocator(), .{ .assets = &.{
        .{ .guid = review_base_guid, .path = "Base.prefab", .bytes = review_base },
        .{ .guid = review_middle_guid, .path = "Malformed.prefab", .bytes = invalid_modification },
    } });
    try testing.expectError(error.InvalidSource, bad.resolve(.{ .guid = review_middle_guid, .file_id = 100 ^ 40 }));
}

// Native strategy uses only declared prefab source edges, never loose path text.
pub fn dependencies(arena: std.mem.Allocator, bytes: []const u8) Error![]const []const u8 {
    const parsed = try parser.parseSpanned(arena, bytes);
    if (parsed.diagnostics.len != 0) return error.InvalidSource;
    var result: std.ArrayList([]const u8) = .empty;
    for (parsed.documents) |*doc| {
        if (doc.class_id != 1001 or doc.stripped) continue;
        const guid = sourceGuid(doc) orelse return error.InvalidSource;
        var found = false;
        for (result.items) |existing| if (std.mem.eql(u8, existing, guid)) {
            found = true;
            break;
        };
        if (!found) try result.append(arena, guid);
    }
    return result.toOwnedSlice(arena);
}
