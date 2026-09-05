const std = @import("std");
const core = @import("core");
const display = @import("display.zig");
const merge_ui_state = @import("merge_ui_state.zig");

const testing = std.testing;

pub const Kind = enum { game_object, components, component, conflict };
pub const Connector = enum { root, tee, elbow, continuation };

pub const Row = struct {
    kind: Kind,
    connector: Connector,
    depth: u16,
    label: []const u8,
    conflict_index: ?usize = null,
};

pub const Model = struct {
    rows: []const Row,
    conflict_rows: []const usize,

    pub fn rowForConflict(self: Model, conflict_index: usize) ?usize {
        if (conflict_index >= self.conflict_rows.len) return null;
        return self.conflict_rows[conflict_index];
    }
};

const NodeKey = union(enum) {
    object: i64,
    component: i64,
};

const DraftNode = struct {
    key: NodeKey,
    parent: ?NodeKey,
    name: []const u8,
    kind: Kind,
    children: std.ArrayList(NodeKey) = .empty,
};

const ConflictDraft = struct {
    ordinal: usize,
    label: []const u8,
};

const Builder = struct {
    arena: std.mem.Allocator,
    nodes: std.AutoHashMapUnmanaged(NodeKey, DraftNode) = .empty,
    roots: std.ArrayList(NodeKey) = .empty,
    document_owner: std.AutoHashMapUnmanaged(i64, NodeKey) = .empty,
    conflicts: std.AutoHashMapUnmanaged(NodeKey, std.ArrayList(ConflictDraft)) = .empty,
    focus_ordinals: std.AutoHashMapUnmanaged(NodeKey, std.ArrayList(usize)) = .empty,

    fn addResult(self: *Builder, result: core.model.DiffResult) !void {
        for (result.roots) |object| try self.addObject(object, null);
        for (result.loose) |component| try self.addComponent(component, null);
    }

    fn addObject(
        self: *Builder,
        object: core.model.ObjectDiff,
        parent: ?NodeKey,
    ) !void {
        const key: NodeKey = .{ .object = object.file_id };
        if (!self.nodes.contains(key)) {
            try self.nodes.put(self.arena, key, .{
                .key = key,
                .parent = parent,
                .name = display.objectName(object, null),
                .kind = .game_object,
            });
            if (parent) |parent_key| {
                try self.nodes.getPtr(parent_key).?.children.append(self.arena, key);
            } else {
                try self.roots.append(self.arena, key);
            }
        }
        if (!self.document_owner.contains(object.file_id)) {
            try self.document_owner.put(self.arena, object.file_id, key);
        }
        for (object.components) |component| try self.addComponent(component, key);
        for (object.children) |child| try self.addObject(child, key);
    }

    fn addComponent(
        self: *Builder,
        component: core.model.ComponentDiff,
        parent: ?NodeKey,
    ) !void {
        const key: NodeKey = .{ .component = component.file_id };
        if (!self.nodes.contains(key)) {
            try self.nodes.put(self.arena, key, .{
                .key = key,
                .parent = parent,
                .name = display.componentName(component, null),
                .kind = .component,
            });
            if (parent) |parent_key| {
                try self.nodes.getPtr(parent_key).?.children.append(self.arena, key);
            } else {
                try self.roots.append(self.arena, key);
            }
        }
        if (!self.document_owner.contains(component.file_id)) {
            try self.document_owner.put(self.arena, component.file_id, key);
        }
    }

    fn addConflicts(
        self: *Builder,
        plan: *const core.merge.MergePlan,
        conflict_indices: []const usize,
    ) !void {
        for (conflict_indices, 0..) |operation_index, ordinal| {
            const operation = &plan.operations[operation_index];
            const atomic_kind = for (plan.atomic_operations) |atomic| {
                if (atomic.id == operation.atomic_id) break atomic.kind;
            } else operation.kind;
            switch (atomic_kind) {
                .document => {
                    const owner = self.document_owner.get(operation.identity.document.file_id) orelse
                        try self.addFallback(operation, .component);
                    try self.addFocus(owner, ordinal);
                },
                .component => {
                    const owner = self.componentTarget(operation) orelse
                        try self.addFallback(operation, .component);
                    try self.addFocus(owner, ordinal);
                },
                .game_object => {
                    const owner = self.document_owner.get(operation.identity.document.file_id) orelse
                        try self.addFallback(operation, .game_object);
                    try self.addFocus(owner, ordinal);
                },
                .reparent => {
                    const owner = self.reparentTarget(operation) orelse
                        try self.addFallback(operation, .game_object);
                    try self.addFocus(owner, ordinal);
                },
                .field,
                .sequence_membership,
                .sequence_content,
                .sequence_order,
                .prefab_override,
                => {
                    const owner = self.document_owner.get(operation.identity.document.file_id) orelse {
                        const fallback_kind: Kind = if (atomic_kind == .game_object or
                            atomic_kind == .reparent) .game_object else .component;
                        const fallback = try self.addFallback(operation, fallback_kind);
                        try self.addFocus(fallback, ordinal);
                        continue;
                    };
                    const entry = try self.conflicts.getOrPut(self.arena, owner);
                    if (!entry.found_existing) entry.value_ptr.* = .empty;
                    const property_path = if (operation.kind == .prefab_override)
                        operation.identity.property_path
                    else
                        operation.property_path;
                    try entry.value_ptr.append(self.arena, .{
                        .ordinal = ordinal,
                        .label = try core.displayPropertyPath(self.arena, property_path),
                    });
                },
            }
        }
    }

    fn componentTarget(self: *Builder, operation: *const core.merge.Operation) ?NodeKey {
        if (self.document_owner.get(operation.identity.document.file_id)) |owner| {
            if (self.nodes.get(owner).?.kind == .component) return owner;
        }
        const item_ref = operation.identity.item_ref orelse return null;
        const owner = self.document_owner.get(item_ref.file_id) orelse return null;
        if (self.nodes.get(owner).?.kind != .component) return null;
        return owner;
    }

    fn reparentTarget(self: *Builder, operation: *const core.merge.Operation) ?NodeKey {
        const transform = self.document_owner.get(operation.identity.document.file_id) orelse
            return null;
        const transform_node = self.nodes.get(transform).?;
        if (transform_node.kind == .game_object) return transform;
        return transform_node.parent;
    }

    fn addFallback(
        self: *Builder,
        operation: *const core.merge.Operation,
        kind: Kind,
    ) !NodeKey {
        const key: NodeKey = switch (kind) {
            .game_object => .{ .object = operation.identity.document.file_id },
            else => .{ .component = operation.identity.document.file_id },
        };
        if (!self.nodes.contains(key)) {
            try self.nodes.put(self.arena, key, .{
                .key = key,
                .parent = null,
                .name = operation.hierarchy_path,
                .kind = kind,
            });
            try self.roots.append(self.arena, key);
        }
        return key;
    }

    fn addFocus(self: *Builder, key: NodeKey, ordinal: usize) !void {
        const entry = try self.focus_ordinals.getOrPut(self.arena, key);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(self.arena, ordinal);
    }

    fn emit(self: *Builder, conflict_count: usize) !Model {
        var rows: std.ArrayList(Row) = .empty;
        const conflict_rows = try self.arena.alloc(usize, conflict_count);
        @memset(conflict_rows, 0);
        var loose_count: usize = 0;
        for (self.roots.items) |key| {
            if (self.nodes.get(key).?.kind == .component) {
                loose_count += 1;
                continue;
            }
            try self.emitNode(&rows, conflict_rows, key, 0, .root);
        }
        if (loose_count != 0) {
            try rows.append(self.arena, .{
                .kind = .components,
                .connector = .root,
                .depth = 0,
                .label = try std.fmt.allocPrint(self.arena, "components ({d})", .{loose_count}),
            });
            var loose_index: usize = 0;
            for (self.roots.items) |key| {
                if (self.nodes.get(key).?.kind != .component) continue;
                loose_index += 1;
                try self.emitNode(
                    &rows,
                    conflict_rows,
                    key,
                    1,
                    if (loose_index == loose_count) .elbow else .tee,
                );
            }
        }
        return .{
            .rows = try rows.toOwnedSlice(self.arena),
            .conflict_rows = conflict_rows,
        };
    }

    fn emitNode(
        self: *Builder,
        rows: *std.ArrayList(Row),
        conflict_rows: []usize,
        key: NodeKey,
        depth: u16,
        connector: Connector,
    ) !void {
        const node = self.nodes.getPtr(key).?;
        const row_index = rows.items.len;
        const focus_ordinals = self.focus_ordinals.get(key);
        try rows.append(self.arena, .{
            .kind = node.kind,
            .connector = connector,
            .depth = depth,
            .label = node.name,
            .conflict_index = if (focus_ordinals) |ordinals| ordinals.items[0] else null,
        });
        if (focus_ordinals) |ordinals| {
            for (ordinals.items) |ordinal| conflict_rows[ordinal] = row_index;
        }

        if (self.conflicts.get(key)) |conflicts| {
            for (conflicts.items, 0..) |conflict, index| {
                const conflict_row_index = rows.items.len;
                const has_more_children = node.kind == .game_object and node.children.items.len != 0;
                try rows.append(self.arena, .{
                    .kind = .conflict,
                    .connector = if (index + 1 == conflicts.items.len and !has_more_children)
                        .elbow
                    else
                        .tee,
                    .depth = depth + 1,
                    .label = conflict.label,
                    .conflict_index = conflict.ordinal,
                });
                conflict_rows[conflict.ordinal] = conflict_row_index;
            }
        }
        if (node.kind == .component) return;

        var component_count: usize = 0;
        for (node.children.items) |child_key| {
            if (self.nodes.get(child_key).?.kind == .component) component_count += 1;
        }
        const object_count = node.children.items.len - component_count;
        if (component_count != 0) {
            try rows.append(self.arena, .{
                .kind = .components,
                .connector = if (object_count == 0) .elbow else .tee,
                .depth = depth + 1,
                .label = try std.fmt.allocPrint(self.arena, "components ({d})", .{component_count}),
            });
            var component_index: usize = 0;
            for (node.children.items) |child_key| {
                if (self.nodes.get(child_key).?.kind != .component) continue;
                component_index += 1;
                try self.emitNode(
                    rows,
                    conflict_rows,
                    child_key,
                    depth + 2,
                    if (component_index == component_count) .elbow else .tee,
                );
            }
        }
        var object_index: usize = 0;
        for (node.children.items) |child_key| {
            if (self.nodes.get(child_key).?.kind != .game_object) continue;
            object_index += 1;
            try self.emitNode(
                rows,
                conflict_rows,
                child_key,
                depth + 1,
                if (object_index == object_count) .elbow else .tee,
            );
        }
    }
};

