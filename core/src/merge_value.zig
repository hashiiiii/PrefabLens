const std = @import("std");
const model = @import("model.zig");
const ordered = @import("merge_collection.zig");
const context = @import("merge_context.zig");
const packed_int = @import("merge_packed.zig");
const A = std.mem.Allocator;
pub const Side = enum { base, ours, theirs };
pub const Nodes = struct { base: ?*const model.Node, ours: ?*const model.Node, theirs: ?*const model.Node };
pub const Comparisons = struct {
    nodes: std.AutoHashMapUnmanaged(*const model.Node, *const model.Node) = .empty,
    contexts: []const Nodes = &.{},
    pub const empty: Comparisons = .{};
    pub fn get(self: *const Comparisons, n: *const model.Node) ?*const model.Node {
        return self.nodes.get(n);
    }
    pub fn put(self: *Comparisons, arena: A, n: *const model.Node, compared: *const model.Node) A.Error!void {
        try self.nodes.put(arena, n, compared);
    }
};
pub const Input = struct { comparisons: ?*const Comparisons = null, nodes: Nodes, schema: ?context.Field = null, context_conflict: bool = false };
pub const Reason = enum { edit_edit, delete_edit, insertion_order, ambiguous_correspondence, context_required, source_bytes, invalid_dictionary, dictionary_order };
pub const Conflict = struct { path: []const u8 = "", nodes: Nodes, reason: Reason, sequence: bool = false };
pub const Choice = union(enum) { unresolved, take: Side, remove, custom: *const model.Node };
pub const Order = enum { ours_first, theirs_first };
pub const Error = A.Error || error{ InvalidResolution, UnresolvedConflict };
const Field = struct { key: []const u8, value: *const Value };
const Piece = struct { value: *const Value, spread: bool };
const Value = union(enum) { accepted: ?*const model.Node, conflict: usize, map: []const Field, sequence: []const Piece, dictionary: Dictionary };
const Dictionary = struct { fields: []const Field, order: *const Value, base_order: *const model.Node, schema: context.Field };
// Plans borrow input nodes and own only arena-allocated plan data. Accepted leaves
// retain input pointers so source-byte writers and Variant provenance can reuse them.
pub const Plan = struct { root: *const Value, conflicts: []const Conflict, input: Input, packed_layout: ?packed_int.Layout = null, logical_nodes: ?Nodes = null };

