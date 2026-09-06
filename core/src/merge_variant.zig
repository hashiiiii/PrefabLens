const std = @import("std");
const model = @import("model.zig");
const source = @import("source.zig");
const mm = @import("merge_model.zig");
const binding = @import("merge_binding.zig");
const value = @import("merge_value.zig");
const projection = @import("merge_variant_value.zig");
const property = @import("merge_property_path.zig");
const yaml = @import("merge_yaml.zig");
const context = @import("merge_context.zig");
const parser = @import("parser.zig");
const A = std.mem.Allocator;
const field = projection.field;
pub const Link = struct { boundary: *const Boundary, group: usize, emit: bool = true };
pub const VariantEffectKind = enum {
    inherited_to_explicit,
    inherited_size_to_explicit,
    explicit_to_inherited,
    custom_explicit,
};
pub const VariantEffect = struct {
    document: mm.DocumentId,
    target: model.Ref,
    property_path: []const u8,
    origin_side: ?mm.Side,
    origin_path: ?[]const u8,
    kind: VariantEffectKind,
    source_value: ?*const model.Node,
    result_value: ?*const model.Node,
    decision_operation: ?mm.OperationId,
};
pub const VariantProvenance = struct {
    effects: []const VariantEffect,
    pending_groups: usize,
};
const SizeChoice = struct {
    binding_id: usize,
    start: usize,
    explicit: [3]bool,
};
const RowTemplate = struct {
    key: []const u8,
    rows: [3]?*const model.Node,
    selected: ?*const model.Node = null,
    binding_id: ?usize = null,
};
const Group = struct {
    target: model.Ref,
    root: []const u8,
    collection: bool,
    raw: bool = false,
    inherit_output: bool = false,
    source_aligned: bool = false,
    size_explicit: bool = false,
    size_choice: ?SizeChoice = null,
    promotion_binding: ?usize = null,
    template: ?*const model.Node = null,
    rows: [3]*const model.Node,
    files: [3]source.ParsedFile = undefined,
    templates: []const RowTemplate = &.{},
    projections: ?[4]projection.Projection = null,
    binding_id: usize = 0,
};
pub const Boundary = struct {
    document: mm.DocumentId,
    files: [3]source.ParsedFile,
    sequences: [3]*const model.Node,
    groups: []Group,
    output: context.Snapshot,
};
pub fn hasContext(c: context.Context) bool {
    for ([_]context.Snapshot{ c.base, c.ours, c.theirs, c.output }) |snapshot| if (snapshot.revision.len > 0 or snapshot.assets.len > 0 or snapshot.scripts.len > 0) return true;
    return false;
}
pub fn handles(arena: A, nodes: value.Nodes) mm.Error!bool {
    for ([_]?*const model.Node{ nodes.base, nodes.ours, nodes.theirs }) |optional| if (optional) |n| {
        if (n.* != .seq) continue;
        for (n.seq) |row| {
            const p = field(row, "propertyPath") orelse continue;
            if (p.* != .scalar) continue;
            const root = property.collectionRoot(arena, p.scalar) catch return true;
            if (root != null) return true;
        }
    };
    return false;
}
fn findDoc(file: source.ParsedFile, id: mm.DocumentId) ?*const model.Document {
    for (file.documents) |*doc| if (doc.class_id == id.class_id and doc.file_id == id.file_id) return doc;
    return null;
}
fn rowIdentity(arena: A, row: *const model.Node) mm.Error!struct { target: model.Ref, root: []const u8, collection: bool } {
    const target = field(row, "target") orelse return error.UnsupportedStructure;
    const p = field(row, "propertyPath") orelse return error.UnsupportedStructure;
    if (target.* != .ref or p.* != .scalar) return error.UnsupportedStructure;
    const root = property.collectionRoot(arena, p.scalar) catch return .{ .target = target.ref, .root = p.scalar, .collection = true };
    return .{ .target = target.ref, .root = root orelse p.scalar, .collection = root != null };
}
fn matches(arena: A, row: *const model.Node, group: Group) mm.Error!bool {
    const id = try rowIdentity(arena, row);
    return projection.sameRef(id.target, group.target) and std.mem.eql(u8, id.root, group.root);
}
pub fn collect(arena: A, state: *binding.State, operations: *std.ArrayList(mm.Operation), atomics: *std.ArrayList(mm.AtomicOperation), document: mm.DocumentId, hierarchy: []const u8, nodes: value.Nodes, files: [3]source.ParsedFile) mm.Error!void {
    const sequences: [3]*const model.Node = .{ nodes.base orelse return error.UnsupportedStructure, nodes.ours orelse return error.UnsupportedStructure, nodes.theirs orelse return error.UnsupportedStructure };
    var groups: std.ArrayList(Group) = .empty;
    // Ours order is the stable base for unrelated authored rows.
    for ([_]usize{ 1, 2, 0 }) |side| {
        if (sequences[side].* != .seq) return error.UnsupportedStructure;
        for (sequences[side].seq, 0..) |row, row_index| {
            const id = try rowIdentity(arena, row);
            var found = false;
            for (groups.items) |g| if (projection.sameRef(id.target, g.target) and std.mem.eql(u8, id.root, g.root)) {
                found = true;
                break;
            };
            if (!found) {
                var insertion = groups.items.len;
                future: for (sequences[side].seq[row_index + 1 ..]) |next| {
                    const next_id = try rowIdentity(arena, next);
                    for (groups.items, 0..) |g, index| {
                        if (projection.sameRef(next_id.target, g.target) and std.mem.eql(u8, next_id.root, g.root)) {
                            insertion = index;
                            break :future;
                        }
                    }
                }
                try groups.insert(arena, insertion, .{ .target = id.target, .root = id.root, .collection = id.collection, .rows = undefined });
            }
        }
    }
    const inherit_unwritten = try unchangedSourceEstablished(arena, files, document, state.context.output);
    for ([_]context.Snapshot{ state.context.base, state.context.ours, state.context.theirs }, files) |snapshot, file| {
        // Unwritten groups inherit the selected source even if an earlier
        // branch removed that source or cannot prove its script declarations.
        if (inherit_unwritten) break;
        const doc = findDoc(file, document) orelse continue;
        const prefab_source = field(doc.body, "m_SourcePrefab") orelse continue;
        if (prefab_source.* != .ref or prefab_source.ref.guid == null) continue;
        var graph = @import("merge_variant_source.zig").Graph.init(arena, snapshot);
        const targets = graph.targets(prefab_source.ref.guid.?) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        for (targets) |target| {
            const resolved = graph.resolve(target) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            const script_guid = resolved.scriptGuid() orelse continue;
            for (snapshot.scripts) |script| {
                if (!std.mem.eql(u8, script.guid, script_guid)) continue;
                for (script.fields) |descriptor| {
                    const segments = property.parse(arena, descriptor.path) catch continue;
                    if (projection.at(resolved.document.body, segments) == null) continue;
                    var found = false;
                    for (groups.items) |g| if (projection.sameRef(target, g.target) and std.mem.eql(u8, descriptor.path, g.root)) {
                        found = true;
                        break;
                    };
                    if (!found) try groups.append(arena, .{ .target = target, .root = descriptor.path, .collection = true, .rows = undefined });
                }
            }
        }
    }
    var has_collection = false;
    for (groups.items) |group| if (group.collection) {
        has_collection = true;
        break;
    };
    if (!has_collection) {
        const ours_doc = findDoc(files[1], document) orelse return error.UnsupportedStructure;
        const source_ref = field(ours_doc.body, "m_SourcePrefab") orelse return error.UnsupportedStructure;
        if (source_ref.* != .ref) return error.UnsupportedStructure;
        if (!try selectedSourceEstablished(arena, state.context.output, source_ref.ref)) {
            try groups.append(arena, .{ .target = source_ref.ref, .root = "m_SourcePrefab", .collection = true, .rows = undefined });
        }
    }
    const boundary = try arena.create(Boundary);
    boundary.* = .{ .document = document, .files = files, .sequences = sequences, .groups = try groups.toOwnedSlice(arena), .output = state.context.output };
    for (boundary.groups, 0..) |*group, group_index| {
        group.files = files;
        for (sequences, 0..) |sequence, side| {
            var selected: std.ArrayList(*model.Node) = .empty;
            for (sequence.seq) |row| if (try matches(arena, row, group.*)) try selected.append(arena, row);
            group.rows[side] = try value.node(arena, .{ .seq = try selected.toOwnedSlice(arena) });
        }
        const bm = try sizeExplicit(arena, group.rows[0]);
        const om = try sizeExplicit(arena, group.rows[1]);
        const tm = try sizeExplicit(arena, group.rows[2]);
        const size_masks: [3]bool = .{ bm, om, tm };
        group.size_explicit = if (om == tm or bm == tm) om else tm;
        var input: value.Input = .{ .nodes = .{ .base = group.rows[0], .ours = group.rows[1], .theirs = group.rows[2] } };
        var bytes_conflict = false;
        if (group.collection) {
            const snapshots: [4]context.Snapshot = .{ state.context.base, state.context.ours, state.context.theirs, state.context.output };
            var projections: [4]projection.Projection = undefined;
            var valid = true;
            for (snapshots, 0..) |snapshot, side| {
                const outer: ?projection.Document = if (side < 3)
                    if (findDoc(files[side], document)) |doc| .{ .file = files[side], .document = doc } else null
                else
                    null;
                projections[side] = projection.project(arena, snapshot, outer, group.target, group.root) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        valid = false;
                        break;
                    },
                };
            }
            if (valid and projection.compatible(&projections)) {
                group.projections = projections;
                group.inherit_output = group.rows[0].seq.len == 0 and group.rows[1].seq.len == 0 and group.rows[2].seq.len == 0;
                input.nodes = if (group.inherit_output)
                    .{ .base = projections[3].node, .ours = projections[3].node, .theirs = projections[3].node }
                else
                    .{ .base = projections[0].node, .ours = projections[1].node, .theirs = projections[2].node };
                if (!group.inherit_output) if (try authoredInputs(arena, group.*, size_masks)) |aligned| {
                    input.nodes = aligned;
                    group.source_aligned = true;
                };
                input.schema = projections[0].descriptor;
                if (input.schema.?.kind == .int32_array) input.schema.?.kind = .ordered;
                input.aligned_items = group.source_aligned and input.schema.?.kind == .ordered;
            } else {
                group.raw = true;
                input.context_conflict = true;
            }
        } else if (group.rows[0].seq.len > 1 or group.rows[1].seq.len > 1 or group.rows[2].seq.len > 1) {
            group.raw = true;
            input.context_conflict = true;
        } else {
            // Scalar overrides keep their established target/path identity.
            input.nodes = .{ .base = single(group.rows[0]), .ours = single(group.rows[1]), .theirs = single(group.rows[2]) };
            const skeletons: [3]?[]const u8 = .{ try skeleton(arena, files[0], input.nodes.base), try skeleton(arena, files[1], input.nodes.ours), try skeleton(arena, files[2], input.nodes.theirs) };
            if (sameBytes(skeletons[1], skeletons[2]) or sameBytes(skeletons[0], skeletons[2])) group.template = input.nodes.ours else if (sameBytes(skeletons[0], skeletons[1])) group.template = input.nodes.theirs else bytes_conflict = true;
        }
        if (group.projections) |ps| {
            if (!group.inherit_output) input.comparisons = try projection.comparisons(arena, ps, input.nodes);
        }
        const planned = if (bytes_conflict) value.conflicted(arena, input, .source_bytes) else value.build(arena, input);
        const plan = planned catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidResolution,
        };
        const binding_id = state.bindings.items.len;
        group.binding_id = binding_id;
        var ids: std.ArrayList(mm.OperationId) = .empty;
        for (plan.conflicts, 0..) |conflict, i| {
            const id: mm.OperationId = @intCast(operations.items.len);
            const atomic: mm.AtomicId = @intCast(atomics.items.len);
            try operations.append(arena, .{ .id = id, .atomic_id = atomic, .kind = .field, .identity = .{ .document = document, .property_path = group.root }, .hierarchy_path = hierarchy, .property_path = group.root, .item_path = if (conflict.path.len > 0) conflict.path else null, .values = .{ .base = try sideValue(arena, conflict.nodes.base), .ours = try sideValue(arena, conflict.nodes.ours), .theirs = try sideValue(arena, conflict.nodes.theirs) }, .resolution = .unresolved, .collection = .{ .binding = binding_id, .conflict = i } });
            try ids.append(arena, id);
            try atomics.append(arena, .{ .id = atomic, .kind = .field, .operation_ids = try arena.dupe(mm.OperationId, &.{id}) });
        }
        try state.bindings.append(arena, .{ .plan = plan, .source_nodes = input.nodes, .original = sequences[1], .identity = .{ .document = document, .property_path = "m_Modification.m_Modifications" }, .operation_ids = try ids.toOwnedSlice(arena), .variant = .{ .boundary = boundary, .group = group_index } });
        if (group.collection and !group.raw and !group.inherit_output) {
            group.templates = try buildRowTemplates(arena, state, operations, atomics, boundary, group_index, document, hierarchy, group.*);
        }
        if (group.projections) |ps| {
            if (!group.inherit_output and sizeIntentConflict(ps, size_masks)) {
                var start = ps[0].node.seq.len;
                for (ps[1..3]) |p| start = @min(start, p.node.seq.len);
                const suffixes: value.Nodes = .{
                    .base = try value.node(arena, .{ .seq = ps[0].node.seq[start..] }),
                    .ours = try value.node(arena, .{ .seq = ps[1].node.seq[start..] }),
                    .theirs = try value.node(arena, .{ .seq = ps[2].node.seq[start..] }),
                };
                group.size_choice = .{
                    .binding_id = try appendAuxiliaryConflict(arena, state, operations, atomics, boundary, group_index, document, hierarchy, group.root, try std.fmt.allocPrint(arena, "[{d}..]", .{start}), suffixes, .delete_edit),
                    .start = start,
                    .explicit = size_masks,
                };
            }
        }
        if (try needsPromotionChoice(arena, group.*, plan, size_masks)) {
            var dependencies: std.ArrayList(mm.AtomicId) = .empty;
            for (state.bindings.items[group.binding_id].operation_ids) |id| try dependencies.append(arena, operations.items[id].atomic_id);
            if (group.size_choice) |choice| {
                for (state.bindings.items[choice.binding_id].operation_ids) |id| try dependencies.append(arena, operations.items[id].atomic_id);
            }
            const ps = group.projections.?;
            group.promotion_binding = try appendAuxiliaryConflictWithDependencies(
                arena,
                state,
                operations,
                atomics,
                boundary,
                group_index,
                document,
                hierarchy,
                group.root,
                "promotion",
                .{ .base = ps[3].node, .ours = ps[1].node, .theirs = ps[3].node },
                .context_required,
                try dependencies.toOwnedSlice(arena),
            );
        }
    }
}
fn unchangedSourceEstablished(arena: A, files: [3]source.ParsedFile, document: mm.DocumentId, output: context.Snapshot) A.Error!bool {
    var first: ?*const model.Node = null;
    for (files) |file| {
        const doc = findDoc(file, document) orelse return false;
        const ref = field(doc.body, "m_SourcePrefab") orelse return false;
        if (ref.* != .ref) return false;
        if (first) |base| {
            if (!model.Node.eql(base, ref)) return false;
        } else first = ref;
    }
    return selectedSourceEstablished(arena, output, first.?.ref);
}

