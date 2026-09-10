const std = @import("std");
const model = @import("model.zig");
const ordered = @import("merge_collection.zig");
const context = @import("merge_context.zig");
const packed_int = @import("merge_packed.zig");
const dictionary = @import("merge_dictionary.zig");
const A = std.mem.Allocator;
pub const Side = enum { base, ours, theirs };
pub const Nodes = struct { base: ?*const model.Node, ours: ?*const model.Node, theirs: ?*const model.Node };
pub const Input = struct {
    nodes: Nodes,
    schema: ?context.Field = null,
    context_conflict: bool = false,
};
pub const Reason = enum { edit_edit, delete_edit, insertion_order, ambiguous_correspondence, context_required, source_bytes };
pub const Conflict = struct { path: []const u8 = "", nodes: Nodes, reason: Reason, sequence: bool = false };
pub const Choice = union(enum) { unresolved, take: Side, remove, custom: *const model.Node };
pub const Order = enum { ours_first, theirs_first };
pub const Error = A.Error || error{ InvalidResolution, UnresolvedConflict };
const Field = struct { key: []const u8, value: *const Value };
const Piece = struct { value: *const Value, spread: bool };
const Value = union(enum) { accepted: ?*const model.Node, conflict: usize, map: []const Field, sequence: []const Piece };
// Plans borrow input nodes and own only arena-allocated plan data. Accepted leaves
// retain input pointers so source-byte writers can reuse their original formatting.
pub const Plan = struct { root: *const Value, conflicts: []const Conflict, input: Input, packed_layout: ?packed_int.Layout = null, logical_nodes: ?Nodes = null };

/// Build an immutable recursive plan. Conflict indexes address the choices slice.
pub fn build(arena: A, input: Input) Error!Plan {
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
                root = try planValue(arena, &conflicts, logical, false);
            },
            .ordered => root = try planValue(arena, &conflicts, input.nodes, true),
            .dictionary => root = try planDictionary(arena, &conflicts, input.nodes) orelse
                try conflict(arena, &conflicts, input.nodes, .context_required, anySequence(input.nodes)),
        }
    } else if (try planDictionary(arena, &conflicts, input.nodes)) |planned| {
        root = planned;
    } else root = try planValue(arena, &conflicts, logical, false);
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

fn planDictionary(arena: A, list: *std.ArrayList(Conflict), n: Nodes) Error!?*const Value {
    if (n.ours == null or n.theirs == null) return null;
    switch (dictionary.detect(n.base, n.ours, n.theirs)) {
        .none => return null,
        .malformed => return try conflict(arena, list, n, .context_required, anySequence(n)),
        .shape => |shape| {
            if (eql(n.ours, n.theirs) or eql(n.base, n.theirs)) return alloc(arena, .{ .accepted = n.ours });
            if (eql(n.base, n.ours)) return alloc(arena, .{ .accepted = n.theirs });
            const base_entries = (try dictionary.entries(arena, n.base, shape)) orelse
                return try conflict(arena, list, n, .context_required, anySequence(n));
            const ours_entries = (try dictionary.entries(arena, n.ours, shape)) orelse
                return try conflict(arena, list, n, .context_required, anySequence(n));
            const theirs_entries = (try dictionary.entries(arena, n.theirs, shape)) orelse
                return try conflict(arena, list, n, .context_required, anySequence(n));
            if (dictionary.sharedOrderChanged(ours_entries, base_entries) and
                dictionary.sharedOrderChanged(theirs_entries, base_entries) and
                sharedKeyOrderDiffers(ours_entries, theirs_entries))
            {
                return try conflict(arena, list, n, .insertion_order, true);
            }
            const use_theirs_order = dictionary.sharedOrderChanged(theirs_entries, base_entries) and
                !dictionary.sharedOrderChanged(ours_entries, base_entries);
            const primary = if (use_theirs_order) theirs_entries else ours_entries;
            const secondary = if (use_theirs_order) ours_entries else theirs_entries;
            const keys = try mergeKeyOrder(arena, primary, secondary);
            return switch (shape) {
                .pair_key_value, .pair_first_second => try planPairEntries(
                    arena,
                    list,
                    shape,
                    keys,
                    base_entries,
                    ours_entries,
                    theirs_entries,
                ),
                .parallel => try planParallelEntries(
                    arena,
                    list,
                    n,
                    keys,
                    base_entries,
                    ours_entries,
                    theirs_entries,
                ),
            };
        },
    }
}