/// Build an immutable recursive plan. Conflict indexes address the choices slice.
pub fn build(arena: A, input: Input) Error!Plan {
    if (input.comparisons) |comparisons| {
        for ([_]?*const model.Node{ input.nodes.base, input.nodes.ours, input.nodes.theirs }) |optional| if (optional) |n| try validateComparison(comparisons, n);
    }
    var conflicts: std.ArrayList(Conflict) = .empty;
    var logical = input.nodes;
    var layout: ?packed_int.Layout = null;
    var root: *const Value = undefined;
    if (input.context_conflict) {
        root = try conflict(arena, &conflicts, input.nodes, .context_required, allSequences(input.nodes));
    } else if (input.schema) |schema| {
        switch (schema.kind) {
            .int32_array => {
                logical = decodePackedNodes(arena, input.nodes) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return .{ .root = try conflict(arena, &conflicts, input.nodes, .context_required, false), .conflicts = try conflicts.toOwnedSlice(arena), .input = input },
                };
                if (eql(logical.ours, logical.theirs) and sourcePreference(input.nodes) == null)
                    return conflicted(arena, input, .source_bytes);
                const base_layout = tokenLayout(input.nodes.base);
                const ours_layout = tokenLayout(input.nodes.ours);
                const theirs_layout = tokenLayout(input.nodes.theirs);
                layout = if (ours_layout == theirs_layout or base_layout == theirs_layout) ours_layout else theirs_layout;
                root = try planValue(arena, &conflicts, logical, false, input.comparisons);
            },
            .string_dictionary, .int32_dictionary => root = try planDictionary(arena, &conflicts, input.nodes, schema, input.comparisons),
            .ordered => root = try planValue(arena, &conflicts, input.nodes, true, input.comparisons),
        }
    } else if (dictionaryShape(input.nodes) and !(eql(input.nodes.base, input.nodes.ours) and eql(input.nodes.base, input.nodes.theirs))) {
        root = try conflict(arena, &conflicts, input.nodes, .context_required, true);
    } else root = try planValue(arena, &conflicts, logical, false, input.comparisons);
    return .{ .root = root, .conflicts = try conflicts.toOwnedSlice(arena), .input = input, .packed_layout = layout, .logical_nodes = if (layout != null) logical else null };
}
pub fn conflicted(arena: A, input: Input, reason: Reason) Error!Plan {
    var conflicts: std.ArrayList(Conflict) = .empty;
    const root = try conflict(arena, &conflicts, input.nodes, reason, anySequence(input.nodes));
    return .{ .root = root, .input = input, .conflicts = try conflicts.toOwnedSlice(arena) };
}
fn alloc(arena: A, value: Value) A.Error!*const Value {
    const p = try arena.create(Value);
    p.* = value;
    return p;
}
pub fn node(arena: A, value: model.Node) A.Error!*const model.Node {
    const p = try arena.create(model.Node);
    p.* = value;
    return p;
}
fn eql(a: ?*const model.Node, b: ?*const model.Node) bool {
    if (a == null or b == null) return a == null and b == null;
    return model.Node.eql(a.?, b.?);
}
fn allSequences(n: Nodes) bool {
    var present = false;
    inline for (.{ n.base, n.ours, n.theirs }) |optional| {
        if (optional) |v| {
            present = true;
            if (v.* != .seq) return false;
        }
    }
    return present;
}
fn anySequence(n: Nodes) bool {
    inline for (.{ n.base, n.ours, n.theirs }) |v| {
        if (v) |p| {
            if (p.* == .seq) return true;
        }
    }
    return false;
}
fn conflict(arena: A, list: *std.ArrayList(Conflict), n: Nodes, reason: Reason, sequence: bool) A.Error!*const Value {
    const id = list.items.len;
    try list.append(arena, .{ .nodes = n, .reason = reason, .sequence = sequence });
    return alloc(arena, .{ .conflict = id });
}
fn planValue(arena: A, list: *std.ArrayList(Conflict), n: Nodes, ordered_schema: bool, comparisons: ?*const Comparisons) Error!*const Value {
    if (contextMatch(comparisons, n)) return conflict(arena, list, n, .context_required, anySequence(n));
    if (n.base == null and n.ours != null and n.theirs != null and n.ours.?.* == .seq and n.theirs.?.* == .seq) {
        return planValue(arena, list, .{ .base = try node(arena, .{ .seq = &.{} }), .ours = n.ours, .theirs = n.theirs }, ordered_schema, comparisons);
    }
    if (!ordered_schema and dictionaryShape(n) and !(eql(n.base, n.ours) and eql(n.base, n.theirs))) return conflict(arena, list, n, .context_required, true);
    if (comparisonEqual(comparisons, n.ours, n.theirs) or comparisonEqual(comparisons, n.base, n.theirs)) return alloc(arena, .{ .accepted = n.ours });
    if (comparisonEqual(comparisons, n.base, n.ours)) return alloc(arena, .{ .accepted = n.theirs });
    if (n.base != null and n.ours != null and n.theirs != null and n.base.?.* == .map and n.ours.?.* == .map and n.theirs.?.* == .map) {
        var fields: std.ArrayList(Field) = .empty;
        inline for (.{ n.ours.?, n.theirs.?, n.base.? }) |map| for (map.map) |entry| {
            var found = false;
            for (fields.items) |f| {
                if (std.mem.eql(u8, f.key, entry.key)) {
                    found = true;
                    break;
                }
            }
            if (found) continue;
            const first_conflict = list.items.len;
            try fields.append(arena, .{ .key = entry.key, .value = try planValue(arena, list, .{ .base = model.findValue(n.base.?.map, entry.key), .ours = model.findValue(n.ours.?.map, entry.key), .theirs = model.findValue(n.theirs.?.map, entry.key) }, false, comparisons) });
            try prefixConflicts(arena, list, first_conflict, entry.key);
        };
        return alloc(arena, .{ .map = try fields.toOwnedSlice(arena) });
    }
    if (n.base != null and n.ours != null and n.theirs != null and n.base.?.* == .seq and n.ours.?.* == .seq and n.theirs.?.* == .seq) {
        const input: ordered.Input = .{ .base = n.base.?.seq, .ours = n.ours.?.seq, .theirs = n.theirs.?.seq };
        const compared: ordered.Input = .{ .base = comparisonNode(comparisons, n.base.?).seq, .ours = comparisonNode(comparisons, n.ours.?).seq, .theirs = comparisonNode(comparisons, n.theirs.?).seq };
        const plan = ordered.build(arena, compared) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidResolution,
        };
        var pieces: std.ArrayList(Piece) = .empty;
        for (plan.segments) |segment| switch (segment) {
            .accepted => |refs| for (refs) |ref| {
                const selected = acceptedNode(input, ref, comparisons);
                const required = contextFor(comparisons, selected);
                const first = list.items.len;
                try pieces.append(arena, .{ .spread = false, .value = if (required) |required_nodes| try conflict(arena, list, required_nodes, .context_required, false) else try alloc(arena, .{ .accepted = selected }) });
                if (required != null) try prefixConflicts(arena, list, first, try std.fmt.allocPrint(arena, "[{d}]", .{ref.index}));
            },
            .conflict => |id| {
                const c = plan.conflicts[id];
                const first_conflict = list.items.len;
                // A one-item replacement bounded by proven anchors permits recursive fields.
                if (c.kind == .edit_edit and c.base.len == 1 and c.ours.len == 1 and c.theirs.len == 1 and referenced(input, c.base[0]).* == .map and referenced(input, c.ours[0]).* == .map and referenced(input, c.theirs[0]).* == .map) {
                    try pieces.append(arena, .{ .spread = false, .value = try planValue(arena, list, .{ .base = referenced(input, c.base[0]), .ours = referenced(input, c.ours[0]), .theirs = referenced(input, c.theirs[0]) }, false, comparisons) });
                } else {
                    try pieces.append(arena, .{ .spread = true, .value = try conflict(arena, list, .{ .base = try refsNode(arena, input, c.base), .ours = try refsNode(arena, input, c.ours), .theirs = try refsNode(arena, input, c.theirs) }, switch (c.kind) {
                        .edit_edit => .edit_edit,
                        .delete_edit => .delete_edit,
                        .insertion_order => .insertion_order,
                        .ambiguous_correspondence => .ambiguous_correspondence,
                    }, true) });
                }
                const path = if (c.base_end == c.base_start + 1) try std.fmt.allocPrint(arena, "[{d}]", .{c.base_start}) else try std.fmt.allocPrint(arena, "[{d}..{d}]", .{ c.base_start, c.base_end });
                try prefixConflicts(arena, list, first_conflict, path);
            },
        };
        return alloc(arena, .{ .sequence = try pieces.toOwnedSlice(arena) });
    }
    return conflict(arena, list, n, if (n.ours == null or n.theirs == null) .delete_edit else .edit_edit, anySequence(n));
}
fn acceptedNode(input: ordered.Input, ref: ordered.ItemRef, comparisons: ?*const Comparisons) *const model.Node {
    const original = referenced(input, ref);
    if (ref.side != .base) return original;
    var base_count: usize = 0;
    var ours_count: usize = 0;
    var ours: ?*const model.Node = null;
    for (input.base) |item| {
        if (comparisonEqual(comparisons, item, original)) base_count += 1;
    }
    for (input.ours) |item| {
        if (comparisonEqual(comparisons, item, original)) {
            ours_count += 1;
            ours = item;
        }
    }
    // Unique equal occurrences prove the surviving item and retain its Ours bytes.
    return if (base_count == 1 and ours_count == 1) ours.? else original;
}
fn referenced(input: ordered.Input, ref: ordered.ItemRef) *const model.Node {
    return switch (ref.side) {
        .base => input.base[ref.index],
        .ours => input.ours[ref.index],
        .theirs => input.theirs[ref.index],
    };
}
fn refsNode(arena: A, input: ordered.Input, refs: []const ordered.ItemRef) A.Error!*const model.Node {
    const items = try arena.alloc(*model.Node, refs.len);
    for (refs, items) |ref, *item| item.* = @constCast(referenced(input, ref));
    return node(arena, .{ .seq = items });
}
/// Rebuild from choices without mutating the plan; null means remove the value.
/// Dictionary keys and declared packed integers are validated before returning.
pub fn materialize(arena: A, plan: Plan, choices: []const Choice) Error!?*const model.Node {
    if (choices.len != plan.conflicts.len) return error.InvalidResolution;
    const result = try materializeValue(arena, plan.root, plan.conflicts, choices);
    if (plan.packed_layout) |layout| {
        const sequence = result orelse return null;
        if (sequence.* != .seq) return error.InvalidResolution;
        if (plan.logical_nodes) |logical| {
            const sources = [_]?*const model.Node{ plan.input.nodes.ours, plan.input.nodes.theirs, plan.input.nodes.base };
            const candidates = [_]?*const model.Node{ logical.ours, logical.theirs, logical.base };
            // Prefer the source-only change before reusing a logically equal
            // encoding. Reuse also requires the independently selected layout.
            if (sourcePreference(plan.input.nodes)) |side| {
                const index: usize = if (side == .ours) 0 else 1;
                if (eql(sequence, candidates[index]) and tokenLayout(sources[index]) == layout) return sources[index];
            }
            for (candidates, sources) |candidate, original| {
                if (eql(sequence, candidate) and tokenLayout(original) == layout) return original;
            }
        }
        const ints = try arena.alloc(i32, sequence.seq.len);
        for (sequence.seq, ints) |item, *int| {
            if (item.* != .scalar) return error.InvalidResolution;
            int.* = std.fmt.parseInt(i32, item.scalar, 10) catch return error.InvalidResolution;
        }
        // Unity serializes an empty int[] as an empty value, including typed arrays.
        if (ints.len == 0) return node(arena, .{ .scalar = "" });
        return node(arena, .{ .scalar = try packed_int.encodeInt32(arena, ints, layout) });
    }
    if (plan.input.schema) |schema| {
        if (schema.kind == .int32_array and result != null) {
            if (result.?.* == .seq) {
                const items = result.?.seq;
                const ints = try arena.alloc(i32, items.len);
                for (items, ints) |item, *int| {
                    if (item.* != .scalar) return error.InvalidResolution;
                    int.* = std.fmt.parseInt(i32, item.scalar, 10) catch return error.InvalidResolution;
                }
                const token = packedToken(plan.input.nodes.ours) orelse "";
                return node(arena, .{ .scalar = if (ints.len == 0) "" else try packed_int.encodeInt32(arena, ints, if (std.mem.endsWith(u8, token, "i")) .typed else .legacy) });
            }
            _ = packed_int.decodeInt32(arena, packedToken(result) orelse return error.InvalidResolution) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidResolution,
            };
        }
        if ((schema.kind == .string_dictionary or schema.kind == .int32_dictionary) and result != null) try validateDictionary(arena, result.?, schema);
    }
    return result;
}
fn materializeValue(arena: A, value: *const Value, conflicts: []const Conflict, choices: []const Choice) Error!?*const model.Node {
    return switch (value.*) {
        .dictionary => |dictionary| blk: {
            const order = (try materializeValue(arena, dictionary.order, conflicts, choices)) orelse return error.InvalidResolution;
            if (order.* != .seq) return error.InvalidResolution;
            var items: std.ArrayList(*model.Node) = .empty;
            var seen: std.StringHashMap(void) = .init(arena);
            const complete_order = try completeDictionaryOrder(arena, order, dictionary.base_order);
            for (complete_order.seq) |key_node| {
                if (key_node.* != .scalar or seen.contains(key_node.scalar)) return error.InvalidResolution;
                try seen.put(key_node.scalar, {});
                const field = for (dictionary.fields) |f| {
                    if (std.mem.eql(u8, f.key, key_node.scalar)) break f;
                } else return error.InvalidResolution;
                if (try materializeValue(arena, field.value, conflicts, choices)) |v| try items.append(arena, @constCast(v));
            }
            // Keep keys accepted independently of an order choice, including new keys.
            for (dictionary.fields) |f| {
                if (seen.contains(f.key)) continue;
                if (try materializeValue(arena, f.value, conflicts, choices)) |v| try items.append(arena, @constCast(v));
            }
            const result = try node(arena, .{ .seq = try items.toOwnedSlice(arena) });
            try validateDictionary(arena, result, dictionary.schema);
            break :blk result;
        },
        .accepted => |v| v,
        .conflict => |id| blk: {
            const c = conflicts[id];
            const selected: ?*const model.Node = switch (choices[id]) {
                .unresolved => return error.UnresolvedConflict,
                .remove => null,
                .custom => |v| v,
                .take => |side| switch (side) {
                    .base => c.nodes.base,
                    .ours => c.nodes.ours,
                    .theirs => c.nodes.theirs,
                },
            };
            if (c.sequence) {
                if (selected) |v| {
                    if (v.* != .seq) return error.InvalidResolution;
                }
            }
            break :blk selected;
        },
        .map => |fields| blk: {
            var entries: std.ArrayList(model.Entry) = .empty;
            for (fields) |f| {
                if (try materializeValue(arena, f.value, conflicts, choices)) |v| try entries.append(arena, .{ .key = f.key, .value = @constCast(v) });
            }
            break :blk try node(arena, .{ .map = try entries.toOwnedSlice(arena) });
        },
        .sequence => |pieces| blk: {
            var items: std.ArrayList(*model.Node) = .empty;
            for (pieces) |p| {
                if (try materializeValue(arena, p.value, conflicts, choices)) |v| {
                    if (p.spread) {
                        if (v.* != .seq) return error.InvalidResolution;
                        try items.appendSlice(arena, v.seq);
                    } else try items.append(arena, @constCast(v));
                }
            }
            break :blk try node(arena, .{ .seq = try items.toOwnedSlice(arena) });
        },
    };
}
pub fn combined(arena: A, c: Conflict, order: Order) Error!*const model.Node {
    if (c.reason != .insertion_order) return error.InvalidResolution;
    const first = if (order == .ours_first) c.nodes.ours.? else c.nodes.theirs.?;
    const second = if (order == .ours_first) c.nodes.theirs.? else c.nodes.ours.?;
    return node(arena, .{ .seq = try std.mem.concat(arena, *model.Node, &.{ first.seq, second.seq }) });
}