// With no authored size, each side contributes leaf overrides and resets.
// Rebase those contributions before merging so inherited Source conflicts do
// not become a second Variant decision. Historical projections stay intact.
fn authoredInputs(arena: A, group: Group, size_masks: [3]bool) mm.Error!?value.Nodes {
    for (size_masks) |explicit| if (explicit) return null;
    const ps = group.projections.?;
    for (ps) |p| if (p.sparse) return null;
    const output = ps[3].node;
    var nodes: [3]*const model.Node = undefined;
    for (ps[0..3], group.rows, &nodes) |p, rows, *node| {
        if (p.node.seq.len != p.inherited.seq.len) return null;
        for (rows.seq) |row| {
            const active = for (p.leaves) |leaf| {
                if (leaf.explicit and leaf.row == row) break true;
            } else false;
            if (!active) return null;
        }
        const items = try arena.dupe(*model.Node, output.seq);
        const claimed = try arena.alloc(bool, items.len);
        @memset(claimed, false);
        const mapping = try @import("merge_collection.zig").correspondence(arena, p.inherited.seq, output.seq);
        for (p.node.seq, 0..) |item, index| {
            if (!hasAuthoredLeaf(group, item)) continue;
            const destination = authoredDestination(p.inherited.seq, output.seq, mapping, index) orelse return null;
            if (claimed[destination] or !projection.coverageEqual(item, output.seq[destination])) return null;
            claimed[destination] = true;
            items[destination] = @constCast(try overlayExplicit(arena, group, item, output.seq[destination]));
        }
        node.* = try value.node(arena, .{ .seq = items });
    }
    return .{ .base = nodes[0], .ours = nodes[1], .theirs = nodes[2] };
}
fn authoredDestination(inherited: []const *model.Node, output: []const *model.Node, mapping: []const ?usize, index: usize) ?usize {
    if (mapping[index]) |destination| return destination;
    // A moved exact value is usable only when both source snapshots contain
    // one occurrence. Output uniqueness alone cannot identify a removed twin.
    var inherited_count: usize = 0;
    for (inherited) |candidate| if (model.Node.eql(candidate, inherited[index])) {
        inherited_count += 1;
    };
    if (inherited_count != 1) return null;
    var destination: ?usize = null;
    for (output, 0..) |candidate, i| if (model.Node.eql(candidate, inherited[index])) {
        if (destination != null) return null;
        destination = i;
    };
    return destination;
}
fn selectedSourceEstablished(arena: A, snapshot: context.Snapshot, ref: model.Ref) A.Error!bool {
    const guid = ref.guid orelse return false;
    var sources = @import("merge_variant_source.zig").Graph.init(arena, snapshot);
    _ = sources.targets(guid) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    return true;
}
fn buildRowTemplates(arena: A, state: *binding.State, operations: *std.ArrayList(mm.Operation), atomics: *std.ArrayList(mm.AtomicOperation), boundary: *const Boundary, group_index: usize, document: mm.DocumentId, hierarchy: []const u8, group: Group) mm.Error![]const RowTemplate {
    var templates: std.ArrayList(RowTemplate) = .empty;
    const ps = group.projections.?;
    const ours_map = try @import("merge_collection.zig").correspondence(arena, ps[0].node.seq, ps[1].node.seq);
    const theirs_map = try @import("merge_collection.zig").correspondence(arena, ps[0].node.seq, ps[2].node.seq);
    const size_path = try std.fmt.allocPrint(arena, "{s}.Array.size", .{group.root});
    const size_rows: [3]?*const model.Node = .{ rowForPath(group.rows[0], size_path), rowForPath(group.rows[1], size_path), rowForPath(group.rows[2], size_path) };
    if (size_rows[0] != null or size_rows[1] != null or size_rows[2] != null) try templates.append(arena, .{ .key = "size", .rows = size_rows });
    const root_path = property.parse(arena, group.root) catch return error.InvalidResolution;
    for (group.rows, 0..) |sequence, side| for (sequence.seq) |row| {
        if (!activeTemplateRow(ps[side], row)) continue;
        const path_node = field(row, "propertyPath") orelse return error.InvalidResolution;
        if (path_node.* != .scalar) return error.InvalidResolution;
        const parsed = property.parse(arena, path_node.scalar) catch return error.InvalidResolution;
        if (parsed.len <= root_path.len or parsed[root_path.len] != .index) return error.InvalidResolution;
        const index = parsed[root_path.len].index;
        const base_index = correspondingBaseIndex(side, index, ours_map, theirs_map);
        const suffix = property.format(arena, parsed[root_path.len + 1 ..]) catch return error.InvalidResolution;
        const key = if (base_index) |base| try std.fmt.allocPrint(arena, "base[{d}].{s}", .{ base, suffix }) else try std.fmt.allocPrint(arena, "side[{d}][{d}].{s}", .{ side, index, suffix });
        var found: ?*RowTemplate = null;
        for (templates.items) |*template| if (std.mem.eql(u8, template.key, key)) {
            found = template;
            break;
        };
        if (found == null) {
            try templates.append(arena, .{ .key = key, .rows = .{ null, null, null } });
            found = &templates.items[templates.items.len - 1];
        }
        found.?.rows[side] = row;
    };
    for (templates.items) |*template| {
        const rows = template.rows;
        const shapes: [3]?[]const u8 = .{ try skeleton(arena, group.files[0], rows[0]), try skeleton(arena, group.files[1], rows[1]), try skeleton(arena, group.files[2], rows[2]) };
        if (sameBytes(shapes[1], shapes[2]) or sameBytes(shapes[0], shapes[2])) {
            template.selected = rows[1];
        } else if (sameBytes(shapes[0], shapes[1])) {
            template.selected = rows[2];
        } else {
            const item_path = for (rows) |candidate| {
                const row = candidate orelse continue;
                break field(row, "propertyPath").?.scalar;
            } else group.root;
            template.binding_id = try appendAuxiliaryConflict(arena, state, operations, atomics, boundary, group_index, document, hierarchy, group.root, item_path, .{ .base = rows[0], .ours = rows[1], .theirs = rows[2] }, .source_bytes);
        }
    }
    return templates.toOwnedSlice(arena);
}
fn activeTemplateRow(p: projection.Projection, row: *const model.Node) bool {
    for (p.leaves) |leaf| if (leaf.row == row) return true;
    return false;
}
fn correspondingBaseIndex(side: usize, index: usize, ours: []?usize, theirs: []?usize) ?usize {
    if (side == 0) return index;
    const mapping = if (side == 1) ours else theirs;
    for (mapping, 0..) |candidate, base| if (candidate == index) return base;
    return null;
}
fn sizeIntentConflict(ps: [4]projection.Projection, masks: [3]bool) bool {
    const sizes: [3]usize = .{ ps[0].node.seq.len, ps[1].node.seq.len, ps[2].node.seq.len };
    const ours_intent = sizes[1] == sizes[0] and masks[1] != masks[0] and sizes[2] != sizes[0];
    const theirs_intent = sizes[2] == sizes[0] and masks[2] != masks[0] and sizes[1] != sizes[0];
    return ours_intent or theirs_intent;
}
fn appendAuxiliaryConflict(arena: A, state: *binding.State, operations: *std.ArrayList(mm.Operation), atomics: *std.ArrayList(mm.AtomicOperation), boundary: *const Boundary, group_index: usize, document: mm.DocumentId, hierarchy: []const u8, root: []const u8, item_path: []const u8, nodes: value.Nodes, reason: value.Reason) mm.Error!usize {
    return appendAuxiliaryConflictWithDependencies(arena, state, operations, atomics, boundary, group_index, document, hierarchy, root, item_path, nodes, reason, &.{});
}
fn appendAuxiliaryConflictWithDependencies(arena: A, state: *binding.State, operations: *std.ArrayList(mm.Operation), atomics: *std.ArrayList(mm.AtomicOperation), boundary: *const Boundary, group_index: usize, document: mm.DocumentId, hierarchy: []const u8, root: []const u8, item_path: []const u8, nodes: value.Nodes, reason: value.Reason, dependencies: []const mm.AtomicId) mm.Error!usize {
    const aux_plan = value.conflicted(arena, .{ .nodes = nodes }, reason) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResolution,
    };
    const binding_id = state.bindings.items.len;
    const id: mm.OperationId = @intCast(operations.items.len);
    const atomic: mm.AtomicId = @intCast(atomics.items.len);
    try operations.append(arena, .{ .id = id, .atomic_id = atomic, .kind = .field, .identity = .{ .document = document, .property_path = root }, .hierarchy_path = hierarchy, .property_path = root, .item_path = item_path, .values = .{ .base = try sideValue(arena, nodes.base), .ours = try sideValue(arena, nodes.ours), .theirs = try sideValue(arena, nodes.theirs) }, .resolution = .unresolved, .collection = .{ .binding = binding_id, .conflict = 0 }, .dependencies = dependencies });
    try atomics.append(arena, .{ .id = atomic, .kind = .field, .operation_ids = try arena.dupe(mm.OperationId, &.{id}), .dependencies = dependencies });
    try state.bindings.append(arena, .{ .plan = aux_plan, .source_nodes = nodes, .original = boundary.sequences[1], .identity = .{ .document = document, .property_path = "m_Modification.m_Modifications" }, .operation_ids = try arena.dupe(mm.OperationId, &.{id}), .variant = .{ .boundary = boundary, .group = group_index, .emit = false } });
    return binding_id;
}
fn single(n: *const model.Node) ?*const model.Node {
    return if (n.seq.len == 1) n.seq[0] else null;
}
fn sideValue(arena: A, n: ?*const model.Node) mm.Error!?mm.SideValue {
    const p = n orelse return null;
    return .{ .node = p, .span = null, .bytes = yaml.flow(arena, p) catch return error.InvalidResolution };
}
const Emission = struct { row: *const model.Node, template: ?*const model.Node = null, force_path: bool = false };
fn makeRow(arena: A, target: model.Ref, path: []const u8, leaf: *const model.Node) mm.Error!*const model.Node {
    const entries = try arena.alloc(model.Entry, 4);
    entries[0] = .{ .key = "target", .value = @constCast(try value.node(arena, .{ .ref = target })) };
    entries[1] = .{ .key = "propertyPath", .value = @constCast(try value.node(arena, .{ .scalar = path })) };
    entries[2] = .{ .key = "value", .value = @constCast(if (leaf.* == .ref) try value.node(arena, .{ .scalar = "" }) else leaf) };
    entries[3] = .{ .key = "objectReference", .value = @constCast(if (leaf.* == .ref) leaf else try value.node(arena, .{ .ref = .{ .file_id = 0 } })) };
    return value.node(arena, .{ .map = entries });
}
fn origin(group: Group, node: *const model.Node) ?projection.Leaf {
    if (group.projections) |ps| for (ps[0..]) |p| for (p.leaves) |leaf| if (leaf.node == node) return leaf;
    for (group.rows) |rows| for (rows.seq) |row| {
        const raw = field(row, "value") orelse continue;
        const reference = field(row, "objectReference") orelse continue;
        if (raw == node or reference == node) return .{ .node = node, .explicit = true, .row = row };
    };
    return null;
}
fn needsPromotionChoice(arena: A, group: Group, plan: value.Plan, size_masks: [3]bool) mm.Error!bool {
    if (group.inherit_output or group.raw or group.projections == null) return false;
    if (group.size_choice == null and plan.conflicts.len == 0) {
        const result = value.materialize(arena, plan, &.{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidResolution,
        };
        const selected = try followInherited(arena, group, result);
        if (hasPromotion(group, selected, group.size_explicit)) return true;
    } else if (group.size_choice == null) {
        const choices = try arena.alloc(value.Choice, plan.conflicts.len);
        for ([_]value.Side{ .ours, .theirs }) |side| {
            @memset(choices, .{ .take = side });
            const result = value.materialize(arena, plan, choices) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            const selected = try followInherited(arena, group, result);
            if (hasPromotion(group, selected, group.size_explicit)) return true;
            for (choices) |*choice| {
                choice.* = .{ .take = if (side == .ours) .theirs else .ours };
                const mixed = value.materialize(arena, plan, choices) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        choice.* = .{ .take = side };
                        continue;
                    },
                };
                choice.* = .{ .take = side };
                const candidate = try followInherited(arena, group, mixed);
                if (hasPromotion(group, candidate, group.size_explicit)) return true;
            }
        }
    }
    if (group.size_choice != null) {
        const ps = group.projections.?;
        for (ps[0..3], size_masks) |candidate, explicit| {
            const selected = try followInherited(arena, group, candidate.node);
            if (hasPromotion(group, selected, explicit)) return true;
        }
    }
    return false;
}
fn hasPromotion(group: Group, selected: ?*const model.Node, size_explicit: bool) bool {
    if (group.inherit_output or group.raw or group.projections == null) return false;
    const result = selected orelse return false;
    const output = group.projections.?[3].node;
    if (result.* != .seq or output.* != .seq) return false;
    if (!size_explicit and result.seq.len != output.seq.len) return true;
    return hasPromotedLeaf(group, result, output);
}
fn hasPromotedLeaf(group: Group, result: *const model.Node, output: ?*const model.Node) bool {
    if (result.* == .map) {
        for (result.map) |entry| {
            const inherited = if (output) |candidate| field(candidate, entry.key) else null;
            if (hasPromotedLeaf(group, entry.value, inherited)) return true;
        }
        return false;
    }
    if (result.* == .seq) {
        for (result.seq, 0..) |item, index| {
            const inherited = if (output) |candidate| if (candidate.* == .seq and index < candidate.seq.len) candidate.seq[index] else null else null;
            if (hasPromotedLeaf(group, item, inherited)) return true;
        }
        return false;
    }
    const leaf = origin(group, result) orelse return false;
    return !leaf.explicit and (output == null or !model.Node.eql(result, output.?));
}
fn followInherited(arena: A, group: Group, selected: ?*const model.Node) mm.Error!?*const model.Node {
    const current = selected orelse return null;
    if (group.source_aligned) return current;
    const ps = group.projections orelse return current;
    if (current.* != .seq or ps[3].node.* != .seq) return current;
    const mapping = try @import("merge_collection.zig").correspondence(arena, ps[3].node.seq, current.seq);
    const items = try arena.dupe(*model.Node, current.seq);
    var changed = false;
    for (mapping, 0..) |selected_index, output_index| {
        const index = selected_index orelse continue;
        const followed = try followInheritedNode(arena, group, items[index], ps[3].node.seq[output_index]);
        if (followed != items[index]) {
            items[index] = @constCast(followed);
            changed = true;
        }
    }
    return if (changed) try value.node(arena, .{ .seq = items }) else current;
}
fn followOutputStructure(arena: A, group: Group, selected: ?*const model.Node, preserve_membership: bool) mm.Error!?*const model.Node {
    const current = selected orelse return null;
    const output = group.projections.?[3].node;
    if (current.* != .seq or output.* != .seq) return current;
    const destinations = try arena.alloc(?usize, current.seq.len);
    const origins = try arena.alloc(bool, current.seq.len);
    const destination_counts = try arena.alloc(usize, output.seq.len);
    const origin_counts = try arena.alloc(usize, output.seq.len);
    @memset(destination_counts, 0);
    @memset(origin_counts, 0);
    for (current.seq, destinations, origins) |item, *destination, *has_origin| {
        const correspondence = try outputIndexForItem(arena, group, item);
        destination.* = correspondence.index;
        has_origin.* = correspondence.has_origin;
        if (destination.*) |index| {
            destination_counts[index] += 1;
            if (has_origin.*) origin_counts[index] += 1;
        }
    }
    // Value-only matches cannot displace a proven origin. Conflicting origins
    // remain unmapped, preserving their accepted occurrences below.
    for (destinations, origins) |*destination, has_origin| if (destination.*) |index| {
        if (if (has_origin) origin_counts[index] != 1 else origin_counts[index] != 0 or destination_counts[index] != 1) destination.* = null;
    };

    var items: std.ArrayList(*model.Node) = .empty;
    for (output.seq, 0..) |output_item, output_index| {
        for (current.seq, destinations, 0..) |item, destination, current_index| {
            if (destination != null or (!preserve_membership and !hasAuthoredLeaf(group, item))) continue;
            const next = nextDestination(destinations, current_index + 1);
            if (next != null and next.? == output_index) try items.append(arena, @constCast(item));
        }
        const selected_item = for (current.seq, destinations) |item, destination| {
            if (destination != null and destination.? == output_index) break item;
        } else null;
        if (selected_item) |item| {
            try items.append(arena, @constCast(try overlayExplicit(arena, group, item, output_item)));
        } else if (!preserve_membership) try items.append(arena, @constCast(output_item));
    }
    for (current.seq, destinations, 0..) |item, destination, current_index| {
        if (destination == null and (preserve_membership or hasAuthoredLeaf(group, item)) and nextDestination(destinations, current_index + 1) == null) try items.append(arena, @constCast(item));
    }
    return value.node(arena, .{ .seq = try items.toOwnedSlice(arena) });
}
fn nextDestination(destinations: []const ?usize, start: usize) ?usize {
    for (destinations[start..]) |destination| if (destination != null) return destination;
    return null;
}
fn hasAuthoredLeaf(group: Group, node: *const model.Node) bool {
    if (node.* == .map) {
        for (node.map) |entry| if (hasAuthoredLeaf(group, entry.value)) return true;
        return false;
    }
    if (node.* == .seq) {
        for (node.seq) |item| if (hasAuthoredLeaf(group, item)) return true;
        return false;
    }
    const leaf = origin(group, node);
    return leaf == null or leaf.?.explicit;
}
const ItemCorrespondence = struct { index: ?usize, has_origin: bool };
fn outputIndexForItem(arena: A, group: Group, item: *const model.Node) mm.Error!ItemCorrespondence {
    const ps = group.projections.?;
    var destination: ?usize = null;
    var has_origin = false;
    for (ps[0..]) |p| {
        if (p.node.* != .seq or p.inherited.* != .seq) continue;
        for (p.node.seq, 0..) |candidate, index| {
            if (!sharesLeafPointer(candidate, item)) continue;
            has_origin = true;
            const mapped = try outputIndexForProjectionItem(arena, ps[3].node.seq, p.inherited.seq, index);
            if (mapped) |output_index| {
                if (destination != null and destination.? != output_index) return .{ .index = null, .has_origin = true };
                destination = output_index;
            }
        }
    }
    if (has_origin) return .{ .index = destination, .has_origin = true };

    // Custom items have no retained input origin. Reuse a unique whole-value
    // match only as a fallback; equality never overrides authored provenance.
    var exact: ?usize = null;
    var exact_count: usize = 0;
    for (ps[3].node.seq, 0..) |candidate, output_index| if (model.Node.eql(candidate, item)) {
        exact = output_index;
        exact_count += 1;
    };
    return .{ .index = if (exact_count == 1) exact else null, .has_origin = false };
}
fn outputIndexForProjectionItem(arena: A, output: []const *model.Node, inherited: []const *model.Node, index: usize) A.Error!?usize {
    if (index >= inherited.len) return null;
    var exact: ?usize = null;
    var exact_count: usize = 0;
    for (output, 0..) |candidate, output_index| if (model.Node.eql(candidate, inherited[index])) {
        exact = output_index;
        exact_count += 1;
    };
    if (exact_count == 1) return exact;
    const mapping = try @import("merge_collection.zig").correspondence(arena, output, inherited);
    for (mapping, 0..) |candidate, output_index| if (candidate != null and candidate.? == index) return output_index;
    return null;
}
fn sharesLeafPointer(a: *const model.Node, b: *const model.Node) bool {
    if (a.* == .map) {
        for (a.map) |entry| if (containsLeafPointer(b, entry.value)) return true;
        return false;
    }
    if (a.* == .seq) {
        for (a.seq) |item| if (sharesLeafPointer(item, b)) return true;
        return false;
    }
    return containsLeafPointer(b, a);
}
fn containsLeafPointer(node: *const model.Node, needle: *const model.Node) bool {
    if (node.* == .map) {
        for (node.map) |entry| if (containsLeafPointer(entry.value, needle)) return true;
        return false;
    }
    if (node.* == .seq) {
        for (node.seq) |item| if (containsLeafPointer(item, needle)) return true;
        return false;
    }
    return node == needle;
}
fn overlayExplicit(arena: A, group: Group, selected: *const model.Node, output: *const model.Node) mm.Error!*const model.Node {
    if (selected.* == .map and output.* == .map) {
        const entries = try arena.dupe(model.Entry, output.map);
        for (entries) |*entry| {
            const selected_value = field(selected, entry.key) orelse continue;
            entry.value = @constCast(try overlayExplicit(arena, group, selected_value, entry.value));
        }
        return value.node(arena, .{ .map = entries });
    }
    if (selected.* == .seq or output.* == .seq) return output;
    const leaf = origin(group, selected) orelse return selected;
    return if (leaf.explicit) selected else output;
}
fn followInheritedNode(arena: A, group: Group, selected: *const model.Node, output: *const model.Node) mm.Error!*const model.Node {
    if (selected.* == .map and output.* == .map) {
        const entries = try arena.dupe(model.Entry, selected.map);
        var changed = false;
        for (entries) |*entry| {
            const output_value = field(output, entry.key) orelse continue;
            const followed = try followInheritedNode(arena, group, entry.value, output_value);
            if (followed != entry.value) {
                entry.value = @constCast(followed);
                changed = true;
            }
        }
        return if (changed) try value.node(arena, .{ .map = entries }) else selected;
    }
    if (selected.* == .seq or output.* == .seq) return selected;
    const leaf = origin(group, selected) orelse return selected;
    return if (leaf.explicit or model.Node.eql(selected, output)) selected else output;
}
fn rowForPath(sequence: *const model.Node, path: []const u8) ?*const model.Node {
    for (sequence.seq) |row| {
        const candidate = field(row, "propertyPath") orelse continue;
        if (candidate.* == .scalar and std.mem.eql(u8, candidate.scalar, path)) return row;
    }
    return null;
}
const TemplateSelection = struct { node: ?*const model.Node, force_path: bool = false };
fn mergedTemplate(arena: A, plan: *const mm.MergePlan, group: Group, path: []const u8, fallback: ?*const model.Node) mm.Error!TemplateSelection {
    for (group.templates) |template| {
        var relevant = false;
        for (template.rows) |candidate| if (candidate == fallback) {
            relevant = true;
            break;
        };
        if (!relevant and fallback == null and std.mem.eql(u8, template.key, "size") and std.mem.endsWith(u8, path, ".Array.size")) relevant = true;
        if (!relevant) continue;
        if (template.binding_id) |binding_id| {
            const b = plan.collections[binding_id];
            const choices = try binding.choices(arena, plan, b);
            const selected = value.materialize(arena, b.plan, choices) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidResolution,
            };
            if (selected) |row| {
                var known = false;
                for (template.rows) |candidate| if (candidate == row) {
                    known = true;
                    break;
                };
                if (!known and !try matches(arena, row, group)) return error.InvalidResolution;
                return .{ .node = row, .force_path = rowPathDiffers(row, path) };
            }
            return .{ .node = fallback, .force_path = rowPathDiffers(fallback, path) };
        }
        const selected = template.selected orelse fallback;
        return .{ .node = selected, .force_path = rowPathDiffers(selected, path) };
    }
    return .{ .node = fallback };
}
fn rowPathDiffers(row: ?*const model.Node, path: []const u8) bool {
    const selected = row orelse return false;
    const property_path = field(selected, "propertyPath") orelse return false;
    return property_path.* == .scalar and !std.mem.eql(u8, property_path.scalar, path);
}
fn emitLeaves(arena: A, plan: *const mm.MergePlan, list: *std.ArrayList(Emission), group: Group, n: *const model.Node, inherited: ?*const model.Node, prefix: []const u8, force_item_path: bool) mm.Error!void {
    if (n.* == .map) {
        for (n.map) |entry| try emitLeaves(arena, plan, list, group, entry.value, if (inherited) |base| field(base, entry.key) else null, try std.fmt.allocPrint(arena, "{s}.{s}", .{ prefix, entry.key }), force_item_path);
        return;
    }
    if (n.* == .seq) {
        if (inherited != null and model.Node.eql(n, inherited.?)) return;
        return error.InvalidResolution;
    }
    const leaf = origin(group, n);
    const explicit = if (leaf) |l| l.explicit else true;
    if (!explicit and inherited != null and model.Node.eql(n, inherited.?)) return;
    const fallback = if (leaf) |l| l.row else null;
    const selected_template = try mergedTemplate(arena, plan, group, prefix, fallback);
    try list.append(arena, .{ .row = try makeRow(arena, group.target, prefix, n), .template = selected_template.node, .force_path = force_item_path or selected_template.force_path });
}
fn itemTemplateNeedsRebase(arena: A, group: Group, node: *const model.Node, prefix: []const u8) mm.Error!bool {
    if (node.* == .map) {
        for (node.map) |entry| {
            if (try itemTemplateNeedsRebase(arena, group, entry.value, try std.fmt.allocPrint(arena, "{s}.{s}", .{ prefix, entry.key }))) return true;
        }
        return false;
    }
    if (node.* == .seq) return false;
    const leaf = origin(group, node) orelse return false;
    return rowPathDiffers(leaf.row, prefix);
}
fn groupRows(arena: A, plan: *const mm.MergePlan, group: Group, result: ?*const model.Node, size_explicit: bool) mm.Error![]const Emission {
    var emitted: std.ArrayList(Emission) = .empty;
    const selected = result orelse return &.{};
    if (group.inherit_output) return &.{};
    if (group.raw) {
        if (selected.* != .seq) return error.InvalidResolution;
        for (selected.seq) |r| {
            if (!try matches(arena, r, group)) return error.InvalidResolution;
            try emitted.append(arena, .{ .row = r });
        }
    } else if (!group.collection) {
        try emitted.append(arena, .{ .row = selected, .template = group.template orelse selected });
    } else {
        if (selected.* != .seq) return error.InvalidResolution;
        const ps = group.projections.?;
        try validateSparseSelection(group, selected);
        const inherited = group.projections.?[3].node;
        const size_path = try std.fmt.allocPrint(arena, "{s}.Array.size", .{group.root});
        const size_fallback = rowForPath(group.rows[1], size_path) orelse rowForPath(group.rows[2], size_path) orelse rowForPath(group.rows[0], size_path);
        if (size_explicit or inherited.seq.len != selected.seq.len) {
            const selected_template = try mergedTemplate(arena, plan, group, size_path, size_fallback);
            try emitted.append(arena, .{ .row = try makeRow(arena, group.target, size_path, try value.node(arena, .{ .scalar = try std.fmt.allocPrint(arena, "{d}", .{selected.seq.len}) })), .template = selected_template.node, .force_path = selected_template.force_path });
        }
        for (selected.seq, 0..) |item, index| {
            const base = if (index < inherited.seq.len) inherited.seq[index] else null;
            const prefix = try std.fmt.allocPrint(arena, "{s}.Array.data[{d}]", .{ group.root, index });
            const custom_insert = index >= ps[0].node.seq.len and groupUsesCustom(plan, group);
            try emitLeaves(arena, plan, &emitted, group, item, base, prefix, custom_insert or try itemTemplateNeedsRebase(arena, group, item, prefix));
        }
    }
    return emitted.toOwnedSlice(arena);
}
fn renderRow(arena: A, emitted: Emission, files: [3]source.ParsedFile, indent: usize, ending: []const u8) mm.Error![]const u8 {
    const template = emitted.template orelse emitted.row;
    for (files) |file| {
        const span = file.sequence_item_spans.get(template) orelse continue;
        if (model.Node.eql(template, emitted.row) and !emitted.force_path) return span.bytes(file.bytes);
        if (template.* != .map or emitted.row.* != .map) break;
        var patches: std.ArrayList(@import("merge_apply.zig").Patch) = .empty;
        for (emitted.row.map) |entry| {
            const previous = field(template, entry.key) orelse break;
            if (model.Node.eql(previous, entry.value) and !(emitted.force_path and std.mem.eql(u8, entry.key, "propertyPath"))) continue;
            const location = file.entry_spans.get(previous) orelse break;
            const bytes = if (std.mem.eql(u8, entry.key, "value") and entry.value.* == .scalar and entry.value.scalar.len == 0) "" else yaml.flow(arena, entry.value) catch return error.InvalidResolution;
            try patches.append(arena, .{ .span = .{ .start = location.value.start - span.start, .end = location.value.end - span.start }, .replacement = bytes, .atomic_id = 0 });
        }
        return @import("merge_apply.zig").applyPatches(arena, span.bytes(file.bytes), patches.items);
    }
    var bytes: std.ArrayList(u8) = .empty;
    if (emitted.row.* != .map) return error.InvalidResolution;
    for (emitted.row.map, 0..) |entry, i| {
        try bytes.appendNTimes(arena, ' ', indent + if (i == 0) @as(usize, 0) else 2);
        if (i == 0) try bytes.appendSlice(arena, "- ");
        try bytes.appendSlice(arena, entry.key);
        try bytes.appendSlice(arena, ": ");
        if (!(std.mem.eql(u8, entry.key, "value") and entry.value.* == .scalar and entry.value.scalar.len == 0)) try bytes.appendSlice(arena, yaml.flow(arena, entry.value) catch return error.InvalidResolution);
        try bytes.appendSlice(arena, ending);
    }
    return bytes.toOwnedSlice(arena);
}
pub fn replacement(arena: A, plan: *const mm.MergePlan, link: Link, require_all: bool) mm.Error!?yaml.Replacement {
    if (!link.emit) return null;
    if (link.group != 0) return null;
    const boundary = link.boundary;
    var emissions: std.ArrayList(Emission) = .empty;
    const expected = try arena.alloc(?*const model.Node, boundary.groups.len);
    const expected_sizes = try arena.alloc(bool, boundary.groups.len);
    for (boundary.groups, expected, expected_sizes) |group, *logical, *size_explicit| {
        if (auxiliaryPending(plan, group)) {
            if (require_all) return error.InvalidResolution;
            logical.* = null;
            size_explicit.* = group.size_explicit;
            for (group.rows[1].seq) |r| try emissions.append(arena, .{ .row = r });
            continue;
        }
        const b = plan.collections[group.binding_id];
        const choices = try binding.choices(arena, plan, b);
        const result = value.materialize(arena, b.plan, choices) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnresolvedConflict => {
                if (require_all) return error.InvalidResolution;
                logical.* = null;
                for (group.rows[1].seq) |r| try emissions.append(arena, .{ .row = r });
                continue;
            },
            else => return error.InvalidResolution,
        };
        var selected = result;
        size_explicit.* = group.size_explicit;
        if (group.size_choice) |choice| {
            const resolved = resolveSizeChoice(arena, plan, choice, result) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.UnresolvedConflict => {
                    if (require_all) return error.InvalidResolution;
                    logical.* = null;
                    for (group.rows[1].seq) |r| try emissions.append(arena, .{ .row = r });
                    continue;
                },
                else => return error.InvalidResolution,
            };
            selected = resolved.node;
            size_explicit.* = resolved.explicit;
        }
        if (!group.inherit_output and group.projections != null) selected = try followInherited(arena, group, selected);
        if (group.promotion_binding) |binding_id| {
            const operation = promotionOperation(plan, binding_id) orelse return error.InvalidMerge;
            switch (operation.resolution) {
                .unresolved => {
                    if (require_all) return error.InvalidResolution;
                    logical.* = null;
                    for (group.rows[1].seq) |r| try emissions.append(arena, .{ .row = r });
                    continue;
                },
                .take => |side| switch (side) {
                    .ours => {},
                    .theirs => selected = try followOutputStructure(arena, group, selected, size_explicit.* or groupUsesCustom(plan, group)),
                    .base => return error.InvalidResolution,
                },
                .custom, .remove => return error.InvalidResolution,
            }
        } else if (hasPromotion(group, selected, size_explicit.*)) return error.InvalidResolution;
        logical.* = selected;
        try emissions.appendSlice(arena, try groupRows(arena, plan, group, selected, size_explicit.*));
    }
    const original = boundary.sequences[1];
    const entry = plan.ours.entry_spans.get(original) orelse return error.InvalidMerge;
    const span = yaml.completeEntrySpan(plan.ours, original) orelse return error.InvalidMerge;
    const header_end = if (std.mem.indexOfScalarPos(u8, plan.ours.bytes, entry.key.start, '\n')) |i| i + 1 else plan.ours.bytes.len;
    const ending = plan.ours.lineEndingAt(entry.whole.start);
    const indent = entry.key.start - entry.whole.start;
    var bytes: std.ArrayList(u8) = .empty;
    if (emissions.items.len == 0) {
        try bytes.appendSlice(arena, plan.ours.bytes[span.start..entry.value.start]);
        if (bytes.items.len > 0 and bytes.items[bytes.items.len - 1] == ':') try bytes.append(arena, ' ');
        try bytes.appendSlice(arena, "[]");
        try bytes.appendSlice(arena, ending);
    } else {
        if (original.seq.len == 0) {
            // The separator before [] is not trailing space on a block header.
            // Retain any actual comment after the replaced empty value.
            try bytes.appendSlice(arena, std.mem.trimEnd(u8, plan.ours.bytes[span.start..entry.value.start], " \t"));
            try bytes.appendSlice(arena, std.mem.trimEnd(u8, plan.ours.bytes[entry.value.end..header_end], "\r\n"));
            try bytes.appendSlice(arena, ending);
        } else try bytes.appendSlice(arena, plan.ours.bytes[span.start..header_end]);
        for (emissions.items) |emission| {
            const rendered = try renderRow(arena, emission, boundary.files, indent, ending);
            try bytes.appendSlice(arena, rendered);
            if (!std.mem.endsWith(u8, rendered, "\n")) try bytes.appendSlice(arena, ending);
        }
    }
    const replacement_bytes = try bytes.toOwnedSlice(arena);
    const candidate = try @import("merge_apply.zig").applyPatches(arena, plan.ours.bytes, &.{.{ .span = span, .replacement = replacement_bytes, .atomic_id = 0 }});
    const parsed = try parser.parseSpanned(arena, candidate);
    if (parsed.diagnostics.len != 0) return error.InvalidResolution;
    const doc = findDoc(parsed, boundary.document) orelse return error.InvalidResolution;
    for (boundary.groups, expected, expected_sizes) |group, logical, size_explicit| {
        if (!group.collection or group.raw or logical == null) continue;
        const materialized = if (groupUsesCustom(plan, group))
            projection.projectAcceptedExplicitGrowth(arena, boundary.output, .{ .file = parsed, .document = doc }, group.target, group.root) catch return error.InvalidResolution
        else
            projection.project(arena, boundary.output, .{ .file = parsed, .document = doc }, group.target, group.root) catch return error.InvalidResolution;
        if (!model.Node.eql(materialized.node, logical.?)) return error.InvalidResolution;
        if (!group.inherit_output) try validateMasks(group, logical.?, materialized.node, group.projections.?[3].node, materialized);
        const size_path = try std.fmt.allocPrint(arena, "{s}.Array.size", .{group.root});
        var size_found = false;
        for (projection.rows(doc).?.seq) |r| {
            const target = field(r, "target") orelse return error.InvalidResolution;
            const path = field(r, "propertyPath") orelse return error.InvalidResolution;
            if (target.* == .ref and projection.sameRef(target.ref, group.target) and path.* == .scalar and std.mem.eql(u8, path.scalar, size_path)) size_found = true;
        }
        if (size_found != (size_explicit or logical.?.seq.len != group.projections.?[3].node.seq.len)) return error.InvalidResolution;
    }
    return .{ .span = span, .bytes = replacement_bytes };
}
fn groupUsesCustom(plan: *const mm.MergePlan, group: Group) bool {
    for (plan.collections[group.binding_id].operation_ids) |id| {
        if (mm.operationByIdConst(plan, id).?.resolution == .custom) return true;
    }
    return false;
}

