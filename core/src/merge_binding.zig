const std = @import("std");
const model = @import("model.zig");
const mm = @import("merge_model.zig");
const value = @import("merge_value.zig");
const yaml = @import("merge_yaml.zig");
const source = @import("source.zig");
pub const Binding = struct { plan: value.Plan, source_nodes: value.Nodes, original: ?*const model.Node, identity: mm.SemanticId, operation_ids: []const mm.OperationId };
pub const State = struct { bindings: std.ArrayList(Binding) = .empty, context: @import("merge_context.zig").Context = .{} };
pub fn collect(arena: std.mem.Allocator, state: *State, operations: *std.ArrayList(mm.Operation), atomics: *std.ArrayList(mm.AtomicOperation), document: mm.DocumentId, path: []const u8, hierarchy: []const u8, nodes: value.Nodes, files: [3]source.ParsedFile) mm.Error!void {
    const original = nodes.ours;
    const evidence = schema(state.context, document, path, files);
    var plan = value.build(arena, .{ .nodes = nodes, .schema = evidence.field, .context_conflict = evidence.conflict }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResolution,
    };
    const probe_choices = try arena.alloc(value.Choice, plan.conflicts.len);
    @memset(probe_choices, .{ .take = .ours });
    const probe = value.materialize(arena, plan, probe_choices) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    if (probe) |result| {
        _ = preserveItems(arena, result, nodes, files) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                plan = value.conflicted(arena, plan.input, .source_bytes) catch |failure| switch (failure) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidResolution,
                };
            },
        };
    }
    const binding_id = state.bindings.items.len;
    var ids: std.ArrayList(mm.OperationId) = .empty;
    for (plan.conflicts, 0..) |c, i| {
        const id: mm.OperationId = @intCast(operations.items.len);
        const atomic_id: mm.AtomicId = @intCast(atomics.items.len);
        try operations.append(arena, .{ .id = id, .atomic_id = atomic_id, .kind = .field, .identity = .{ .document = document, .property_path = path }, .hierarchy_path = hierarchy, .property_path = path, .item_path = if (c.path.len > 0) c.path else null, .values = .{ .base = try side(arena, c.nodes.base, files), .ours = try side(arena, c.nodes.ours, files), .theirs = try side(arena, c.nodes.theirs, files) }, .resolution = .unresolved, .collection = .{ .binding = binding_id, .conflict = i } });
        const members = try arena.dupe(mm.OperationId, &.{id});
        try atomics.append(arena, .{ .id = atomic_id, .kind = .field, .operation_ids = members });
        try ids.append(arena, id);
    }
    try state.bindings.append(arena, .{ .plan = plan, .source_nodes = nodes, .original = original, .identity = .{ .document = document, .property_path = path }, .operation_ids = try ids.toOwnedSlice(arena) });
}
fn side(arena: std.mem.Allocator, n: ?*const model.Node, files: [3]source.ParsedFile) mm.Error!?mm.SideValue {
    const v = n orelse return null;
    const bytes = blk: {
        for (files) |file| {
            if (file.sequenceItemBytes(v)) |raw| break :blk std.mem.trim(u8, raw, "\r\n");
        }
        break :blk yaml.flow(arena, v) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidResolution,
        };
    };
    return .{ .node = v, .span = null, .bytes = bytes };
}
pub fn choices(arena: std.mem.Allocator, plan: *const mm.MergePlan, binding: Binding) mm.Error![]value.Choice {
    const result = try arena.alloc(value.Choice, binding.operation_ids.len);
    for (binding.operation_ids, result) |id, *choice| {
        const op = mm.operationByIdConst(plan, id) orelse return error.InvalidMerge;
        choice.* = switch (op.resolution) {
            .unresolved => .unresolved,
            .remove => .remove,
            .take => |s| .{ .take = @enumFromInt(@intFromEnum(s)) },
            .custom => |text| blk: {
                const parsed = yaml.parseValue(arena, text) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidResolution,
                };
                const reference = op.collection orelse break :blk .{ .custom = parsed };
                break :blk .{ .custom = try pairCustom(arena, binding.plan.conflicts[reference.conflict], parsed) };
            },
        };
    }
    return result;
}
pub fn replacement(arena: std.mem.Allocator, plan: *const mm.MergePlan, binding: Binding, require_all: bool) mm.Error!?yaml.Replacement {
    const selected = try choices(arena, plan, binding);
    const result = value.materialize(arena, binding.plan, selected) catch |err| switch (err) {
        error.UnresolvedConflict => {
            if (require_all) return error.InvalidResolution;
            return null;
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResolution,
    };
    if (result == null) {
        const original = binding.original orelse return null;
        return .{ .span = plan.ours.completeEntrySpan(original) orelse return error.InvalidMerge, .bytes = "" };
    }
    var final = result.?;
    const borrowed = final == binding.plan.input.nodes.ours or final == binding.plan.input.nodes.theirs or final == binding.plan.input.nodes.base;
    if (!borrowed) inline for (.{ binding.plan.input.nodes.ours, binding.plan.input.nodes.theirs, binding.plan.input.nodes.base }) |n| {
        if (n) |v| {
            if (model.Node.eql(final, v)) {
                final = v;
                break;
            }
        }
    };
    const explicit_source = for (binding.plan.conflicts) |conflict| {
        if (conflict.reason == .source_bytes) break true;
    } else false;
    if (!explicit_source) final = try preserveItems(arena, final, binding.source_nodes, .{ plan.base, plan.ours, plan.theirs });
    const original = binding.original orelse return try insertReplacement(arena, plan, binding, final);
    if (binding.plan.input.schema) |descriptor| {
        if (descriptor.kind == .int32_array and final.* == .scalar and final.scalar.len == 0) {
            const entry = plan.ours.entry_spans.get(original) orelse return error.InvalidMerge;
            const span = plan.ours.completeEntrySpan(original) orelse return error.InvalidMerge;
            return .{ .span = span, .bytes = try std.mem.concat(arena, u8, &.{ plan.ours.bytes[span.start..entry.value.start], plan.ours.bytes[entry.value.end..span.end] }) };
        }
    }
    return yaml.replaceEntry(arena, plan.ours, original, final, &.{ plan.ours, plan.theirs, plan.base }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResolution,
    };
}

const ctx = @import("merge_context.zig");
const Evidence = struct { field: ?ctx.Field = null, conflict: bool = false };
fn field(snapshot: ctx.Snapshot, file: source.ParsedFile, document: mm.DocumentId, path: []const u8) ?ctx.Field {
    for (file.documents) |doc| {
        if (doc.class_id != document.class_id or doc.file_id != document.file_id) continue;
        const script = doc.body.get("m_Script") orelse return null;
        if (script.* != .ref) return null;
        return snapshot.field(script.ref.guid orelse return null, path);
    }
    return null;
}
pub fn schema(context: ctx.Context, document: mm.DocumentId, path: []const u8, files: [3]source.ParsedFile) Evidence {
    const b = field(context.base, files[0], document, path);
    const o = field(context.ours, files[1], document, path);
    const t = field(context.theirs, files[2], document, path);
    if (b == null and o == null and t == null) return .{};
    if (b == null or o == null or t == null) return .{ .conflict = true };
    if (!b.?.sameType(o.?) or !b.?.sameType(t.?)) return .{ .conflict = true };
    // Output evidence can reject a schema selected by an independently merged script.
    const output_field = field(context.output, files[1], document, path);
    if (output_field == null and (context.output.revision.len > 0 or context.output.scripts.len > 0)) return .{ .conflict = true };
    if (output_field) |output| {
        if (!b.?.sameType(output)) return .{ .conflict = true };
    }
    return .{ .field = b };
}

pub fn validateSelection(arena: std.mem.Allocator, plan: *const mm.MergePlan, reference: mm.CollectionRef) mm.Error!void {
    const binding = plan.collections[reference.binding];
    const selected = try choices(arena, plan, binding);
    // Validate a local edit immediately, even when another conflict keeps the
    // collection compositor on the original Ours bytes.
    for (selected) |*choice| {
        if (choice.* == .unresolved) choice.* = .{ .take = .ours };
    }
    _ = value.materialize(arena, binding.plan, selected) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResolution,
    };
}