fn sourcePreference(n: Nodes) ?Side {
    if (eql(n.ours, n.theirs) or eql(n.base, n.theirs)) return .ours;
    if (eql(n.base, n.ours)) return .theirs;
    return null;
}
fn tokenLayout(n: ?*const model.Node) packed_int.Layout {
    return if (std.mem.endsWith(u8, packedToken(n) orelse "", "i")) .typed else .legacy;
}
fn packedToken(n: ?*const model.Node) ?[]const u8 {
    const v = n orelse return "";
    return switch (v.*) {
        .scalar => v.scalar,
        .map => if (v.map.len == 0) "" else null,
        else => null,
    };
}
fn decodePackedNode(arena: A, n: ?*const model.Node) Error!?*const model.Node {
    if (n == null) return null;
    const decoded = packed_int.decodeInt32(arena, packedToken(n) orelse return error.InvalidResolution) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResolution,
    };
    const items = try arena.alloc(*model.Node, decoded.values.len);
    for (decoded.values, items) |int, *item| item.* = @constCast(try node(arena, .{ .scalar = try std.fmt.allocPrint(arena, "{d}", .{int}) }));
    return node(arena, .{ .seq = items });
}
fn decodePackedNodes(arena: A, n: Nodes) Error!Nodes {
    return .{ .base = try decodePackedNode(arena, n.base), .ours = try decodePackedNode(arena, n.ours), .theirs = try decodePackedNode(arena, n.theirs) };
}
fn dictionaryShape(n: Nodes) bool {
    for ([_]?*const model.Node{ n.base, n.ours, n.theirs }) |optional| {
        if (optional) |v| {
            if (v.* != .seq) continue;
            for (v.seq) |item| {
                if (item.* == .map and model.findValue(item.map, "key") != null and model.findValue(item.map, "value") != null) return true;
            }
        }
    }
    return false;
}
fn dictionaryKey(arena: A, item: *const model.Node, schema: context.Field) Error![]const u8 {
    if (item.* != .map or item.map.len != 2) return error.InvalidResolution;
    const key = model.findValue(item.map, "key") orelse return error.InvalidResolution;
    const v = model.findValue(item.map, "value") orelse return error.InvalidResolution;
    if (key.* != .scalar or v.* != .scalar) return error.InvalidResolution;
    switch (schema.dictionary_value orelse return error.InvalidResolution) {
        .int32 => {
            _ = std.fmt.parseInt(i32, v.scalar, 10) catch return error.InvalidResolution;
        },
        .string => {},
    }
    if (schema.kind == .int32_dictionary) {
        const int = std.fmt.parseInt(i32, key.scalar, 10) catch return error.InvalidResolution;
        return std.fmt.allocPrint(arena, "{d}", .{int});
    }
    // Unity's declared string fields retain null and ~ as literal strings.
    if (schema.kind != .string_dictionary) return error.InvalidResolution;
    return key.scalar;
}
pub fn validateDictionary(arena: A, n: *const model.Node, schema: context.Field) Error!void {
    if (n.* != .seq) return error.InvalidResolution;
    var keys: std.StringHashMap(void) = .init(arena);
    for (n.seq) |item| {
        const key = try dictionaryKey(arena, item, schema);
        if (keys.contains(key)) return error.InvalidResolution;
        try keys.put(key, {});
    }
}
fn dictionaryItems(n: ?*const model.Node) []const *model.Node {
    const v = n orelse return &.{};
    return if (v.* == .seq) v.seq else &.{};
}
fn dictionaryItem(arena: A, n: ?*const model.Node, key: []const u8, schema: context.Field) Error!?*const model.Node {
    for (dictionaryItems(n)) |item| {
        if (std.mem.eql(u8, try dictionaryKey(arena, item, schema), key)) return item;
    }
    return null;
}
fn keyOrder(arena: A, n: ?*const model.Node, schema: context.Field, base: ?*const model.Node, common: Nodes) Error!*const model.Node {
    var items: std.ArrayList(*model.Node) = .empty;
    for (dictionaryItems(n)) |item| {
        const key = try dictionaryKey(arena, item, schema);
        if (base != null) {
            if (try dictionaryItem(arena, base, key, schema) == null or try dictionaryItem(arena, common.ours, key, schema) == null or try dictionaryItem(arena, common.theirs, key, schema) == null) continue;
        }
        try items.append(arena, @constCast(try node(arena, .{ .scalar = key })));
    }
    return node(arena, .{ .seq = try items.toOwnedSlice(arena) });
}
fn planDictionary(arena: A, list: *std.ArrayList(Conflict), n: Nodes, schema: context.Field, comparisons: ?*const Comparisons) Error!*const Value {
    if (n.base == null and n.ours != null and n.theirs != null and n.ours.?.* == .seq and n.theirs.?.* == .seq) {
        return planDictionary(arena, list, .{ .base = try node(arena, .{ .seq = &.{} }), .ours = n.ours, .theirs = n.theirs }, schema, comparisons);
    }
    if (schema.dictionary_equality != .default) return conflict(arena, list, n, .context_required, true);
    inline for (.{ n.base, n.ours, n.theirs }) |optional| {
        if (optional) |v| {
            validateDictionary(arena, v, schema) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return conflict(arena, list, n, .invalid_dictionary, true),
            };
        }
    }
    if (comparisonEqual(comparisons, n.ours, n.theirs) or comparisonEqual(comparisons, n.base, n.theirs)) return alloc(arena, .{ .accepted = n.ours });
    if (comparisonEqual(comparisons, n.base, n.ours)) return alloc(arena, .{ .accepted = n.theirs });
    if (n.base == null or n.ours == null or n.theirs == null) return conflict(arena, list, n, .delete_edit, true);
    var fields: std.ArrayList(Field) = .empty;
    // Base keys retain their position; independent new keys append Ours then Theirs.
    inline for (.{ n.base, n.ours, n.theirs }) |optional| for (dictionaryItems(optional)) |item| {
        const key = try dictionaryKey(arena, item, schema);
        var exists = false;
        for (fields.items) |f| {
            if (std.mem.eql(u8, f.key, key)) {
                exists = true;
                break;
            }
        }
        if (exists) continue;
        const first_conflict = list.items.len;
        try fields.append(arena, .{ .key = key, .value = try planValue(arena, list, .{ .base = try dictionaryItem(arena, n.base, key, schema), .ours = try dictionaryItem(arena, n.ours, key, schema), .theirs = try dictionaryItem(arena, n.theirs, key, schema) }, false, comparisons) });
        try prefixConflicts(arena, list, first_conflict, try std.fmt.allocPrint(arena, "[{s}]", .{key}));
    };
    const base = try keyOrder(arena, n.base, schema, n.base, n);
    const ours = try keyOrder(arena, n.ours, schema, n.base, n);
    const theirs = try keyOrder(arena, n.theirs, schema, n.base, n);
    const order = if (eql(ours, theirs) or eql(base, theirs)) try alloc(arena, .{ .accepted = try keyOrder(arena, n.ours, schema, null, n) }) else if (eql(base, ours)) try alloc(arena, .{ .accepted = try keyOrder(arena, n.theirs, schema, null, n) }) else try conflict(arena, list, .{ .base = try keyOrder(arena, n.base, schema, null, n), .ours = try keyOrder(arena, n.ours, schema, null, n), .theirs = try keyOrder(arena, n.theirs, schema, null, n) }, .dictionary_order, true);
    return alloc(arena, .{ .dictionary = .{ .fields = try fields.toOwnedSlice(arena), .order = order, .base_order = try keyOrder(arena, n.base, schema, null, n), .schema = schema } });
}

