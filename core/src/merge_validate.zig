const std = @import("std");
const merge = @import("merge.zig");
const merge_model = @import("merge_model.zig");
const merge_test_support = @import("merge_test_support.zig");
const model = @import("model.zig");
const parser = @import("parser.zig");

const merge_validate = @This();
const testing = std.testing;

const Index = struct {
    arena: std.mem.Allocator,
    documents: std.AutoHashMapUnmanaged(i64, *const model.Document),
    all_documents: []const model.Document,

    fn init(
        arena: std.mem.Allocator,
        documents: []const model.Document,
    ) merge_model.Error!Index {
        var by_file_id: std.AutoHashMapUnmanaged(i64, *const model.Document) = .empty;
        for (documents) |*document| try by_file_id.put(arena, document.file_id, document);
        return .{ .arena = arena, .documents = by_file_id, .all_documents = documents };
    }

    fn requireUniqueFileIds(self: *const Index) merge_model.Error!void {
        var identifiers: std.AutoHashMapUnmanaged(i64, void) = .empty;
        for (self.all_documents) |document| {
            const entry = try identifiers.getOrPut(self.arena, document.file_id);
            if (entry.found_existing) return error.InvalidMerge;
        }
    }

    fn requireInternalReferences(self: *const Index) merge_model.Error!void {
        for (self.all_documents) |document| try self.requireNodeReferences(document.body);
    }

    fn requireNodeReferences(
        self: *const Index,
        node: *const model.Node,
    ) merge_model.Error!void {
        switch (node.*) {
            .ref => |reference| {
                if (reference.guid == null and reference.file_id != 0 and
                    !self.documents.contains(reference.file_id)) return error.InvalidMerge;
            },
            .map => |entries| for (entries) |entry| try self.requireNodeReferences(entry.value),
            .seq => |items| for (items) |item| try self.requireNodeReferences(item),
            .scalar => {},
        }
    }

    fn requireComponentOwnership(self: *const Index) merge_model.Error!void {
        var owners: std.AutoHashMapUnmanaged(i64, i64) = .empty;
        for (self.all_documents) |document| {
            if (document.class_id != 1) continue;
            const components = model.findValue(document.body.map, "m_Component") orelse
                return error.InvalidMerge;
            if (components.* != .seq) return error.InvalidMerge;
            var transform_count: usize = 0;
            for (components.seq) |item| {
                if (item.* != .map) return error.InvalidMerge;
                const component_node = model.findValue(item.map, "component") orelse
                    return error.InvalidMerge;
                if (component_node.* != .ref or component_node.ref.guid != null or
                    component_node.ref.file_id == 0) return error.InvalidMerge;
                const component = self.documents.get(component_node.ref.file_id) orelse
                    return error.InvalidMerge;
                if (component.class_id == 4 or component.class_id == 224) transform_count += 1;
                const owner = try owners.getOrPut(self.arena, component.file_id);
                if (owner.found_existing) return error.InvalidMerge;
                owner.value_ptr.* = document.file_id;
                const back_reference = model.findValue(component.body.map, "m_GameObject") orelse
                    return error.InvalidMerge;
                if (back_reference.* != .ref or back_reference.ref.guid != null or
                    back_reference.ref.file_id != document.file_id) return error.InvalidMerge;
            }
            if (transform_count != 1) return error.InvalidMerge;
        }
        for (self.all_documents) |document| {
            const game_object = model.findValue(document.body.map, "m_GameObject") orelse {
                if (document.class_id == 4 or document.class_id == 224) return error.InvalidMerge;
                continue;
            };
            if (game_object.* != .ref or game_object.ref.guid != null or
                game_object.ref.file_id == 0) return error.InvalidMerge;
            const owner = owners.get(document.file_id) orelse return error.InvalidMerge;
            if (owner != game_object.ref.file_id) return error.InvalidMerge;
        }
    }

    fn requireBidirectionalHierarchy(self: *const Index) merge_model.Error!void {
        var parents: std.AutoHashMapUnmanaged(i64, i64) = .empty;
        for (self.all_documents) |document| {
            if (document.class_id != 4 and document.class_id != 224) continue;
            const children = model.findValue(document.body.map, "m_Children") orelse
                return error.InvalidMerge;
            if (children.* != .seq) return error.InvalidMerge;
            for (children.seq) |item| {
                if (item.* != .ref or item.ref.guid != null or item.ref.file_id == 0)
                    return error.InvalidMerge;
                const child = self.documents.get(item.ref.file_id) orelse return error.InvalidMerge;
                if (child.class_id != 4 and child.class_id != 224) return error.InvalidMerge;
                const parent = try parents.getOrPut(self.arena, child.file_id);
                if (parent.found_existing) return error.InvalidMerge;
                parent.value_ptr.* = document.file_id;
            }
        }
        for (self.all_documents) |document| {
            if (document.class_id != 4 and document.class_id != 224) continue;
            const father = model.findValue(document.body.map, "m_Father") orelse
                return error.InvalidMerge;
            if (father.* != .ref or father.ref.guid != null) return error.InvalidMerge;
            if (father.ref.file_id == 0) {
                if (parents.contains(document.file_id)) return error.InvalidMerge;
                continue;
            }
            const parent = self.documents.get(father.ref.file_id) orelse return error.InvalidMerge;
            if (parent.class_id != 4 and parent.class_id != 224) return error.InvalidMerge;
            if (parents.get(document.file_id) != father.ref.file_id) return error.InvalidMerge;
        }
    }

    fn requireAcyclicHierarchy(self: *const Index) merge_model.Error!void {
        var complete: std.AutoHashMapUnmanaged(i64, void) = .empty;
        var iterator = self.documents.iterator();
        while (iterator.next()) |entry| {
            const document = entry.value_ptr.*;
            if (document.class_id != 4 and document.class_id != 224) continue;
            if (complete.contains(document.file_id)) continue;
            var path: std.AutoHashMapUnmanaged(i64, void) = .empty;
            var current: ?*const model.Document = document;
            while (current) |transform| {
                if (complete.contains(transform.file_id)) break;
                const visited = try path.getOrPut(self.arena, transform.file_id);
                if (visited.found_existing) return error.InvalidMerge;
                const father = model.findValue(transform.body.map, "m_Father") orelse break;
                if (father.* != .ref or father.ref.guid != null) return error.InvalidMerge;
                if (father.ref.file_id == 0) break;
                const parent = self.documents.get(father.ref.file_id) orelse break;
                if (parent.class_id != 4 and parent.class_id != 224) break;
                current = parent;
            }
            var path_iterator = path.iterator();
            while (path_iterator.next()) |path_entry| try complete.put(self.arena, path_entry.key_ptr.*, {});
        }
    }
};

