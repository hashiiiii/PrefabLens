const std = @import("std");
const model = @import("model.zig");
const source = @import("source.zig");
const context = @import("merge_context.zig");
const graph = @import("merge_variant_source.zig");
const path = @import("merge_property_path.zig");
const value = @import("merge_value.zig");
const A = std.mem.Allocator;
pub const Error = A.Error || error{ContextRequired};
pub const Leaf = struct { node: *const model.Node, explicit: bool, row: ?*const model.Node = null };
pub const Projection = struct {
    node: *const model.Node,
    inherited: *const model.Node,
    leaves: []const Leaf,
    sparse: bool,
    script: context.Script,
    descriptor: context.Field,
    source_bytes: []const u8,
};
pub fn field(n: *const model.Node, key: []const u8) ?*const model.Node {
    return if (n.* == .map) model.findValue(n.map, key) else null;
}
pub fn rows(doc: *const model.Document) ?*const model.Node {
    return field(field(doc.body, "m_Modification") orelse return null, "m_Modifications");
}
pub fn sameRef(a: model.Ref, b: model.Ref) bool {
    return a.file_id == b.file_id and optionalEqual(a.guid, b.guid);
}
fn optionalEqual(a: ?[]const u8, b: ?[]const u8) bool {
    return if (a) |s| b != null and std.mem.eql(u8, s, b.?) else b == null;
}
pub fn at(n: *const model.Node, segments: []const path.Segment) ?*const model.Node {
    if (segments.len == 0) return n;
    return switch (segments[0]) {
        .field => |key| at(field(n, key) orelse return null, segments[1..]),
        .index => |index| if (n.* == .seq and index < n.seq.len) at(n.seq[index], segments[1..]) else null,
        .size => null,
    };
}
fn clone(arena: A, n: *const model.Node, file: source.ParsedFile, leaves: *std.ArrayList(Leaf)) Error!*const model.Node {
    if (n.* == .map and n.map.len > 0) {
        const entries = try arena.dupe(model.Entry, n.map);
        for (entries) |*entry| entry.value = @constCast(try clone(arena, entry.value, file, leaves));
        return value.node(arena, .{ .map = entries });
    }
    if (n.* == .seq) {
        const items = try arena.dupe(*model.Node, n.seq);
        for (items) |*item| item.* = @constCast(try clone(arena, item.*, file, leaves));
        return value.node(arena, .{ .seq = items });
    }
    var leaf = n.*;
    if (n.* == .map) {
        const span = file.entry_spans.get(n) orelse return error.ContextRequired;
        if (std.mem.trim(u8, span.value.bytes(file.bytes), " \t\r\n").len != 0) return error.ContextRequired;
        leaf = .{ .scalar = "" };
    }
    const result = try value.node(arena, leaf);
    try leaves.append(arena, .{ .node = result, .explicit = false });
    return result;
}
fn assign(arena: A, n: *const model.Node, segments: []const path.Segment, replacement: *const model.Node) Error!*const model.Node {
    if (segments.len == 0) return replacement;
    if (segments[0] != .field or n.* != .map) return error.ContextRequired;
    const key = segments[0].field;
    var entries = try std.ArrayList(model.Entry).initCapacity(arena, n.map.len + 1);
    try entries.appendSlice(arena, n.map);
    for (entries.items) |*entry| {
        if (!std.mem.eql(u8, entry.key, key)) continue;
        entry.value = @constCast(try assign(arena, entry.value, segments[1..], replacement));
        return value.node(arena, .{ .map = try entries.toOwnedSlice(arena) });
    }
    const empty = try value.node(arena, .{ .map = &.{} });
    try entries.append(arena, .{ .key = key, .value = @constCast(try assign(arena, empty, segments[1..], replacement)) });
    return value.node(arena, .{ .map = try entries.toOwnedSlice(arena) });
}
const ActiveRow = struct { row: *const model.Node, suffix: []const path.Segment };
fn layer(arena: A, initial: *const model.Node, doc: *const model.Document, target: model.Ref, root: []const u8, leaves: *std.ArrayList(Leaf), local: bool, allow_explicit_growth: bool, sparse: *bool) Error!*const model.Node {
    if (field(doc.body, "m_Modification")) |modification| {
        if (field(modification, "m_RemovedGameObjects")) |removed| {
            if (removed.* != .seq or removed.seq.len > 0) return error.ContextRequired;
        }
    }
    const sequence = rows(doc) orelse return error.ContextRequired;
    if (sequence.* != .seq) return error.ContextRequired;
    const root_path = path.parse(arena, root) catch return error.ContextRequired;
    var selected: std.ArrayList(ActiveRow) = .empty;
    var size: ?usize = null;
    for (sequence.seq) |row| {
        const r = field(row, "target") orelse return error.ContextRequired;
        const p = field(row, "propertyPath") orelse return error.ContextRequired;
        if (r.* != .ref or p.* != .scalar) return error.ContextRequired;
        const parsed = path.parse(arena, p.scalar) catch return error.ContextRequired;
        if (!sameRef(target, r.ref)) continue;
        const candidate_root = path.collectionRoot(arena, p.scalar) catch return error.ContextRequired;
        if (candidate_root == null or !std.mem.eql(u8, candidate_root.?, root)) continue;
        const suffix = parsed[root_path.len..];
        if (suffix.len == 0) return error.ContextRequired;
        if (suffix[0] == .size) {
            if (size != null) return error.ContextRequired;
            const raw = field(row, "value") orelse return error.ContextRequired;
            if (raw.* != .scalar) return error.ContextRequired;
            const count = std.fmt.parseInt(usize, raw.scalar, 10) catch return error.ContextRequired;
            if (count > 100_000) return error.ContextRequired;
            size = count;
        } else try selected.append(arena, .{ .row = row, .suffix = suffix });
    }
    if (initial.* != .seq) return error.ContextRequired;
    const count = size orelse initial.seq.len;
    const items = try arena.alloc(*model.Node, count);
    for (items, 0..) |*item, i| {
        if (i < initial.seq.len) item.* = initial.seq[i] else {
            sparse.* = true;
            if (initial.seq.len != 0 and !allow_explicit_growth) return error.ContextRequired;
            item.* = @constCast(try value.node(arena, .{ .map = &.{} }));
        }
    }
    var active_paths: std.ArrayList([]const u8) = .empty;
    for (selected.items) |record| {
        if (record.suffix[0] != .index) return error.ContextRequired;
        const index = record.suffix[0].index;
        // Size is decided first. Valid stale records never create active items.
        if (index >= count) continue;
        for (record.suffix[1..]) |segment| if (segment != .field) return error.ContextRequired;
        const text = path.format(arena, record.suffix) catch return error.ContextRequired;
        for (active_paths.items) |previous| {
            if (std.mem.eql(u8, previous, text) or isAncestor(previous, text) or isAncestor(text, previous)) return error.ContextRequired;
        }
        try active_paths.append(arena, text);
        const raw = field(record.row, "value") orelse return error.ContextRequired;
        const reference = field(record.row, "objectReference") orelse return error.ContextRequired;
        if (reference.* != .ref) return error.ContextRequired;
        const inherited = at(items[index], record.suffix[1..]);
        const blank = (raw.* == .map and raw.map.len == 0) or (raw.* == .scalar and raw.scalar.len == 0);
        var data: model.Node = undefined;
        if (reference.ref.file_id != 0 or reference.ref.guid != null or (inherited != null and inherited.?.* == .ref)) {
            if (!blank) return error.ContextRequired;
            data = reference.*;
        } else if (blank) {
            // A known inherited string proves the empty channel; sparse empty
            // rows cannot distinguish null references from empty strings.
            if (inherited == null or inherited.?.* != .scalar) return error.ContextRequired;
            data = .{ .scalar = "" };
        } else if (raw.* == .scalar) data = raw.* else return error.ContextRequired;
        const leaf = try value.node(arena, data);
        try leaves.append(arena, .{ .node = leaf, .explicit = local, .row = record.row });
        items[index] = @constCast(try assign(arena, items[index], record.suffix[1..], leaf));
    }
    return value.node(arena, .{ .seq = items });
}
fn isAncestor(a: []const u8, b: []const u8) bool {
    return b.len > a.len and std.mem.startsWith(u8, b, a) and b[a.len] == '.';
}
fn allLeavesExplicit(node: *const model.Node, leaves: []const Leaf) bool {
    if (node.* == .map) {
        for (node.map) |entry| if (!allLeavesExplicit(entry.value, leaves)) return false;
        return true;
    }
    if (node.* == .seq) {
        for (node.seq) |item| if (!allLeavesExplicit(item, leaves)) return false;
        return true;
    }
    for (leaves) |leaf| if (leaf.node == node) return leaf.explicit;
    return false;
}
fn validateAcceptedExplicitGrowth(inherited: *const model.Node, current: *const model.Node, leaves: []const Leaf) Error!void {
    if (inherited.* != .seq or current.* != .seq or inherited.seq.len == 0 or current.seq.len <= inherited.seq.len) return;
    for (current.seq[inherited.seq.len..]) |item| {
        var complete = false;
        for (inherited.seq) |template| if (coverageEqual(template, item)) {
            complete = true;
            break;
        };
        if (!complete or !allLeavesExplicit(item, leaves)) return error.ContextRequired;
    }
}
pub fn project(arena: A, snapshot: context.Snapshot, doc: ?*const model.Document, target: model.Ref, root: []const u8) Error!Projection {
    return projectInternal(arena, snapshot, doc, target, root, false);
}
// Final rematerialization may accept a user-selected custom item only when its
// emitted rows explicitly cover a complete serialized source-item shape.
pub fn projectAcceptedExplicitGrowth(arena: A, snapshot: context.Snapshot, doc: *const model.Document, target: model.Ref, root: []const u8) Error!Projection {
    return projectInternal(arena, snapshot, doc, target, root, true);
}
fn projectInternal(arena: A, snapshot: context.Snapshot, doc: ?*const model.Document, target: model.Ref, root: []const u8, allow_explicit_growth: bool) Error!Projection {
    var sources = graph.Graph.init(arena, snapshot);
    const resolved = sources.resolve(target) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ContextRequired,
    };
    if (doc) |outer| {
        const source_ref = field(outer.body, "m_SourcePrefab") orelse return error.ContextRequired;
        if (source_ref.* != .ref or !optionalEqual(source_ref.ref.guid, target.guid)) return error.ContextRequired;
        if (@import("merge_variant_source.zig").targetRemoved(outer, target, resolved.owner_file_id) catch return error.ContextRequired) return error.ContextRequired;
    }
    const guid = resolved.scriptGuid() orelse return error.ContextRequired;
    var script: ?context.Script = null;
    for (snapshot.scripts) |s| if (std.mem.eql(u8, guid, s.guid)) {
        if (script != null) return error.ContextRequired;
        script = s;
    };
    const descriptor = snapshot.field(guid, root) orelse return error.ContextRequired;
    const segments = path.parse(arena, root) catch return error.ContextRequired;
    var original = at(resolved.document.body, segments) orelse return error.ContextRequired;
    if (descriptor.kind == .int32_array and original.* != .seq) {
        const token = if (original.* == .scalar) original.scalar else blk: {
            if (original.* != .map or original.map.len != 0) return error.ContextRequired;
            const span = resolved.file.entry_spans.get(original) orelse return error.ContextRequired;
            if (std.mem.trim(u8, span.value.bytes(resolved.file.bytes), " \t\r\n").len != 0) return error.ContextRequired;
            break :blk "";
        };
        const decoded = @import("merge_packed.zig").decodeInt32(arena, token) catch return error.ContextRequired;
        const items = try arena.alloc(*model.Node, decoded.values.len);
        for (items, decoded.values) |*item, integer| item.* = @constCast(try value.node(arena, .{ .scalar = try std.fmt.allocPrint(arena, "{d}", .{integer}) }));
        original = try value.node(arena, .{ .seq = items });
    }
    if (original.* != .seq) return error.ContextRequired;
    var leaves: std.ArrayList(Leaf) = .empty;
    var current = try clone(arena, original, resolved.file, &leaves);
    var sparse = false;
    for (resolved.layers) |inherited| current = try layer(arena, current, inherited.instance, inherited.target, root, &leaves, false, false, &sparse);
    const inherited = current;
    if (doc) |outer| current = try layer(arena, current, outer, target, root, &leaves, true, allow_explicit_growth, &sparse);
    if (allow_explicit_growth) try validateAcceptedExplicitGrowth(inherited, current, leaves.items);
    if (descriptor.kind == .int32_array) for (current.seq) |item| {
        if (item.* != .scalar) return error.ContextRequired;
        _ = std.fmt.parseInt(i32, item.scalar, 10) catch return error.ContextRequired;
    };
    var chain: std.ArrayList(u8) = .empty;
    try chain.appendSlice(arena, resolved.file.bytes);
    for (resolved.layers) |inherited_layer| try chain.appendSlice(arena, inherited_layer.file.bytes);
    return .{ .node = current, .inherited = inherited, .leaves = try leaves.toOwnedSlice(arena), .sparse = sparse, .script = script orelse return error.ContextRequired, .descriptor = descriptor, .source_bytes = try chain.toOwnedSlice(arena) };
}
pub fn coverageEqual(a: *const model.Node, b: *const model.Node) bool {
    if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
    return switch (a.*) {
        .scalar, .ref => true,
        .seq => false,
        .map => blk: {
            if (a.map.len != b.map.len) break :blk false;
            for (a.map) |entry| if (!coverageEqual(entry.value, field(b, entry.key) orelse break :blk false)) break :blk false;
            break :blk true;
        },
    };
}
pub fn compatible(projections: []const Projection) bool {
    const first = projections[0];
    var sparse = false;
    for (projections) |p| {
        if (!first.descriptor.sameType(p.descriptor)) return false;
        if ((p.descriptor.kind == .string_dictionary or p.descriptor.kind == .int32_dictionary) and p.descriptor.dictionary_equality != .default) return false;
        if (p.sparse) sparse = true;
    }
    var nested = false;
    for (projections) |p| for (p.node.seq) |item| if (hasNestedSequence(item)) {
        nested = true;
    };
    if (nested) for (projections) |p| {
        if (p.node.seq.len != first.node.seq.len) return false;
        for (first.node.seq, p.node.seq) |a, b| if (!sameNestedSequences(a, b)) return false;
    };
    if (!sparse) return true;
    for (projections) |p| {
        if (p.inherited.* != .seq or !std.mem.eql(u8, first.script.guid, p.script.guid) or !std.mem.eql(u8, first.script.source_hash, p.script.source_hash) or !std.mem.eql(u8, first.source_bytes, p.source_bytes)) return false;
        if (p.inherited.seq.len != 0 and (!model.Node.eql(first.inherited, p.inherited) or p.node.seq.len != p.inherited.seq.len)) return false;
    }
    return true;
}