test "value materialization preserves leaf pointer provenance" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const yaml = @import("merge_yaml.zig");
    const b = try yaml.parseValue(arena, "[{left: 1, right: 1, keep: original}]");
    const o = try yaml.parseValue(arena, "[{left: 2, right: 1, keep: original}]");
    const t = try yaml.parseValue(arena, "[{left: 1, right: 3, keep: original}]");
    const plan = try build(arena, .{ .nodes = .{ .base = b, .ours = o, .theirs = t } });
    const result = (try materialize(arena, plan, &.{})).?;
    try std.testing.expect(model.findValue(result.seq[0].map, "left").? == model.findValue(o.seq[0].map, "left").?);
    try std.testing.expect(model.findValue(result.seq[0].map, "right").? == model.findValue(t.seq[0].map, "right").?);
    try std.testing.expect(model.findValue(result.seq[0].map, "keep").? == model.findValue(o.seq[0].map, "keep").?);
}

fn keyIndex(items: []const *model.Node, key: []const u8) ?usize {
    for (items, 0..) |item, i| {
        if (item.* == .scalar and std.mem.eql(u8, item.scalar, key)) return i;
    }
    return null;
}
fn completeDictionaryOrder(arena: A, chosen: *const model.Node, base: *const model.Node) Error!*const model.Node {
    var items: std.ArrayList(*model.Node) = .empty;
    try items.appendSlice(arena, chosen.seq);
    for (base.seq, 0..) |key, i| {
        if (keyIndex(items.items, key.scalar) != null) continue;
        var position: ?usize = null;
        for (base.seq[i + 1 ..]) |next| {
            if (keyIndex(items.items, next.scalar)) |index| {
                position = index;
                break;
            }
        }
        if (position == null) {
            var previous = i;
            while (previous > 0) {
                previous -= 1;
                if (keyIndex(items.items, base.seq[previous].scalar)) |index| {
                    position = index + 1;
                    break;
                }
            }
        }
        // A restored key returns next to surviving base keys, independently of
        // its value choice. New keys keep the selected side's serialized order.
        try items.insert(arena, position orelse items.items.len, key);
    }
    return node(arena, .{ .seq = try items.toOwnedSlice(arena) });
}