pub fn validate(arena: std.mem.Allocator, bytes: []const u8) merge_model.Error!void {
    const parsed = try parser.parseSpanned(arena, bytes);
    if (parsed.diagnostics.len != 0) return error.InvalidMerge;
    var index = try Index.init(arena, parsed.documents);
    try index.requireUniqueFileIds();
    try index.requireComponentOwnership();
    try index.requireBidirectionalHierarchy();
    try index.requireAcyclicHierarchy();
    try index.requireInternalReferences();
}

test "merge planner: applies a complete GameObject subtree or none of it" {
    const fixture = merge_test_support.load("game-object-add", false);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var built = try merge.build(arena, fixture.base, fixture.ours, fixture.theirs);
    const atomic = merge_test_support.findAtomicByKind(&built.plan, .game_object).?;
    try testing.expect(atomic.operation_ids.len >= 6);
    try merge_validate.validate(arena, built.partial);
}

test "merge planner: groups both parent lists with the child father" {
    const fixture = merge_test_support.load("reparent-one-side", false);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var built = try merge.build(arena_state.allocator(), fixture.base, fixture.ours, fixture.theirs);
    const atomic = merge_test_support.findAtomicByKind(&built.plan, .reparent).?;
    try testing.expectEqual(@as(usize, 3), atomic.operation_ids.len);
    try testing.expectEqualStrings(fixture.expected, built.partial);
}

test "merge planner: combines matching reparent changes" {
    const fixture = merge_test_support.load("reparent-same-parent", false);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var built = try merge.build(arena, fixture.base, fixture.ours, fixture.theirs);

    try testing.expectEqualStrings(fixture.expected, built.partial);
    try testing.expectEqualStrings(fixture.expected, try merge.finish(arena, &built.plan));
}

test "merge planner: holds the Ours hierarchy during a reparent conflict" {
    const fixture = merge_test_support.load("reparent-conflict", true);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const built = try merge.build(
        arena_state.allocator(),
        fixture.base,
        fixture.ours,
        fixture.theirs,
    );

    try testing.expectEqualStrings(fixture.partial.?, built.partial);
}