fn sharedKeyOrderDiffers(ours: []const dictionary.Entry, theirs: []const dictionary.Entry) bool {
    var ours_i: usize = 0;
    var theirs_i: usize = 0;
    while (true) {
        while (ours_i < ours.len and dictionary.find(theirs, ours[ours_i].key) == null) ours_i += 1;
        while (theirs_i < theirs.len and dictionary.find(ours, theirs[theirs_i].key) == null) theirs_i += 1;
        if (ours_i == ours.len or theirs_i == theirs.len) return ours_i != ours.len or theirs_i != theirs.len;
        if (!model.Node.eql(ours[ours_i].key, theirs[theirs_i].key)) return true;
        ours_i += 1;
        theirs_i += 1;
    }
}

fn mergeKeyOrder(
    arena: A,
    primary: []const dictionary.Entry,
    secondary: []const dictionary.Entry,
) A.Error![]const *const model.Node {
    var keys: std.ArrayList(*const model.Node) = .empty;
    for (primary) |entry| try keys.append(arena, entry.key);
    for (secondary) |entry| {
        if (dictionary.contains(primary, entry.key)) continue;
        var insert_at = keys.items.len;
        if (indexOfEntry(secondary, entry.key)) |here| {
            var previous = here;
            while (previous > 0) {
                previous -= 1;
                if (indexOfKey(keys.items, secondary[previous].key)) |idx| {
                    insert_at = idx + 1;
                    while (insert_at < keys.items.len and dictionary.find(secondary, keys.items[insert_at]) == null)
                        insert_at += 1;
                    break;
                }
            }
        }
        try keys.insert(arena, insert_at, entry.key);
    }
    return keys.items;
}

fn indexOfEntry(list: []const dictionary.Entry, key: *const model.Node) ?usize {
    for (list, 0..) |entry, i| {
        if (model.Node.eql(entry.key, key)) return i;
    }
    return null;
}

fn indexOfKey(list: []const *const model.Node, key: *const model.Node) ?usize {
    for (list, 0..) |item, i| {
        if (model.Node.eql(item, key)) return i;
    }
    return null;
}

fn planPairEntries(
    arena: A,
    list: *std.ArrayList(Conflict),
    shape: dictionary.Shape,
    keys: []const *const model.Node,
    base_entries: []const dictionary.Entry,
    ours_entries: []const dictionary.Entry,
    theirs_entries: []const dictionary.Entry,
) Error!*const Value {
    var pieces: std.ArrayList(Piece) = .empty;
    for (keys) |key| {
        const first_conflict = list.items.len;
        const planned = try planDictionaryEntry(
            arena,
            list,
            dictionary.find(base_entries, key),
            dictionary.find(ours_entries, key),
            dictionary.find(theirs_entries, key),
            shape,
        );
        if (planned) |value| try pieces.append(arena, .{ .spread = false, .value = value });
        try prefixConflicts(arena, list, first_conflict, try dictionaryKeyPath(arena, key));
    }
    return alloc(arena, .{ .sequence = try pieces.toOwnedSlice(arena) });
}