fn prefixConflicts(arena: A, list: *std.ArrayList(Conflict), first: usize, prefix: []const u8) A.Error!void {
    for (list.items[first..]) |*c| {
        c.path = if (c.path.len == 0) prefix else try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ prefix, if (c.path[0] == '[') "" else ".", c.path });
    }
}

pub const Origin = struct { normalized: *const model.Node, original: *const model.Node };
pub const Normalized = struct { nodes: Nodes, origins: []const Origin };
/// blank_strings must contain only nodes whose serialized value span is blank.
/// An explicit empty map is never string evidence, including in custom input.
pub fn normalizeDictionaryStrings(arena: A, n: Nodes, schema: context.Field, blank_strings: []const *const model.Node) A.Error!Normalized {
    var origins: std.ArrayList(Origin) = .empty;
    return .{ .nodes = .{
        .base = try normalizeDictionaryNode(arena, n.base, schema, blank_strings, &origins),
        .ours = try normalizeDictionaryNode(arena, n.ours, schema, blank_strings, &origins),
        .theirs = try normalizeDictionaryNode(arena, n.theirs, schema, blank_strings, &origins),
    }, .origins = try origins.toOwnedSlice(arena) };
}
fn normalizeDictionaryNode(arena: A, optional: ?*const model.Node, schema: context.Field, blanks: []const *const model.Node, origins: *std.ArrayList(Origin)) A.Error!?*const model.Node {
    const original = optional orelse return null;
    if (original.* != .seq) return original;
    const items = try arena.dupe(*model.Node, original.seq);
    var changed = false;
    for (items) |*item| {
        if (item.*.* != .map) continue;
        const entries = try arena.dupe(model.Entry, item.*.map);
        var item_changed = false;
        for (entries) |*entry| {
            const string_position = (schema.kind == .string_dictionary and std.mem.eql(u8, entry.key, "key")) or
                (schema.dictionary_value == .string and std.mem.eql(u8, entry.key, "value"));
            if (!string_position or entry.value.* != .map or entry.value.map.len != 0) continue;
            var blank = false;
            for (blanks) |candidate| {
                if (entry.value == candidate) {
                    blank = true;
                    break;
                }
            }
            if (!blank) continue;
            const normalized = try node(arena, .{ .scalar = "" });
            try origins.append(arena, .{ .normalized = normalized, .original = entry.value });
            entry.value = @constCast(normalized);
            item_changed = true;
        }
        if (item_changed) {
            const normalized = try node(arena, .{ .map = entries });
            try origins.append(arena, .{ .normalized = normalized, .original = item.* });
            item.* = @constCast(normalized);
            changed = true;
        }
    }
    if (!changed) return original;
    const normalized = try node(arena, .{ .seq = items });
    try origins.append(arena, .{ .normalized = normalized, .original = original });
    return normalized;
}