pub fn build(
    arena: std.mem.Allocator,
    partial: []const u8,
    plan: *const core.merge.MergePlan,
    conflict_indices: []const usize,
) !Model {
    var builder: Builder = .{ .arena = arena };
    try builder.addResult(try core.diffBytes(arena, "", partial));
    try builder.addResult(try core.diffBytes(arena, "", plan.ours.bytes));
    try builder.addResult(try core.diffBytes(arena, "", plan.theirs.bytes));
    try builder.addResult(try core.diffBytes(arena, "", plan.base.bytes));
    try builder.addConflicts(plan, conflict_indices);
    return builder.emit(conflict_indices.len);
}

const base =
    "--- !u!1 &1\n" ++
    "GameObject:\n" ++
    "  m_Name: Player\n" ++
    "  m_Component:\n" ++
    "  - component: {fileID: 4}\n" ++
    "  - component: {fileID: 114}\n" ++
    "--- !u!4 &4\n" ++
    "Transform:\n" ++
    "  m_GameObject: {fileID: 1}\n" ++
    "  m_Father: {fileID: 0}\n" ++
    "  m_Children: []\n" ++
    "--- !u!114 &114\n" ++
    "MonoBehaviour:\n" ++
    "  m_GameObject: {fileID: 1}\n" ++
    "  maxHp: 100\n";