fn planParallelEntries(
    arena: A,
    list: *std.ArrayList(Conflict),
    n: Nodes,
    keys: []const *const model.Node,
    base_entries: []const dictionary.Entry,
    ours_entries: []const dictionary.Entry,
    theirs_entries: []const dictionary.Entry,
) Error!*const Value {
    var key_nodes: std.ArrayList(*model.Node) = .empty;
    var value_pieces: std.ArrayList(Piece) = .empty;
    for (keys) |key| {
        const first_conflict = list.items.len;
        const base_entry = dictionary.find(base_entries, key);
        const ours_entry = dictionary.find(ours_entries, key);
        const theirs_entry = dictionary.find(theirs_entries, key);
        const planned = try planDictionaryValue(
            arena,
            list,
            if (base_entry) |e| e.value else null,
            if (ours_entry) |e| e.value else null,
            if (theirs_entry) |e| e.value else null,
        );
        if (planned) |value| {
            try key_nodes.append(arena, @constCast(if (ours_entry) |e| e.key else if (theirs_entry) |e| e.key else key));
            try value_pieces.append(arena, .{ .spread = false, .value = value });
        }
        try prefixConflicts(arena, list, first_conflict, try dictionaryKeyPath(arena, key));
    }
    var fields: std.ArrayList(Field) = .empty;
    const template = n.ours.?;
    if (template.* == .map) {
        for (template.map) |entry| {
            if (std.mem.eql(u8, entry.key, "m_Keys") or std.mem.eql(u8, entry.key, "m_Values")) continue;
            try fields.append(arena, .{
                .key = entry.key,
                .value = try planValue(arena, list, .{
                    .base = if (n.base) |base| base.get(entry.key) else null,
                    .ours = n.ours.?.get(entry.key),
                    .theirs = if (n.theirs) |theirs| theirs.get(entry.key) else null,
                }, false),
            });
        }
    }
    const key_seq = try alloc(arena, .{ .accepted = try node(arena, .{ .seq = try key_nodes.toOwnedSlice(arena) }) });
    const value_seq = try alloc(arena, .{ .sequence = try value_pieces.toOwnedSlice(arena) });
    try fields.append(arena, .{ .key = "m_Keys", .value = key_seq });
    try fields.append(arena, .{ .key = "m_Values", .value = value_seq });
    return alloc(arena, .{ .map = try fields.toOwnedSlice(arena) });
}

fn planDictionaryEntry(
    arena: A,
    list: *std.ArrayList(Conflict),
    base_entry: ?dictionary.Entry,
    ours_entry: ?dictionary.Entry,
    theirs_entry: ?dictionary.Entry,
    shape: dictionary.Shape,
) Error!?*const Value {
    _ = shape;
    if (base_entry == null) {
        if (ours_entry == null) return alloc(arena, .{ .accepted = theirs_entry.?.item });
        if (theirs_entry == null) return alloc(arena, .{ .accepted = ours_entry.?.item });
        if (model.Node.eql(ours_entry.?.item, theirs_entry.?.item)) return alloc(arena, .{ .accepted = ours_entry.?.item });
        return try conflict(arena, list, .{
            .base = null,
            .ours = ours_entry.?.item,
            .theirs = theirs_entry.?.item,
        }, .edit_edit, false);
    }
    if (ours_entry == null and theirs_entry == null) return null;
    if (ours_entry == null) {
        if (model.Node.eql(theirs_entry.?.item, base_entry.?.item)) return null;
        return try conflict(arena, list, .{
            .base = base_entry.?.item,
            .ours = null,
            .theirs = theirs_entry.?.item,
        }, .delete_edit, false);
    }
    if (theirs_entry == null) {
        if (model.Node.eql(ours_entry.?.item, base_entry.?.item)) return null;
        return try conflict(arena, list, .{
            .base = base_entry.?.item,
            .ours = ours_entry.?.item,
            .theirs = null,
        }, .delete_edit, false);
    }
    if (leafDictionaryValue(ours_entry.?.value) and leafDictionaryValue(theirs_entry.?.value) and
        leafDictionaryValue(base_entry.?.value))
    {
        if (eql(ours_entry.?.item, theirs_entry.?.item) or eql(base_entry.?.item, theirs_entry.?.item))
            return alloc(arena, .{ .accepted = ours_entry.?.item });
        if (eql(base_entry.?.item, ours_entry.?.item))
            return alloc(arena, .{ .accepted = theirs_entry.?.item });
        return try conflict(arena, list, .{
            .base = base_entry.?.item,
            .ours = ours_entry.?.item,
            .theirs = theirs_entry.?.item,
        }, .edit_edit, false);
    }
    return planValue(arena, list, .{
        .base = base_entry.?.item,
        .ours = ours_entry.?.item,
        .theirs = theirs_entry.?.item,
    }, false);
}