test "merge planner: resolves a reparent conflict with the selected hierarchy" {
    const fixture = merge_test_support.load("reparent-conflict", true);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var built = try merge.build(arena, fixture.base, fixture.ours, fixture.theirs);
    const operation = merge_test_support.findOperationByKind(&built.plan, .reparent).?;

    try merge.resolve(arena, &built.plan, operation.id, .{ .take = .ours });

    try testing.expectEqualStrings(fixture.expected, try merge.finish(arena, &built.plan));
}

test "merge planner: applies the Theirs hierarchy after a reparent conflict" {
    const fixture = merge_test_support.load("reparent-conflict", true);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var built = try merge.build(arena, fixture.base, fixture.ours, fixture.theirs);
    const operation = merge_test_support.findOperationByKind(&built.plan, .reparent).?;

    try merge.resolve(arena, &built.plan, operation.id, .{ .take = .theirs });

    try testing.expectEqualStrings(fixture.theirs, try merge.finish(arena, &built.plan));
}

test "merge planner: moves a Transform between a parent and the root" {
    const fixture = merge_test_support.load("reparent-one-side", false);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const without_parent_child = try std.mem.replaceOwned(
        u8,
        arena,
        fixture.base,
        "  m_Children:\n  - {fileID: 42}\n  m_Father: {fileID: 4}",
        "  m_Children: []\n  m_Father: {fileID: 4}",
    );
    const root = try std.mem.replaceOwned(
        u8,
        arena,
        without_parent_child,
        "  m_Father: {fileID: 40}",
        "  m_Father: {fileID: 0}",
    );

    var to_root = try merge.build(arena, fixture.base, fixture.base, root);
    var from_root = try merge.build(arena, root, root, fixture.base);

    try testing.expectEqualStrings(root, try merge.finish(arena, &to_root.plan));
    try testing.expectEqualStrings(fixture.base, try merge.finish(arena, &from_root.plan));
}

test "merge validation: rejects a hierarchy cycle" {
    const fixture = merge_test_support.load("reparent-cycle", true);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var built = try merge.build(arena, fixture.base, fixture.ours, fixture.theirs);
    const operation = merge_test_support.findOperationByKind(&built.plan, .reparent).?;
    try testing.expectError(
        error.InvalidResolution,
        merge.resolve(arena, &built.plan, operation.id, .{ .take = .theirs }),
    );
    const atomic = merge_test_support.findAtomicByKind(&built.plan, .reparent).?;
    for (atomic.operation_ids) |operation_id| {
        const member = merge_model.operationByIdConst(&built.plan, operation_id).?;
        try testing.expect(member.resolution == .unresolved);
    }
    try testing.expectEqualStrings(fixture.partial.?, try @import("merge_apply.zig").applyResolved(
        arena,
        &built.plan,
        false,
    ));
}

test "merge validation: rejects duplicate file identifiers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    try testing.expectError(
        error.InvalidMerge,
        validate(
            arena_state.allocator(),
            "--- !u!1 &7\nGameObject:\n  m_Name: First\n" ++
                "--- !u!4 &7\nTransform:\n  m_Father: {fileID: 0}\n",
        ),
    );
}

test "merge validation: rejects a dangling internal reference" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    try testing.expectError(
        error.InvalidMerge,
        validate(
            arena_state.allocator(),
            "--- !u!114 &7\nMonoBehaviour:\n  m_Target: {fileID: 99}\n",
        ),
    );
}

test "merge validation: rejects mismatched component ownership" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const bytes =
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n" ++
        "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 2}\n  m_Children: []\n  m_Father: {fileID: 0}\n" ++
        "--- !u!1 &2\nGameObject:\n  m_Component:\n  - component: {fileID: 40}\n" ++
        "--- !u!4 &40\nTransform:\n  m_GameObject: {fileID: 2}\n  m_Children: []\n  m_Father: {fileID: 0}\n";

    try testing.expectError(error.InvalidMerge, validate(arena_state.allocator(), bytes));
}

test "merge validation: rejects two Transforms in one Component list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const bytes =
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n  - component: {fileID: 40}\n" ++
        "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children: []\n  m_Father: {fileID: 0}\n" ++
        "--- !u!4 &40\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children: []\n  m_Father: {fileID: 0}\n";

    try testing.expectError(error.InvalidMerge, validate(arena_state.allocator(), bytes));
}

test "merge validation: rejects a GameObject without one Transform" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const bytes =
        "--- !u!1 &1\nGameObject:\n  m_Component: []\n";

    try testing.expectError(error.InvalidMerge, validate(arena_state.allocator(), bytes));
}