test "value packed byte-only choices retain their source or expose a conflict" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const yaml = @import("merge_yaml.zig");
    const schema: context.Field = .{ .path = "values", .kind = .int32_array };
    const b = try yaml.parseValue(arena, "ffffffff");
    const o = try yaml.parseValue(arena, "FFFFFFFF");
    const t = try yaml.parseValue(arena, "ffffffffi");
    const plan = try build(arena, .{ .nodes = .{ .base = b, .ours = o, .theirs = t }, .schema = schema });
    try std.testing.expectEqual(@as(usize, 1), plan.conflicts.len);
    try std.testing.expectEqual(Reason.source_bytes, plan.conflicts[0].reason);
    const selected = (try materialize(arena, plan, &.{.{ .take = .theirs }})).?;
    try std.testing.expect(selected == t);
}

fn comparisonNode(comparisons: ?*const Comparisons, n: *const model.Node) *const model.Node {
    return if (comparisons) |lookup| lookup.get(n) orelse n else n;
}
fn comparisonEqual(comparisons: ?*const Comparisons, a: ?*const model.Node, b: ?*const model.Node) bool {
    if (a == null or b == null) return a == null and b == null;
    if (comparisons) |policy| for (policy.contexts) |c| {
        for ([_]?*const model.Node{ c.base, c.ours, c.theirs }) |optional| if (optional) |target| {
            if (containsNode(a.?, target) or containsNode(b.?, target)) return false;
        };
    };
    return model.Node.eql(comparisonNode(comparisons, a.?), comparisonNode(comparisons, b.?));
}