fn validateSparseSelection(group: Group, selected: *const model.Node) mm.Error!void {
    const ps = group.projections.?;
    if (!ps[0].sparse and !ps[1].sparse and !ps[2].sparse) return;
    const template = for (ps[0..3]) |p| {
        if (p.node.seq.len > 0) break p.node.seq[0];
    } else return error.InvalidResolution;
    for (selected.seq) |item| {
        if (projection.coverageEqual(template, item)) continue;
        const authored = found: for (ps[0..3]) |p| {
            for (p.node.seq) |candidate| {
                if (item == candidate) break :found true;
            }
        } else false;
        if (!authored) return error.InvalidResolution;
    }
}

pub fn validateSelection(arena: A, plan: *const mm.MergePlan, reference: mm.CollectionRef) mm.Error!void {
    if (reference.binding >= plan.collections.len) return error.InvalidResolution;
    const selected_binding = plan.collections[reference.binding];
    const link = selected_binding.variant orelse return;
    const group = link.boundary.groups[link.group];
    if (reference.binding != group.binding_id or group.raw or group.projections == null) return;
    const b = plan.collections[group.binding_id];
    const choices = try binding.choices(arena, plan, b);
    for (choices) |*choice| {
        if (choice.* == .unresolved) choice.* = .{ .take = .ours };
    }
    var selected = value.materialize(arena, b.plan, choices) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResolution,
    };
    if (!group.inherit_output) selected = try followInherited(arena, group, selected);
    const result = selected orelse return;
    if (result.* != .seq) return error.InvalidResolution;
    try validateSparseSelection(group, result);
}