test "merge TUI: tree keeps Unity context and focuses only conflicts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ours_bytes = try std.mem.replaceOwned(u8, arena, base, "maxHp: 100", "maxHp: 150");
    const theirs_bytes = try std.mem.replaceOwned(u8, arena, base, "maxHp: 100", "maxHp: 200");
    var built = try core.merge.build(arena, base, ours_bytes, theirs_bytes);
    const state = try merge_ui_state.State.init(arena, &built.plan);

    // A conflict-only projection would omit the unchanged Transform and its owning GameObject.
    const tree = try build(arena, built.partial, &built.plan, state.conflict_indices);
    try testing.expectEqualStrings("Player", tree.rows[0].label);
    try testing.expectEqual(Kind.game_object, tree.rows[0].kind);
    try testing.expectEqualStrings("components (2)", tree.rows[1].label);
    try testing.expectEqualStrings("Transform", tree.rows[2].label);
    try testing.expectEqual(@as(?usize, null), tree.rows[2].conflict_index);
    try testing.expectEqualStrings("MonoBehaviour", tree.rows[3].label);
    try testing.expectEqualStrings("Max Hp", tree.rows[4].label);
    try testing.expectEqual(@as(?usize, 0), tree.rows[4].conflict_index);
    try testing.expectEqual(@as(?usize, 4), tree.rowForConflict(0));
}