fn leafDictionaryValue(n: *const model.Node) bool {
    return n.* != .map and n.* != .seq;
}

fn planDictionaryValue(
    arena: A,
    list: *std.ArrayList(Conflict),
    base_value: ?*const model.Node,
    ours_value: ?*const model.Node,
    theirs_value: ?*const model.Node,
) Error!?*const Value {
    if (base_value == null) {
        if (ours_value == null) return alloc(arena, .{ .accepted = theirs_value });
        if (theirs_value == null) return alloc(arena, .{ .accepted = ours_value });
        if (eql(ours_value, theirs_value)) return alloc(arena, .{ .accepted = ours_value });
        return try conflict(arena, list, .{ .base = null, .ours = ours_value, .theirs = theirs_value }, .edit_edit, false);
    }
    if (ours_value == null and theirs_value == null) return null;
    if (ours_value == null) {
        if (eql(theirs_value, base_value)) return null;
        return try conflict(arena, list, .{ .base = base_value, .ours = null, .theirs = theirs_value }, .delete_edit, false);
    }
    if (theirs_value == null) {
        if (eql(ours_value, base_value)) return null;
        return try conflict(arena, list, .{ .base = base_value, .ours = ours_value, .theirs = null }, .delete_edit, false);
    }
    return planValue(arena, list, .{ .base = base_value, .ours = ours_value, .theirs = theirs_value }, false);
}

fn dictionaryKeyPath(arena: A, key: *const model.Node) A.Error![]const u8 {
    return dictionary.keyBracket(arena, key);
}