fn promotionOperation(plan: *const mm.MergePlan, binding_id: usize) ?*const mm.Operation {
    if (binding_id >= plan.collections.len) return null;
    const ids = plan.collections[binding_id].operation_ids;
    if (ids.len != 1) return null;
    return mm.operationByIdConst(plan, ids[0]);
}

pub fn isPromotion(plan: *const mm.MergePlan, operation_id: mm.OperationId) bool {
    const operation = mm.operationByIdConst(plan, operation_id) orelse return false;
    const reference = operation.collection orelse return false;
    if (reference.binding >= plan.collections.len) return false;
    const link = plan.collections[reference.binding].variant orelse return false;
    return link.boundary.groups[link.group].promotion_binding == reference.binding;
}

pub fn promotionValue(arena: A, plan: *const mm.MergePlan, operation_id: mm.OperationId, side: mm.Side) mm.Error!mm.SideValue {
    if (side == .base or !isPromotion(plan, operation_id)) return error.InvalidResolution;
    const operation = mm.operationByIdConst(plan, operation_id) orelse return error.InvalidResolution;
    const reference = operation.collection orelse return error.InvalidResolution;
    const link = plan.collections[reference.binding].variant orelse return error.InvalidResolution;
    const group = link.boundary.groups[link.group];
    const b = plan.collections[group.binding_id];
    const choices = try binding.choices(arena, plan, b);
    var selected = value.materialize(arena, b.plan, choices) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResolution,
    };
    var size_explicit = group.size_explicit;
    if (group.size_choice) |choice| {
        const resolved = resolveSizeChoice(arena, plan, choice, selected) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidResolution,
        };
        selected = resolved.node;
        size_explicit = resolved.explicit;
    }
    if (!group.inherit_output and group.projections != null) selected = try followInherited(arena, group, selected);
    if (side == .theirs) selected = try followOutputStructure(arena, group, selected, size_explicit or groupUsesCustom(plan, group));
    const node = selected orelse return error.InvalidResolution;
    const bytes = yaml.flow(arena, node) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResolution,
    };
    return .{ .node = node, .span = null, .bytes = bytes };
}