test "comparison projections reject mismatched sequence shape before occurrence planning" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const logical = try @import("merge_yaml.zig").parseValue(arena, "[A, B]");
    const other = try @import("merge_yaml.zig").parseValue(arena, "[A]");
    var comparisons: Comparisons = .empty;
    try comparisons.put(arena, logical, other);
    try std.testing.expectError(error.InvalidResolution, build(arena, .{ .nodes = .{ .base = logical, .ours = logical, .theirs = logical }, .comparisons = &comparisons }));
}

fn validateComparison(comparisons: *const Comparisons, n: *const model.Node) Error!void {
    const compared = comparisons.get(n) orelse n;
    switch (n.*) {
        .map => |entries| {
            if (compared.* != .map or compared.map.len != entries.len) return error.InvalidResolution;
            for (entries, compared.map) |entry, other| {
                if (!std.mem.eql(u8, entry.key, other.key) or other.value != (comparisons.get(entry.value) orelse entry.value)) return error.InvalidResolution;
                try validateComparison(comparisons, entry.value);
            }
        },
        .seq => |items| {
            if (compared.* != .seq or compared.seq.len != items.len) return error.InvalidResolution;
            for (items, compared.seq) |item, other| {
                if (other != (comparisons.get(item) orelse item)) return error.InvalidResolution;
                try validateComparison(comparisons, item);
            }
        },
        .scalar, .ref => {},
    }
}

fn containsNode(n: *const model.Node, target: *const model.Node) bool {
    if (n == target) return true;
    switch (n.*) {
        .map => |entries| for (entries) |entry| {
            if (containsNode(entry.value, target)) return true;
        },
        .seq => |items| for (items) |item| {
            if (containsNode(item, target)) return true;
        },
        else => {},
    }
    return false;
}
fn contextFor(comparisons: ?*const Comparisons, n: *const model.Node) ?Nodes {
    if (comparisons) |policy| for (policy.contexts) |c| {
        if (n == c.base or n == c.ours or n == c.theirs) return c;
    };
    return null;
}
fn contextMatch(comparisons: ?*const Comparisons, n: Nodes) bool {
    for ([_]?*const model.Node{ n.base, n.ours, n.theirs }) |optional| if (optional) |v| {
        if (contextFor(comparisons, v) != null) return true;
    };
    return false;
}