// Comparison trees carry explicit intent only during equality/correspondence.
// Logical conflicts and materialized results always retain the original leaves.
pub fn comparisons(arena: A, projections: [4]Projection) A.Error!*const value.Comparisons {
    const lookup = try arena.create(value.Comparisons);
    lookup.* = .empty;
    for (projections[0..3]) |p| _ = try compareTree(arena, lookup, p, p.node, null);
    lookup.contexts = try coverageContexts(arena, projections);
    return lookup;
}
fn compareTree(arena: A, lookup: *value.Comparisons, p: Projection, n: *const model.Node, slot: ?usize) A.Error!*const model.Node {
    var result: *const model.Node = undefined;
    if (n.* == .map) {
        const entries = try arena.dupe(model.Entry, n.map);
        for (entries) |*entry| entry.value = @constCast(try compareTree(arena, lookup, p, entry.value, slot));
        result = try value.node(arena, .{ .map = entries });
    } else if (n.* == .seq) {
        const items = try arena.dupe(*model.Node, n.seq);
        for (items, 0..) |*item, i| item.* = @constCast(try compareTree(arena, lookup, p, item.*, i));
        result = try value.node(arena, .{ .seq = items });
    } else {
        var explicit = false;
        for (p.leaves) |leaf| if (leaf.node == n) {
            explicit = leaf.explicit;
            break;
        };
        const pinned = p.sparse and p.inherited.seq.len > 0;
        const items = try arena.alloc(*model.Node, if (pinned) 3 else 2);
        items[0] = @constCast(n);
        items[1] = @constCast(try value.node(arena, .{ .scalar = if (explicit) "explicit" else "inherited" }));
        if (pinned) items[2] = @constCast(try value.node(arena, .{ .scalar = try std.fmt.allocPrint(arena, "{d}", .{slot orelse 0}) }));
        result = try value.node(arena, .{ .seq = items });
    }
    try lookup.put(arena, n, result);
    return result;
}