fn planValue(arena: A, list: *std.ArrayList(Conflict), n: Nodes, ordered_schema: bool) Error!*const Value {
    if (n.base == null and n.ours != null and n.theirs != null and n.ours.?.* == .seq and n.theirs.?.* == .seq) {
        return planValue(arena, list, .{ .base = try node(arena, .{ .seq = &.{} }), .ours = n.ours, .theirs = n.theirs }, ordered_schema);
    }
    if (!ordered_schema) {
        if (try planDictionary(arena, list, n)) |planned| return planned;
    }
    if (eql(n.ours, n.theirs) or eql(n.base, n.theirs)) return alloc(arena, .{ .accepted = n.ours });
    if (eql(n.base, n.ours)) return alloc(arena, .{ .accepted = n.theirs });
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
            try fields.append(arena, .{ .key = entry.key, .value = try planValue(arena, list, .{ .base = model.findValue(n.base.?.map, entry.key), .ours = model.findValue(n.ours.?.map, entry.key), .theirs = model.findValue(n.theirs.?.map, entry.key) }, false) });
            try prefixConflicts(arena, list, first_conflict, entry.key);
        };
        return alloc(arena, .{ .map = try fields.toOwnedSlice(arena) });
    }
    if (n.base != null and n.ours != null and n.theirs != null and n.base.?.* == .seq and n.ours.?.* == .seq and n.theirs.?.* == .seq) {
        const input: ordered.Input = .{ .base = n.base.?.seq, .ours = n.ours.?.seq, .theirs = n.theirs.?.seq };
        const plan = ordered.build(arena, input) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidResolution,
        };
        var pieces: std.ArrayList(Piece) = .empty;
        for (plan.segments) |segment| switch (segment) {
            .accepted => |refs| for (refs) |ref| {
                const selected = acceptedNode(input, ref);
                try pieces.append(arena, .{ .spread = false, .value = try alloc(arena, .{ .accepted = selected }) });
            },
            .conflict => |id| {
                const c = plan.conflicts[id];
                const first_conflict = list.items.len;
                // A one-item replacement bounded by proven anchors permits recursive fields.
                if (c.kind == .edit_edit and c.base.len == 1 and c.ours.len == 1 and c.theirs.len == 1 and referenced(input, c.base[0]).* == .map and referenced(input, c.ours[0]).* == .map and referenced(input, c.theirs[0]).* == .map) {
                    try pieces.append(arena, .{ .spread = false, .value = try planValue(arena, list, .{ .base = referenced(input, c.base[0]), .ours = referenced(input, c.ours[0]), .theirs = referenced(input, c.theirs[0]) }, false) });
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
fn acceptedNode(input: ordered.Input, ref: ordered.ItemRef) *const model.Node {
    const original = referenced(input, ref);
    if (ref.side != .base) return original;
    var base_count: usize = 0;
    var ours_count: usize = 0;
    var ours: ?*const model.Node = null;
    for (input.base) |item| {
        if (eql(item, original)) base_count += 1;
    }
    for (input.ours) |item| {
        if (eql(item, original)) {
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
/// Declared packed integers are validated before returning.
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
    }
    return result;
}
fn materializeValue(arena: A, value: *const Value, conflicts: []const Conflict, choices: []const Choice) Error!?*const model.Node {
    return switch (value.*) {
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

fn prefixConflicts(arena: A, list: *std.ArrayList(Conflict), first: usize, prefix: []const u8) A.Error!void {
    for (list.items[first..]) |*c| {
        c.path = if (c.path.len == 0) prefix else try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ prefix, if (c.path[0] == '[') "" else ".", c.path });
    }
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

test "value keyed pairs merge independent key insertions" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const yaml = @import("merge_yaml.zig");
    const b = try yaml.parseValue(arena, "[{key: a, value: 1}]");
    const o = try yaml.parseValue(arena, "[{key: a, value: 1}, {key: b, value: 2}]");
    const t = try yaml.parseValue(arena, "[{key: a, value: 1}, {key: c, value: 3}]");
    const plan = try build(arena, .{ .nodes = .{ .base = b, .ours = o, .theirs = t } });
    try std.testing.expectEqual(@as(usize, 0), plan.conflicts.len);
    const result = (try materialize(arena, plan, &.{})).?;
    try std.testing.expectEqual(@as(usize, 3), result.seq.len);
    try std.testing.expectEqualStrings("a", model.findValue(result.seq[0].map, "key").?.scalar);
    try std.testing.expectEqualStrings("b", model.findValue(result.seq[1].map, "key").?.scalar);
    try std.testing.expectEqualStrings("c", model.findValue(result.seq[2].map, "key").?.scalar);
    try std.testing.expectEqualStrings("2", model.findValue(result.seq[1].map, "value").?.scalar);
    try std.testing.expectEqualStrings("3", model.findValue(result.seq[2].map, "value").?.scalar);
}

test "value keyed pairs conflict when both sides edit the same key" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const yaml = @import("merge_yaml.zig");
    const b = try yaml.parseValue(arena, "[{key: a, value: 1}]");
    const o = try yaml.parseValue(arena, "[{key: a, value: 2}]");
    const t = try yaml.parseValue(arena, "[{key: a, value: 3}]");
    const plan = try build(arena, .{ .nodes = .{ .base = b, .ours = o, .theirs = t } });
    try std.testing.expectEqual(@as(usize, 1), plan.conflicts.len);
    try std.testing.expectEqual(Reason.edit_edit, plan.conflicts[0].reason);
    try std.testing.expectEqualStrings("[a]", plan.conflicts[0].path);
}

test "value keyed first-second pairs and parallel keys merge by key" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const yaml = @import("merge_yaml.zig");
    const pair_b = try yaml.parseValue(arena, "[{first: a, second: 1}]");
    const pair_o = try yaml.parseValue(arena, "[{first: a, second: 1}, {first: b, second: 2}]");
    const pair_t = try yaml.parseValue(arena, "[{first: a, second: 1}, {first: c, second: 3}]");
    const pair_plan = try build(arena, .{ .nodes = .{ .base = pair_b, .ours = pair_o, .theirs = pair_t } });
    try std.testing.expectEqual(@as(usize, 0), pair_plan.conflicts.len);
    const pair = (try materialize(arena, pair_plan, &.{})).?;
    try std.testing.expectEqual(@as(usize, 3), pair.seq.len);
    try std.testing.expectEqualStrings("b", model.findValue(pair.seq[1].map, "first").?.scalar);
    try std.testing.expectEqualStrings("c", model.findValue(pair.seq[2].map, "first").?.scalar);

    const par_b = try yaml.parseValue(arena, "{m_Keys: [a], m_Values: [1]}");
    try std.testing.expect(par_b.* == .map);
    try std.testing.expect(par_b.get("m_Keys").?.* == .seq);
    const par_o = try yaml.parseValue(arena, "{m_Keys: [a, b], m_Values: [1, 2]}");
    const par_t = try yaml.parseValue(arena, "{m_Keys: [a, c], m_Values: [1, 3]}");
    const par_plan = try build(arena, .{ .nodes = .{ .base = par_b, .ours = par_o, .theirs = par_t } });
    try std.testing.expectEqual(@as(usize, 0), par_plan.conflicts.len);
    const par = (try materialize(arena, par_plan, &.{})).?;
    try std.testing.expectEqual(@as(usize, 3), par.get("m_Keys").?.seq.len);
    try std.testing.expectEqualStrings("a", par.get("m_Keys").?.seq[0].scalar);
    try std.testing.expectEqualStrings("b", par.get("m_Keys").?.seq[1].scalar);
    try std.testing.expectEqualStrings("c", par.get("m_Keys").?.seq[2].scalar);
    try std.testing.expectEqualStrings("2", par.get("m_Values").?.seq[1].scalar);
    try std.testing.expectEqualStrings("3", par.get("m_Values").?.seq[2].scalar);
}

test "value keyed pairs report delete/edit when one side removes a changed key" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const yaml = @import("merge_yaml.zig");
    const b = try yaml.parseValue(arena, "[{key: a, value: 1}]");
    const o = try yaml.parseValue(arena, "[]");
    const t = try yaml.parseValue(arena, "[{key: a, value: 2}]");
    const plan = try build(arena, .{ .nodes = .{ .base = b, .ours = o, .theirs = t } });
    // Taking Theirs would restore a key Ours deleted. The conflict has to stay
    // explicit instead of auto-keeping the edited pair.
    try std.testing.expectEqual(@as(usize, 1), plan.conflicts.len);
    try std.testing.expectEqual(Reason.delete_edit, plan.conflicts[0].reason);
    try std.testing.expectEqualStrings("[a]", plan.conflicts[0].path);
}

test "value keyed pairs keep the side that reorders shared keys" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const yaml = @import("merge_yaml.zig");
    const b = try yaml.parseValue(arena, "[{key: a, value: 1}, {key: b, value: 2}]");
    const o = try yaml.parseValue(arena, "[{key: a, value: 1}, {key: b, value: 2}]");
    const t = try yaml.parseValue(arena, "[{key: b, value: 2}, {key: a, value: 1}]");
    const plan = try build(arena, .{ .nodes = .{ .base = b, .ours = o, .theirs = t } });
    try std.testing.expectEqual(@as(usize, 0), plan.conflicts.len);
    const result = (try materialize(arena, plan, &.{})).?;
    try std.testing.expectEqualStrings("b", model.findValue(result.seq[0].map, "key").?.scalar);
    try std.testing.expectEqualStrings("a", model.findValue(result.seq[1].map, "key").?.scalar);
}

test "value keyed collections stay unresolved when YAML is malformed" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const yaml = @import("merge_yaml.zig");
    const cases = [_][3][]const u8{
        .{ "[{key: a, value: 1}]", "[{key: a, value: 1}, {key: a, value: 2}]", "[{key: a, value: 1}]" },
        .{ "{m_Keys: [a], m_Values: [1]}", "{m_Keys: [a, b], m_Values: [1]}", "{m_Keys: [a], m_Values: [1]}" },
    };
    for (cases) |sides| {
        const plan = try build(arena, .{ .nodes = .{
            .base = try yaml.parseValue(arena, sides[0]),
            .ours = try yaml.parseValue(arena, sides[1]),
            .theirs = try yaml.parseValue(arena, sides[2]),
        } });
        // Duplicate keys and m_Keys/m_Values length mismatch cannot prove identity.
        try std.testing.expectEqual(@as(usize, 1), plan.conflicts.len);
        try std.testing.expectEqual(Reason.context_required, plan.conflicts[0].reason);
        try std.testing.expectEqualStrings("", plan.conflicts[0].path);
    }
}