test "merge validation: rejects a GameObject without a Component list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const bytes =
        "--- !u!1 &1\nGameObject:\n  m_Name: Root\n";

    try testing.expectError(error.InvalidMerge, validate(arena_state.allocator(), bytes));
}

test "merge validation: rejects a Transform without a GameObject owner" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const bytes =
        "--- !u!4 &4\nTransform:\n  m_Children: []\n  m_Father: {fileID: 0}\n";

    try testing.expectError(error.InvalidMerge, validate(arena_state.allocator(), bytes));
}

test "merge validation: rejects a listed child without a father" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const bytes =
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n" ++
        "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children:\n  - {fileID: 42}\n  m_Father: {fileID: 0}\n" ++
        "--- !u!1 &20\nGameObject:\n  m_Component:\n  - component: {fileID: 42}\n" ++
        "--- !u!4 &42\nTransform:\n  m_GameObject: {fileID: 20}\n  m_Children: []\n";

    try testing.expectError(error.InvalidMerge, validate(arena_state.allocator(), bytes));
}

test "merge validation: rejects a Transform without a Children list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const bytes =
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n" ++
        "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Father: {fileID: 0}\n";

    try testing.expectError(error.InvalidMerge, validate(arena_state.allocator(), bytes));
}

test "merge validation: rejects duplicate parent membership" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const bytes =
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n" ++
        "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children:\n  - {fileID: 42}\n  m_Father: {fileID: 0}\n" ++
        "--- !u!1 &10\nGameObject:\n  m_Component:\n  - component: {fileID: 40}\n" ++
        "--- !u!4 &40\nTransform:\n  m_GameObject: {fileID: 10}\n  m_Children:\n  - {fileID: 42}\n  m_Father: {fileID: 0}\n" ++
        "--- !u!1 &20\nGameObject:\n  m_Component:\n  - component: {fileID: 42}\n" ++
        "--- !u!4 &42\nTransform:\n  m_GameObject: {fileID: 20}\n  m_Children: []\n  m_Father: {fileID: 4}\n";

    try testing.expectError(error.InvalidMerge, validate(arena_state.allocator(), bytes));
}

test "merge validation: rejects mismatched parent references" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const bytes =
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n" ++
        "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children:\n  - {fileID: 42}\n  m_Father: {fileID: 0}\n" ++
        "--- !u!1 &20\nGameObject:\n  m_Component:\n  - component: {fileID: 42}\n" ++
        "--- !u!4 &42\nTransform:\n  m_GameObject: {fileID: 20}\n  m_Children: []\n  m_Father: {fileID: 0}\n";

    try testing.expectError(error.InvalidMerge, validate(arena_state.allocator(), bytes));
}

test "merge validation: accepts external and built-in references" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const bytes =
        "--- !u!114 &7\nMonoBehaviour:\n" ++
        "  m_External: {fileID: 99, guid: abcdef, type: 3}\n" ++
        "  m_BuiltIn: {fileID: 10001, guid: 0000000000000000f000000000000000, type: 0}\n";

    try validate(arena_state.allocator(), bytes);
}

test "merge validation: accepts every valid hierarchy fixture" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const game_object_add = merge_test_support.load("game-object-add", false);
    const game_object_delete = merge_test_support.load("game-object-delete", false);
    const game_object_delete_edit = merge_test_support.load("game-object-delete-edit", true);
    const reparent_one_side = merge_test_support.load("reparent-one-side", false);
    const reparent_same_parent = merge_test_support.load("reparent-same-parent", false);
    const reparent_conflict = merge_test_support.load("reparent-conflict", true);
    const reparent_cycle = merge_test_support.load("reparent-cycle", true);

    inline for (.{
        game_object_add.expected,
        game_object_delete.expected,
        game_object_delete_edit.expected,
        game_object_delete_edit.partial.?,
        reparent_one_side.expected,
        reparent_same_parent.expected,
        reparent_conflict.expected,
        reparent_conflict.partial.?,
        reparent_cycle.expected,
        reparent_cycle.partial.?,
    }) |bytes| try validate(arena, bytes);
}

test "merge planner: holds a complete GameObject during a delete and edit conflict" {
    const fixture = merge_test_support.load("game-object-delete-edit", true);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const built = try merge.build(
        arena_state.allocator(),
        fixture.base,
        fixture.ours,
        fixture.theirs,
    );

    try testing.expectEqualStrings(fixture.partial.?, built.partial);
}