fn coverageContexts(arena: A, ps: [4]Projection) A.Error![]const value.Nodes {
    if (!ps[0].sparse and !ps[1].sparse and !ps[2].sparse) return &.{};
    const template = for (ps[0..3]) |p| {
        if (p.node.seq.len > 0) break p.node.seq[0];
    } else return &.{};
    const base = ps[0].node.seq;
    const ours = ps[1].node.seq;
    const theirs = ps[2].node.seq;
    const om = try @import("merge_collection.zig").correspondence(arena, base, ours);
    const tm = try @import("merge_collection.zig").correspondence(arena, base, theirs);
    var contexts: std.ArrayList(value.Nodes) = .empty;
    for (base, 0..) |b, i| {
        const o = if (om[i]) |index| ours[index] else null;
        const t = if (tm[i]) |index| theirs[index] else null;
        if (!coverageEqual(template, b) or (o != null and !coverageEqual(template, o.?)) or (t != null and !coverageEqual(template, t.?))) try contexts.append(arena, .{ .base = b, .ours = o, .theirs = t });
    }
    for ([_][]const *model.Node{ ours, theirs }, 0..) |items, side| for (items) |item| {
        if (coverageEqual(template, item)) continue;
        var found = false;
        for (contexts.items) |c| if (item == c.ours or item == c.theirs) {
            found = true;
            break;
        };
        if (!found) try contexts.append(arena, if (side == 0) .{ .base = null, .ours = item, .theirs = null } else .{ .base = null, .ours = null, .theirs = item });
    };
    return contexts.toOwnedSlice(arena);
}

fn hasNestedSequence(n: *const model.Node) bool {
    if (n.* == .seq) return true;
    if (n.* == .map) for (n.map) |entry| if (hasNestedSequence(entry.value)) return true;
    return false;
}
fn sameNestedSequences(a: *const model.Node, b: *const model.Node) bool {
    if (a.* == .seq or b.* == .seq) return model.Node.eql(a, b);
    if (a.* == .map) for (a.map) |entry| {
        if (hasNestedSequence(entry.value) and !sameNestedSequences(entry.value, field(b, entry.key) orelse return false)) return false;
    };
    if (b.* == .map) for (b.map) |entry| {
        if (hasNestedSequence(entry.value) and !sameNestedSequences(field(a, entry.key) orelse return false, entry.value)) return false;
    };
    return true;
}