test "merge TUI: tree includes a structural target absent from the partial result" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture_base =
        "--- !u!1 &1\n" ++
        "GameObject:\n" ++
        "  m_Name: Root\n" ++
        "  m_Component:\n" ++
        "  - component: {fileID: 4}\n" ++
        "--- !u!4 &4\n" ++
        "Transform:\n" ++
        "  m_GameObject: {fileID: 1}\n" ++
        "  m_Father: {fileID: 0}\n" ++
        "  m_Children: []\n";
    const fixture_ours = fixture_base;
    const fixture_theirs =
        "--- !u!1 &1\n" ++
        "GameObject:\n" ++
        "  m_Name: Root\n" ++
        "  m_Component:\n" ++
        "  - component: {fileID: 4}\n" ++
        "  - component: {fileID: 54}\n" ++
        "--- !u!4 &4\n" ++
        "Transform:\n" ++
        "  m_GameObject: {fileID: 1}\n" ++
        "  m_Father: {fileID: 0}\n" ++
        "  m_Children: []\n" ++
        "--- !u!54 &54\n" ++
        "Rigidbody:\n" ++
        "  m_GameObject: {fileID: 1}\n" ++
        "  m_Mass: 2\n";
    var built = try core.merge.build(
        arena,
        fixture_base,
        fixture_ours,
        fixture_theirs,
    );
    const operation_index = for (built.plan.operations, 0..) |operation, index| {
        if (operation.kind == .component and operation.identity.document.file_id == 54)
            break index;
    } else return error.TestExpectedEqual;
    const conflict_indices = [_]usize{operation_index};

    // A partial-only projection would omit the Rigidbody because only Theirs contains document 54.
    try testing.expect(std.mem.indexOf(u8, fixture_ours, "Rigidbody") == null);
    const tree = try build(arena, fixture_ours, &built.plan, &conflict_indices);
    const row_index = tree.rowForConflict(0).?;
    try testing.expectEqualStrings("components (2)", tree.rows[1].label);
    try testing.expect(tree.rows[row_index].kind == .component);
    try testing.expectEqualStrings("Rigidbody", tree.rows[row_index].label);
    try testing.expectEqual(@as(u16, 2), tree.rows[row_index].depth);
    try testing.expect(tree.rows[row_index].conflict_index == 0);
}

test "merge TUI: prefab override conflict uses the Inspector property name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture_base = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "core/src/testdata/merge/prefab-property/base.prefab",
        arena,
        .limited(4096),
    );
    const fixture_ours = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "core/src/testdata/merge/prefab-property/ours.prefab",
        arena,
        .limited(4096),
    );
    const fixture_theirs = try std.mem.replaceOwned(
        u8,
        arena,
        fixture_ours,
        "value: Ours",
        "value: Theirs",
    );
    var built = try core.merge.build(
        arena,
        fixture_base,
        fixture_ours,
        fixture_theirs,
    );
    const state = try merge_ui_state.State.init(arena, &built.plan);

    // The containing sequence path would hide the overridden Inspector property name.
    const tree = try build(arena, built.partial, &built.plan, state.conflict_indices);
    const row_index = tree.rowForConflict(0).?;
    try testing.expectEqualStrings("Name", tree.rows[row_index].label);
}