test "merge planner: keeps Base when subtree deletion conflicts with descendant reparent" {
    const fixture = merge_test_support.load("game-object-delete-reparent", true);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const built = try merge.build(
        arena_state.allocator(),
        fixture.base,
        fixture.ours,
        fixture.theirs,
    );

    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
    try testing.expectEqualStrings(fixture.partial.?, built.partial);
}

test "merge planner: resolves subtree deletion and descendant reparent coherently" {
    const fixture = merge_test_support.load("game-object-delete-reparent", true);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var deletion = try merge.build(arena, fixture.base, fixture.ours, fixture.theirs);
    const delete_operation = merge_test_support.findOperationByKind(&deletion.plan, .game_object).?;
    try merge.resolve(arena, &deletion.plan, delete_operation.id, .remove);
    try testing.expectEqualStrings(fixture.expected, try merge.finish(arena, &deletion.plan));

    var reparent = try merge.build(arena, fixture.base, fixture.ours, fixture.theirs);
    const reparent_operation = merge_test_support.findOperationByKind(&reparent.plan, .game_object).?;
    try merge.resolve(arena, &reparent.plan, reparent_operation.id, .{ .take = .theirs });
    try testing.expectEqualStrings(fixture.theirs, try merge.finish(arena, &reparent.plan));
}

test "merge planner: applies a complete GameObject addition" {
    const fixture = merge_test_support.load("game-object-add", false);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var built = try merge.build(arena, fixture.base, fixture.ours, fixture.theirs);

    try testing.expectEqualStrings(fixture.expected, built.partial);
    try testing.expectEqualStrings(fixture.expected, try merge.finish(arena, &built.plan));
}

test "merge planner: applies a complete GameObject deletion" {
    const fixture = merge_test_support.load("game-object-delete", false);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var built = try merge.build(arena, fixture.base, fixture.ours, fixture.theirs);

    try testing.expectEqualStrings(fixture.expected, built.partial);
    try testing.expectEqualStrings(fixture.expected, try merge.finish(arena, &built.plan));
}

test "merge planner: resolves a GameObject delete and edit conflict" {
    const fixture = merge_test_support.load("game-object-delete-edit", true);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var built = try merge.build(arena, fixture.base, fixture.ours, fixture.theirs);
    const operation = merge_test_support.findOperationByKind(&built.plan, .game_object).?;

    try merge.resolve(arena, &built.plan, operation.id, .{ .take = .theirs });

    try testing.expectEqualStrings(fixture.expected, try merge.finish(arena, &built.plan));
}

test "merge planner: groups a nested GameObject subtree" {
    const base =
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n" ++
        "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children: []\n  m_Father: {fileID: 0}\n";
    const theirs =
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n" ++
        "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children:\n  - {fileID: 42}\n  m_Father: {fileID: 0}\n" ++
        "--- !u!1 &20\nGameObject:\n  m_Component:\n  - component: {fileID: 42}\n" ++
        "--- !u!4 &42\nTransform:\n  m_GameObject: {fileID: 20}\n  m_Children:\n  - {fileID: 43}\n  m_Father: {fileID: 4}\n" ++
        "--- !u!1 &30\nGameObject:\n  m_Component:\n  - component: {fileID: 43}\n" ++
        "--- !u!4 &43\nTransform:\n  m_GameObject: {fileID: 30}\n  m_Children: []\n  m_Father: {fileID: 42}\n";
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const built = try merge.build(arena_state.allocator(), base, base, theirs);
    var count: usize = 0;
    for (built.plan.atomic_operations) |atomic| if (atomic.kind == .game_object) {
        count += 1;
    };

    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqualStrings(theirs, built.partial);
}

test "merge planner: holds a GameObject addition with a duplicate file identifier" {
    const base =
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n" ++
        "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children: []\n  m_Father: {fileID: 0}\n" ++
        "--- !u!114 &20\nMonoBehaviour:\n  m_Value: 1\n";
    const theirs =
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n" ++
        "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children:\n  - {fileID: 42}\n  m_Father: {fileID: 0}\n" ++
        "--- !u!114 &20\nMonoBehaviour:\n  m_Value: 1\n" ++
        "--- !u!1 &20\nGameObject:\n  m_Component:\n  - component: {fileID: 42}\n" ++
        "--- !u!4 &42\nTransform:\n  m_GameObject: {fileID: 20}\n  m_Children: []\n  m_Father: {fileID: 4}\n";
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const built = try merge.build(arena_state.allocator(), base, base, theirs);

    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
    try testing.expectEqualStrings(base, built.partial);
}