fn pairCustom(arena: std.mem.Allocator, conflict: value.Conflict, parsed: *const model.Node) mm.Error!*const model.Node {
    if (conflict.sequence) {
        if (parsed.* != .seq) return error.InvalidResolution;
        return parsed;
    }
    if (parsed.* == .map or parsed.* == .seq) return parsed;
    const template = conflict.nodes.ours orelse conflict.nodes.theirs orelse conflict.nodes.base orelse
        return error.InvalidResolution;
    if (template.* != .map) return parsed;
    var value_key: ?[]const u8 = null;
    for (template.map) |entry| {
        if (std.mem.eql(u8, entry.key, "value") or std.mem.eql(u8, entry.key, "second")) {
            value_key = entry.key;
            break;
        }
    }
    const value_field = value_key orelse return parsed;
    const entries = try arena.dupe(model.Entry, template.map);
    for (entries) |*entry| {
        if (std.mem.eql(u8, entry.key, value_field)) entry.value = @constCast(parsed);
    }
    return value.node(arena, .{ .map = entries });
}

fn uniqueItem(sequence: *const model.Node, target: *const model.Node) ?*const model.Node {
    var found: ?*const model.Node = null;
    for (sequence.seq) |item| {
        if (model.Node.eql(item, target)) {
            if (found != null) return null;
            found = item;
        }
    }
    return found;
}
fn itemBytes(file: source.ParsedFile, item: *const model.Node) ?[]const u8 {
    return file.sequenceItemBytes(item);
}
fn preserveItems(arena: std.mem.Allocator, result: *const model.Node, n: value.Nodes, files: [3]source.ParsedFile) mm.Error!*const model.Node {
    if (result.* != .seq or n.base == null or n.ours == null or n.theirs == null or n.base.?.* != .seq or n.ours.?.* != .seq or n.theirs.?.* != .seq) return result;
    if (try headerBytes(arena, files[0], n.base.?)) |base_header| {
        if (try headerBytes(arena, files[1], n.ours.?)) |ours_header| {
            if (try headerBytes(arena, files[2], n.theirs.?)) |theirs_header| {
                const selected_header = if (result == n.theirs.?) theirs_header else ours_header;
                if ((!std.mem.eql(u8, base_header, ours_header) and !std.mem.eql(u8, selected_header, ours_header)) or
                    (!std.mem.eql(u8, base_header, theirs_header) and !std.mem.eql(u8, selected_header, theirs_header))) return error.UnsupportedStructure;
            }
        }
    }
    for (n.base.?.seq) |base_item| {
        if (uniqueItem(n.base.?, base_item) != null) continue;
        const raw = itemBytes(files[0], base_item) orelse continue;
        var base_raw_count: usize = 0;
        for (n.base.?.seq) |item| {
            if (!model.Node.eql(base_item, item)) continue;
            if (itemBytes(files[0], item)) |candidate| {
                if (std.mem.eql(u8, raw, candidate)) base_raw_count += 1;
            }
        }
        for ([_]struct { sequence: *const model.Node, file: source.ParsedFile }{ .{ .sequence = n.ours.?, .file = files[1] }, .{ .sequence = n.theirs.?, .file = files[2] } }) |side_source| {
            var equal_count: usize = 0;
            var raw_count: usize = 0;
            for (side_source.sequence.seq) |item| {
                if (!model.Node.eql(base_item, item)) continue;
                equal_count += 1;
                if (itemBytes(side_source.file, item)) |candidate| {
                    if (std.mem.eql(u8, raw, candidate)) raw_count += 1;
                }
            }
            // One surviving raw span cannot account for several equal Base
            // occurrences. A deficit may hide an edited occurrence's bytes.
            if (raw_count < @min(base_raw_count, equal_count)) return error.UnsupportedStructure;
        }
    }
    const items = try arena.dupe(*model.Node, result.seq);
    var changed = false;
    for (items) |*item| {
        const b = uniqueItem(n.base.?, item.*) orelse continue;
        const o = uniqueItem(n.ours.?, item.*) orelse continue;
        const t = uniqueItem(n.theirs.?, item.*) orelse continue;
        const b_bytes = itemBytes(files[0], b) orelse continue;
        const o_bytes = itemBytes(files[1], o) orelse continue;
        const t_bytes = itemBytes(files[2], t) orelse continue;
        const selected = if (std.mem.eql(u8, o_bytes, t_bytes) or std.mem.eql(u8, b_bytes, t_bytes)) o else if (std.mem.eql(u8, b_bytes, o_bytes)) t else return error.UnsupportedStructure;
        const selected_bytes = if (selected == o) o_bytes else t_bytes;
        const current_bytes = for (files) |file| {
            if (itemBytes(file, item.*)) |bytes| break bytes;
        } else null;
        if (current_bytes) |bytes| {
            if (std.mem.eql(u8, bytes, selected_bytes)) continue;
        }
        if (item.* != selected) {
            item.* = @constCast(selected);
            changed = true;
        }
    }
    for (items) |*item| {
        const has_bytes = for (files) |file| {
            if (itemBytes(file, item.*) != null) break true;
        } else false;
        if (has_bytes) continue;
        const selected = uniqueItem(n.theirs.?, item.*) orelse uniqueItem(n.ours.?, item.*) orelse uniqueItem(n.base.?, item.*) orelse continue;
        if (item.* != selected) {
            item.* = @constCast(selected);
            changed = true;
        }
    }
    return if (changed) try value.node(arena, .{ .seq = items }) else result;
}