pub fn provenance(arena: A, plan: *const mm.MergePlan) mm.Error!VariantProvenance {
    var effects: std.ArrayList(VariantEffect) = .empty;
    var pending_groups: usize = 0;
    for (plan.collections) |collection| {
        const link = collection.variant orelse continue;
        if (!link.emit or link.group != 0) continue;
        for (link.boundary.groups) |group| {
            if (auxiliaryPending(plan, group)) {
                pending_groups += 1;
                continue;
            }
            const b = plan.collections[group.binding_id];
            const choices = try binding.choices(arena, plan, b);
            const result = value.materialize(arena, b.plan, choices) catch |err| switch (err) {
                error.UnresolvedConflict => {
                    pending_groups += 1;
                    continue;
                },
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidResolution,
            };
            var selected = result;
            var size_explicit = group.size_explicit;
            if (group.size_choice) |choice| {
                const resolved = resolveSizeChoice(arena, plan, choice, result) catch |err| switch (err) {
                    error.UnresolvedConflict => {
                        pending_groups += 1;
                        continue;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidResolution,
                };
                selected = resolved.node;
                size_explicit = resolved.explicit;
            }
            if (!group.inherit_output and group.projections != null) selected = try followInherited(arena, group, selected);
            var decision_operation: ?mm.OperationId = null;
            if (group.promotion_binding) |binding_id| {
                const operation = promotionOperation(plan, binding_id) orelse return error.InvalidMerge;
                decision_operation = operation.id;
                switch (operation.resolution) {
                    .unresolved => {
                        pending_groups += 1;
                        continue;
                    },
                    .take => |side| switch (side) {
                        .ours => {},
                        .theirs => selected = try followOutputStructure(arena, group, selected, size_explicit or groupUsesCustom(plan, group)),
                        .base => return error.InvalidResolution,
                    },
                    .custom, .remove => return error.InvalidResolution,
                }
            }
            try appendPromotionEffects(arena, &effects, link.boundary.document, group, selected, size_explicit, decision_operation);
        }
    }
    return .{ .effects = try effects.toOwnedSlice(arena), .pending_groups = pending_groups };
}

fn appendPromotionEffects(arena: A, effects: *std.ArrayList(VariantEffect), document: mm.DocumentId, group: Group, selected: ?*const model.Node, size_explicit: bool, decision_operation: ?mm.OperationId) mm.Error!void {
    const result = selected orelse return;
    const output = group.projections orelse return;
    if (result.* != .seq or output[3].node.* != .seq) return error.InvalidResolution;
    if (!size_explicit and result.seq.len != output[3].node.seq.len) {
        try effects.append(arena, .{
            .document = document,
            .target = group.target,
            .property_path = try std.fmt.allocPrint(arena, "{s}.Array.size", .{group.root}),
            .origin_side = null,
            .origin_path = null,
            .kind = .inherited_size_to_explicit,
            .source_value = try sizeNode(arena, output[3].node.seq.len),
            .result_value = try sizeNode(arena, result.seq.len),
            .decision_operation = decision_operation,
        });
    }
    for (result.seq, 0..) |item, index| {
        const inherited = if (index < output[3].node.seq.len) output[3].node.seq[index] else null;
        try appendPromotedLeaves(arena, effects, document, group, item, inherited, try std.fmt.allocPrint(arena, "{s}.Array.data[{d}]", .{ group.root, index }), decision_operation);
    }
}

fn sizeNode(arena: A, size: usize) A.Error!*const model.Node {
    return value.node(arena, .{ .scalar = try std.fmt.allocPrint(arena, "{d}", .{size}) });
}

fn appendPromotedLeaves(arena: A, effects: *std.ArrayList(VariantEffect), document: mm.DocumentId, group: Group, result: *const model.Node, output: ?*const model.Node, path: []const u8, decision_operation: ?mm.OperationId) mm.Error!void {
    if (result.* == .map) {
        for (result.map) |entry| {
            const inherited = if (output) |candidate| field(candidate, entry.key) else null;
            try appendPromotedLeaves(arena, effects, document, group, entry.value, inherited, try std.fmt.allocPrint(arena, "{s}.{s}", .{ path, entry.key }), decision_operation);
        }
        return;
    }
    if (result.* == .seq) return error.InvalidResolution;
    const leaf = origin(group, result) orelse return;
    if (leaf.explicit or (output != null and model.Node.eql(result, output.?))) return;
    const detail = originDetail(group, result);
    try effects.append(arena, .{
        .document = document,
        .target = group.target,
        .property_path = path,
        .origin_side = detail.side,
        .origin_path = detail.path,
        .kind = .inherited_to_explicit,
        .source_value = output,
        .result_value = result,
        .decision_operation = decision_operation,
    });
}

fn originDetail(group: Group, node: *const model.Node) struct { side: ?mm.Side, path: ?[]const u8 } {
    const ps = group.projections orelse return .{ .side = null, .path = null };
    for (ps, 0..) |p, side| for (p.leaves) |leaf| {
        if (leaf.node != node) continue;
        const origin_path = if (leaf.row) |row| if (field(row, "propertyPath")) |property_path| if (property_path.* == .scalar) property_path.scalar else null else null else null;
        return .{ .side = switch (side) {
            0 => .base,
            1 => .ours,
            2 => .theirs,
            else => null,
        }, .path = origin_path };
    };
    return .{ .side = null, .path = null };
}

fn auxiliaryPending(plan: *const mm.MergePlan, group: Group) bool {
    if (group.size_choice) |choice| {
        for (plan.collections[choice.binding_id].operation_ids) |id| {
            if (mm.operationByIdConst(plan, id).?.resolution == .unresolved) return true;
        }
    }
    for (group.templates) |template| if (template.binding_id) |binding_id| {
        for (plan.collections[binding_id].operation_ids) |id| {
            if (mm.operationByIdConst(plan, id).?.resolution == .unresolved) return true;
        }
    };
    return false;
}

const ResolvedSize = struct { node: ?*const model.Node, explicit: bool };
fn resolveSizeChoice(arena: A, plan: *const mm.MergePlan, choice: SizeChoice, logical: ?*const model.Node) (value.Error || mm.Error)!ResolvedSize {
    const b = plan.collections[choice.binding_id];
    const selected_choices = try binding.choices(arena, plan, b);
    const suffix = try value.materialize(arena, b.plan, selected_choices);
    const operation = mm.operationByIdConst(plan, b.operation_ids[0]) orelse return error.InvalidMerge;
    const selected = suffix orelse try value.node(arena, .{ .seq = &.{} });
    if (selected.* != .seq) return error.InvalidResolution;
    const explicit = switch (operation.resolution) {
        .take => |side| choice.explicit[@intFromEnum(side)],
        .custom, .remove => true,
        .unresolved => return error.UnresolvedConflict,
    };
    const current = logical orelse return error.InvalidResolution;
    if (current.* != .seq) return error.InvalidResolution;
    const target_len = choice.start + selected.seq.len;
    if (target_len <= current.seq.len) return .{ .node = try value.node(arena, .{ .seq = current.seq[0..target_len] }), .explicit = explicit };
    const items = try arena.alloc(*model.Node, target_len);
    @memcpy(items[0..current.seq.len], current.seq);
    const selected_start = current.seq.len -| choice.start;
    if (selected_start + target_len - current.seq.len > selected.seq.len) return error.InvalidResolution;
    @memcpy(items[current.seq.len..], selected.seq[selected_start..][0 .. target_len - current.seq.len]);
    return .{ .node = try value.node(arena, .{ .seq = items }), .explicit = explicit };
}

fn sizeExplicit(arena: A, sequence: *const model.Node) mm.Error!bool {
    for (sequence.seq) |r| {
        const p = field(r, "propertyPath") orelse continue;
        if (p.* != .scalar) continue;
        const segments = property.parse(arena, p.scalar) catch continue;
        if (segments.len > 0 and segments[segments.len - 1] == .size) return true;
    }
    return false;
}
pub fn linkSourceChoices(state: binding.State, operations: []mm.Operation) void {
    for (state.bindings.items) |b| {
        const link = b.variant orelse continue;
        if (link.group != 0) continue;
        const boundary = link.boundary;
        const base = field(findDoc(boundary.files[0], boundary.document).?.body, "m_SourcePrefab") orelse continue;
        const ours = field(findDoc(boundary.files[1], boundary.document).?.body, "m_SourcePrefab") orelse continue;
        const theirs = field(findDoc(boundary.files[2], boundary.document).?.body, "m_SourcePrefab") orelse continue;
        if (model.Node.eql(base, ours) and model.Node.eql(base, theirs)) continue;
        for (operations) |*op| {
            if (op.identity.document.class_id == boundary.document.class_id and op.identity.document.file_id == boundary.document.file_id and std.mem.eql(u8, op.property_path, "m_SourcePrefab")) op.resolution = .unresolved;
        }
    }
}

pub fn validateSources(arena: A, plan: *const mm.MergePlan, output: []const u8) mm.Error!void {
    if (plan.collections.len == 0) return;
    var parsed: ?source.ParsedFile = null;
    for (plan.collections) |b| {
        const link = b.variant orelse continue;
        if (link.group != 0) continue;
        const boundary = link.boundary;
        var pending_source = false;
        for (plan.operations) |op| {
            if (op.identity.document.class_id == boundary.document.class_id and op.identity.document.file_id == boundary.document.file_id and std.mem.eql(u8, op.property_path, "m_SourcePrefab") and op.resolution == .unresolved) pending_source = true;
        }
        if (pending_source) continue;
        if (parsed == null) parsed = try parser.parseSpanned(arena, output);
        const doc = findDoc(parsed.?, boundary.document) orelse continue;
        const prefab_source = field(doc.body, "m_SourcePrefab") orelse return error.InvalidResolution;
        if (prefab_source.* != .ref) return error.InvalidResolution;
        const list = projection.rows(doc) orelse return error.InvalidResolution;
        if (list.* != .seq) return error.InvalidResolution;
        for (list.seq) |r| {
            const id = try rowIdentity(arena, r);
            if (!id.collection) continue;
            if (id.target.guid == null or prefab_source.ref.guid == null or !std.mem.eql(u8, id.target.guid.?, prefab_source.ref.guid.?)) return error.InvalidResolution;
        }
    }
}

fn validateMasks(group: Group, selected: *const model.Node, actual: *const model.Node, inherited: ?*const model.Node, materialized: projection.Projection) mm.Error!void {
    switch (selected.*) {
        .map => |entries| for (entries) |entry| {
            try validateMasks(group, entry.value, field(actual, entry.key) orelse return error.InvalidResolution, if (inherited) |n| field(n, entry.key) else null, materialized);
        },
        .seq => |items| for (items, 0..) |item, i| {
            if (actual.* != .seq or i >= actual.seq.len) return error.InvalidResolution;
            try validateMasks(group, item, actual.seq[i], if (inherited != null and inherited.?.* == .seq and i < inherited.?.seq.len) inherited.?.seq[i] else null, materialized);
        },
        else => {
            const leaf = origin(group, selected);
            const intended = (if (leaf) |l| l.explicit else true) or inherited == null or !model.Node.eql(selected, inherited.?);
            const observed = for (materialized.leaves) |l| {
                if (l.node == actual) break l.explicit;
            } else return error.InvalidResolution;
            if (intended != observed) return error.InvalidResolution;
        },
    }
}

fn skeleton(arena: A, file: source.ParsedFile, optional: ?*const model.Node) mm.Error!?[]const u8 {
    const row = optional orelse return null;
    const span = file.sequence_item_spans.get(row) orelse return error.InvalidMerge;
    if (row.* != .map) return error.InvalidMerge;
    var patches: std.ArrayList(@import("merge_apply.zig").Patch) = .empty;
    for (row.map) |entry| {
        const location = file.entry_spans.get(entry.value) orelse return error.InvalidMerge;
        try patches.append(arena, .{ .span = .{ .start = location.value.start - span.start, .end = location.value.end - span.start }, .replacement = "<value>", .atomic_id = 0 });
    }
    return try @import("merge_apply.zig").applyPatches(arena, span.bytes(file.bytes), patches.items);
}
fn sameBytes(a: ?[]const u8, b: ?[]const u8) bool {
    return if (a) |left| b != null and std.mem.eql(u8, left, b.?) else b == null;
}