fn insertReplacement(arena: std.mem.Allocator, plan: *const mm.MergePlan, binding: Binding, final: *const model.Node) mm.Error!yaml.Replacement {
    const template_side: mm.Side = if (binding.source_nodes.theirs != null) .theirs else .base;
    const template = if (template_side == .theirs) binding.source_nodes.theirs.? else binding.source_nodes.base.?;
    const file = if (template_side == .theirs) plan.theirs else plan.base;
    const rendered = yaml.replaceEntry(arena, file, template, final, &.{ plan.ours, plan.theirs, plan.base }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResolution,
    };
    const operation: mm.Operation = .{ .id = 0, .atomic_id = 0, .kind = .field, .identity = binding.identity, .hierarchy_path = "", .property_path = binding.identity.property_path, .values = .{ .base = try side(arena, binding.source_nodes.base, .{ plan.base, plan.ours, plan.theirs }), .ours = null, .theirs = try side(arena, binding.source_nodes.theirs, .{ plan.base, plan.ours, plan.theirs }) }, .resolution = .{ .take = template_side } };
    const offset = try @import("merge_apply.zig").insertionOffset(plan, &operation);
    return .{ .span = .{ .start = offset, .end = offset }, .bytes = rendered.bytes };
}

pub fn patchOrder(plan: *const mm.MergePlan, binding: Binding) usize {
    if (binding.original != null) return 0;
    const template = binding.source_nodes.theirs orelse binding.source_nodes.base orelse return 0;
    const file = if (binding.source_nodes.theirs != null) plan.theirs else plan.base;
    return if (file.entry_spans.get(template)) |entry| entry.whole.start else 0;
}

fn headerBytes(arena: std.mem.Allocator, file: source.ParsedFile, n: *const model.Node) std.mem.Allocator.Error!?[]const u8 {
    const entry = file.entry_spans.get(n) orelse return null;
    const end = if (std.mem.indexOfScalarPos(u8, file.bytes, entry.key.start, '\n')) |index| index + 1 else file.bytes.len;
    if (entry.value.end > end) return null;
    return try std.mem.concat(arena, u8, &.{ file.bytes[entry.whole.start..entry.value.start], file.bytes[entry.value.end..end] });
}
