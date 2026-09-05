const std = @import("std");
const core = @import("core");

const testing = std.testing;

pub const Pane = enum { hierarchy, inspector };
pub const Outcome = enum { active, ready, aborted };

pub const Action = union(enum) {
    pane_left,
    pane_right,
    move_up,
    move_down,
    select_conflict: usize,
    choose_ours,
    choose_theirs,
    edit_result: []const u8,
    apply_result,
    reopen_result,
    abort,
};

const DependencyState = enum { ready, unresolved, invalid };

pub const State = struct {
    allocator: std.mem.Allocator,
    plan: *core.merge.MergePlan,
    initial_resolutions: []core.merge.Resolution,
    conflict_indices: []usize,
    pane: Pane = .hierarchy,
    selected_conflict: usize = 0,
    pending: ?core.merge.Resolution = null,
    status: []const u8 = "",
    outcome: Outcome = .active,

    pub fn init(
        allocator: std.mem.Allocator,
        plan: *core.merge.MergePlan,
    ) !State {
        const initial = try allocator.alloc(core.merge.Resolution, plan.operations.len);
        const conflicts = try allocator.alloc(usize, plan.unresolvedCount());
        for (plan.operations, initial) |operation_item, *resolution| {
            resolution.* = operation_item.resolution;
        }
        var conflict_index: usize = 0;
        for (plan.atomic_operations) |atomic| {
            for (atomic.operation_ids) |id| {
                for (plan.operations, 0..) |operation_item, operation_index| {
                    if (operation_item.id == id and operation_item.resolution == .unresolved) {
                        conflicts[conflict_index] = operation_index;
                        conflict_index += 1;
                        break;
                    }
                } else continue;
                break;
            }
        }
        return .{
            .allocator = allocator,
            .plan = plan,
            .initial_resolutions = initial,
            .conflict_indices = conflicts,
            .outcome = if (conflicts.len == 0) .ready else .active,
        };
    }

    fn operation(self: *State) ?*core.merge.Operation {
        if (self.conflict_indices.len == 0 or self.selected_conflict >= self.conflict_indices.len)
            return null;
        return &self.plan.operations[self.conflict_indices[self.selected_conflict]];
    }

    fn selectConflict(self: *State, index: usize) void {
        if (index >= self.conflict_indices.len) return;
        self.selected_conflict = index;
        const resolution = self.operation().?.resolution;
        self.pending = if (resolution == .unresolved) null else resolution;
    }

    fn advance(self: *State) void {
        if (self.conflict_indices.len == 0) {
            self.outcome = .ready;
            self.pending = null;
            return;
        }
        for (1..self.conflict_indices.len + 1) |offset| {
            const index = (self.selected_conflict + offset) % self.conflict_indices.len;
            if (self.plan.operations[self.conflict_indices[index]].resolution == .unresolved) {
                self.selectConflict(index);
                return;
            }
        }
        self.outcome = .ready;
        self.pending = null;
    }

    fn atomicIndexById(self: *const State, atomic_id: u32) ?usize {
        for (self.plan.atomic_operations, 0..) |atomic, index| {
            if (atomic.id == atomic_id) return index;
        }
        return null;
    }

    fn operationById(self: *State, operation_id: core.merge.OperationId) ?*core.merge.Operation {
        for (self.plan.operations) |*operation_item| {
            if (operation_item.id == operation_id) return operation_item;
        }
        return null;
    }

    fn dependencyState(
        self: *State,
        atomic_id: u32,
        path: *std.ArrayList(u32),
    ) !DependencyState {
        for (path.items) |ancestor_id| {
            if (ancestor_id == atomic_id) return .invalid;
        }
        const atomic_index = self.atomicIndexById(atomic_id) orelse return .invalid;
        const atomic = &self.plan.atomic_operations[atomic_index];
        try path.append(self.allocator, atomic_id);
        defer _ = path.pop();

        var state: DependencyState = .ready;
        for (atomic.dependencies) |dependency_id| {
            switch (try self.dependencyState(dependency_id, path)) {
                .ready => {},
                .unresolved => state = .unresolved,
                .invalid => return .invalid,
            }
        }
        if (atomic.operation_ids.len == 0) return .invalid;
        for (atomic.operation_ids) |operation_id| {
            const member = self.operationById(operation_id) orelse return .invalid;
            if (member.atomic_id != atomic.id) return .invalid;
            if (member.resolution == .unresolved) state = .unresolved;
            for (member.dependencies) |dependency_id| {
                switch (try self.dependencyState(dependency_id, path)) {
                    .ready => {},
                    .unresolved => state = .unresolved,
                    .invalid => return .invalid,
                }
            }
        }
        return state;
    }

    fn selectedDependencies(self: *State, operation_item: *const core.merge.Operation) !DependencyState {
        const atomic_index = self.atomicIndexById(operation_item.atomic_id) orelse return .invalid;
        const atomic = &self.plan.atomic_operations[atomic_index];
        var path: std.ArrayList(u32) = .empty;
        try path.append(self.allocator, atomic.id);
        defer _ = path.pop();

        var state: DependencyState = .ready;
        for (atomic.dependencies) |dependency_id| {
            switch (try self.dependencyState(dependency_id, &path)) {
                .ready => {},
                .unresolved => state = .unresolved,
                .invalid => return .invalid,
            }
        }
        for (atomic.operation_ids) |operation_id| {
            const member = self.operationById(operation_id) orelse return .invalid;
            if (member.atomic_id != atomic.id) return .invalid;
            for (member.dependencies) |dependency_id| {
                switch (try self.dependencyState(dependency_id, &path)) {
                    .ready => {},
                    .unresolved => state = .unresolved,
                    .invalid => return .invalid,
                }
            }
        }
        return state;
    }

    pub fn unresolvedCount(self: State) usize {
        return self.plan.unresolvedCount();
    }

    pub fn handle(self: *State, action: Action) !void {
        if (action == .abort) {
            for (self.plan.operations, self.initial_resolutions) |*operation_item, initial| {
                operation_item.resolution = initial;
            }
            self.pending = null;
            self.status = "";
            self.outcome = .aborted;
            return;
        }
        if (self.outcome == .aborted) return;

        switch (action) {
            .pane_left => self.pane = .hierarchy,
            .pane_right => self.pane = .inspector,
            .move_up => self.selectConflict(self.selected_conflict -| 1),
            .move_down => if (self.selected_conflict + 1 < self.conflict_indices.len) {
                self.selectConflict(self.selected_conflict + 1);
            },
            .select_conflict => |index| self.selectConflict(index),
            .choose_ours => if (self.operation()) |operation_item| {
                self.pending = resolutionForSide(operation_item, .ours);
            },
            .choose_theirs => if (self.operation()) |operation_item| {
                self.pending = resolutionForSide(operation_item, .theirs);
            },
            .edit_result => |value| if (self.operation() != null) {
                self.pending = .{ .custom = try self.allocator.dupe(u8, value) };
            },
            .apply_result => {
                const operation_item = self.operation() orelse return;
                const pending = self.pending orelse {
                    self.status = "Select a result first.";
                    return;
                };
                switch (try self.selectedDependencies(operation_item)) {
                    .ready => {},
                    .unresolved => {
                        self.status = "Resolve dependent conflicts first.";
                        return;
                    },
                    .invalid => {
                        self.status = "The result is not valid Unity YAML.";
                        return;
                    },
                }
                core.merge.resolve(
                    self.allocator,
                    self.plan,
                    operation_item.id,
                    pending,
                ) catch |err| switch (err) {
                    error.InvalidResolution, error.InvalidMerge => {
                        self.status = "The result is not valid Unity YAML.";
                        return;
                    },
                    else => return err,
                };
                self.status = "";
                self.advance();
            },
            .reopen_result => if (self.operation()) |operation_item| {
                const atomic_index = self.atomicIndexById(operation_item.atomic_id) orelse return;
                for (self.plan.atomic_operations[atomic_index].operation_ids) |operation_id| {
                    const member = self.operationById(operation_id) orelse continue;
                    member.resolution = .unresolved;
                }
                self.pending = null;
                self.status = "";
                self.outcome = .active;
            },
            .abort => unreachable,
        }
    }
};

fn resolutionForSide(
    operation: *const core.merge.Operation,
    side: core.merge.Side,
) core.merge.Resolution {
    const value = switch (side) {
        .base => operation.values.base,
        .ours => operation.values.ours,
        .theirs => operation.values.theirs,
    };
    return if (value == null) .remove else .{ .take = side };
}

fn conflictPlan(arena: std.mem.Allocator, count: u8) !core.merge.BuildResult {
    const base = "--- !u!54 &54\nRigidbody:\n  m_Mass: 5\n  m_Drag: 0\n";
    const ours = if (count == 1)
        "--- !u!54 &54\nRigidbody:\n  m_Mass: 12\n  m_Drag: 0\n"
    else
        "--- !u!54 &54\nRigidbody:\n  m_Mass: 12\n  m_Drag: 2\n";
    const theirs = if (count == 1)
        "--- !u!54 &54\nRigidbody:\n  m_Mass: 8\n  m_Drag: 0\n"
    else
        "--- !u!54 &54\nRigidbody:\n  m_Mass: 8\n  m_Drag: 3\n";
    return core.merge.build(arena, base, ours, theirs);
}

fn groupConflicts(arena: std.mem.Allocator, plan: *core.merge.MergePlan) !void {
    const first_atomic_id = plan.operations[0].atomic_id;
    plan.operations[1].atomic_id = first_atomic_id;
    plan.atomic_operations[0].operation_ids = try arena.dupe(
        core.merge.OperationId,
        &.{ plan.operations[0].id, plan.operations[1].id },
    );
    plan.atomic_operations = plan.atomic_operations[0..1];
}

test "merge UI state: choose and apply advances to the next conflict" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try conflictPlan(arena, 2);
    var state = try State.init(arena, &fixture.plan);

    try state.handle(.choose_ours);
    try testing.expectEqual(@as(usize, 2), state.unresolvedCount());
    try state.handle(.apply_result);

    try testing.expectEqual(@as(usize, 1), state.unresolvedCount());
    try testing.expectEqual(@as(usize, 1), state.selected_conflict);
}

test "merge UI state: a missing side removes the container in both directions" {
    const base =
        "--- !u!114 &1\nMonoBehaviour:\n  m_Config:\n    value: 1\n  m_After: keep\n";
    const deleted =
        "--- !u!114 &1\nMonoBehaviour:\n  m_After: keep\n";
    const edited =
        "--- !u!114 &1\nMonoBehaviour:\n  m_Config:\n    value: 2\n  m_After: keep\n";

    inline for (.{
        .{ .ours = deleted, .theirs = edited, .action = Action.choose_ours },
        .{ .ours = edited, .theirs = deleted, .action = Action.choose_theirs },
    }) |case| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var fixture = try core.merge.build(arena, base, case.ours, case.theirs);
        var state = try State.init(arena, &fixture.plan);

        try state.handle(case.action);
        try testing.expect(state.pending.? == .remove);
        try state.handle(.apply_result);

        try testing.expectEqual(Outcome.ready, state.outcome);
        try testing.expectEqualStrings(deleted, try core.merge.finish(arena, &fixture.plan));
    }
}

test "merge UI state: invalid custom input remains unresolved" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try conflictPlan(arena, 1);
    var state = try State.init(arena, &fixture.plan);

    try state.handle(.{ .edit_result = "{bad" });
    try state.handle(.apply_result);

    try testing.expectEqual(@as(usize, 1), state.unresolvedCount());
    try testing.expectEqualStrings("The result is not valid Unity YAML.", state.status);
}

test "merge UI state: ambiguous plain Result never reaches finish" {
    const invalid_values = [_][]const u8{
        "value # comment",
        "key: value",
        "# comment",
        " leading",
    };
    for (invalid_values) |invalid| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var fixture = try conflictPlan(arena, 1);
        var state = try State.init(arena, &fixture.plan);

        try state.handle(.{ .edit_result = invalid });
        try state.handle(.apply_result);

        try testing.expectEqual(@as(usize, 1), state.unresolvedCount());
        try testing.expectEqualStrings("The result is not valid Unity YAML.", state.status);
        try testing.expectError(error.InvalidResolution, core.merge.finish(arena, &fixture.plan));
    }
}

test "merge UI state: invalid references remain unresolved" {
    const invalid_values = [_][]const u8{
        "{fileID: 0, bogus: value}",
        "{fileID: 0, guid: bad, type: 3}",
        "{fileID: 0, guid: 0123456789abcdef0123456789abcdef}",
        "{fileID: 0, type: nope}",
        "{guid: 0123456789abcdef0123456789abcdef, type: 3}",
        "{fileID: 0, guid: 0123456789abcdef0123456789abcdef, type: nope}",
        "{fileID: nope}",
        "{fileID: 0, fileID: 1}",
    };
    for (invalid_values) |invalid| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var fixture = try conflictPlan(arena, 1);
        var state = try State.init(arena, &fixture.plan);

        try testing.expectError(
            error.InvalidResolution,
            core.merge.resolve(
                arena,
                &fixture.plan,
                fixture.plan.operations[0].id,
                .{ .custom = invalid },
            ),
        );
        try testing.expect(fixture.plan.operations[0].resolution == .unresolved);
        try state.handle(.{ .edit_result = invalid });
        try state.handle(.apply_result);

        try testing.expect(fixture.plan.operations[0].resolution == .unresolved);
        try testing.expectEqual(@as(usize, 1), state.unresolvedCount());
        try testing.expectEqualStrings("The result is not valid Unity YAML.", state.status);
        try testing.expectError(error.InvalidResolution, core.merge.finish(arena, &fixture.plan));
    }
}

test "merge UI state: valid references reach finish" {
    const cases = [_]struct { value: []const u8, expected: []const u8 }{
        .{
            .value = "{fileID: 0}",
            .expected = "--- !u!54 &54\nRigidbody:\n  m_Mass: {fileID: 0}\n  m_Drag: 0\n",
        },
        .{
            .value = "{fileID: 2100000, guid: 0123456789abcdef0123456789abcdef, type: 3}",
            .expected = "--- !u!54 &54\nRigidbody:\n  m_Mass: {fileID: 2100000, guid: 0123456789abcdef0123456789abcdef, type: 3}\n  m_Drag: 0\n",
        },
    };
    for (cases) |case| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var fixture = try conflictPlan(arena, 1);
        var state = try State.init(arena, &fixture.plan);

        try state.handle(.{ .edit_result = case.value });
        try state.handle(.apply_result);

        try testing.expectEqual(Outcome.ready, state.outcome);
        try testing.expectEqualStrings(case.expected, try core.merge.finish(arena, &fixture.plan));
    }
}

test "merge UI state: abort discards all in-memory choices" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try conflictPlan(arena, 1);
    var state = try State.init(arena, &fixture.plan);

    try state.handle(.choose_theirs);
    try state.handle(.apply_result);
    try state.handle(.abort);

    try testing.expectEqual(Outcome.aborted, state.outcome);
    try testing.expect(fixture.plan.operations[0].resolution == .unresolved);
}

test "merge UI state: choices stay pending until apply" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try conflictPlan(arena, 2);
    var state = try State.init(arena, &fixture.plan);

    try state.handle(.pane_right);
    try state.handle(.move_down);
    try state.handle(.choose_theirs);

    try testing.expectEqual(Pane.inspector, state.pane);
    try testing.expectEqual(@as(usize, 1), state.selected_conflict);
    try testing.expect(fixture.plan.operations[1].resolution == .unresolved);
    try testing.expect(state.pending.? == .take and state.pending.?.take == .theirs);

    try state.handle(.move_up);
    try testing.expectEqual(@as(usize, 0), state.selected_conflict);
    try testing.expectEqual(@as(?core.merge.Resolution, null), state.pending);
    try state.handle(.move_up);
    try state.handle(.{ .select_conflict = 99 });
    try testing.expectEqual(@as(usize, 0), state.selected_conflict);
}

test "merge UI state: one conflict represents an atomic operation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try conflictPlan(arena, 2);
    try groupConflicts(arena, &fixture.plan);
    var state = try State.init(arena, &fixture.plan);

    try testing.expectEqual(@as(usize, 1), state.conflict_indices.len);
    try state.handle(.choose_ours);
    try testing.expect(fixture.plan.operations[0].resolution == .unresolved);
    try testing.expect(fixture.plan.operations[1].resolution == .unresolved);

    try state.handle(.apply_result);

    try testing.expectEqual(Outcome.ready, state.outcome);
    for (fixture.plan.operations) |operation_item| {
        try testing.expect(operation_item.resolution == .take);
        try testing.expect(operation_item.resolution.take == .ours);
    }
}

test "merge UI state: reopening a conflict resets every atomic member" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try conflictPlan(arena, 2);
    try groupConflicts(arena, &fixture.plan);
    var state = try State.init(arena, &fixture.plan);

    try state.handle(.choose_ours);
    try state.handle(.apply_result);
    try state.handle(.reopen_result);

    // An atomic conflict cannot contain both resolved and unresolved members.
    for (fixture.plan.operations) |operation_item| {
        try testing.expect(operation_item.resolution == .unresolved);
    }
    try testing.expectEqual(Outcome.active, state.outcome);
    try testing.expectEqual(@as(?core.merge.Resolution, null), state.pending);
}

test "merge UI state: a ready conflict can be revised" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try conflictPlan(arena, 1);
    var state = try State.init(arena, &fixture.plan);

    try state.handle(.choose_ours);
    try state.handle(.apply_result);
    try testing.expectEqual(Outcome.ready, state.outcome);

    try state.handle(.{ .select_conflict = 0 });
    try state.handle(.choose_theirs);
    try state.handle(.apply_result);

    try testing.expectEqual(Outcome.ready, state.outcome);
    try testing.expect(fixture.plan.operations[0].resolution.take == .theirs);
}

test "merge UI state: unresolved dependency prevents apply" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try conflictPlan(arena, 2);
    fixture.plan.atomic_operations[0].dependencies = try arena.dupe(
        @TypeOf(fixture.plan.atomic_operations[0].id),
        &.{fixture.plan.atomic_operations[1].id},
    );
    var state = try State.init(arena, &fixture.plan);

    try state.handle(.choose_ours);
    try state.handle(.apply_result);

    try testing.expect(fixture.plan.operations[0].resolution == .unresolved);
    try testing.expectEqual(@as(usize, 2), state.unresolvedCount());
    try testing.expectEqualStrings("Resolve dependent conflicts first.", state.status);
}

test "merge UI state: invalid merge keeps the atomic conflict unresolved" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try conflictPlan(arena, 2);
    try groupConflicts(arena, &fixture.plan);
    fixture.plan.operations[1].values.ours.?.span = fixture.plan.operations[0].values.ours.?.span;
    var state = try State.init(arena, &fixture.plan);

    try state.handle(.choose_theirs);
    try state.handle(.apply_result);

    try testing.expectEqual(@as(usize, 1), state.unresolvedCount());
    for (fixture.plan.operations) |operation_item| {
        try testing.expect(operation_item.resolution == .unresolved);
    }
    try testing.expectEqualStrings("The result is not valid Unity YAML.", state.status);
}

test "merge UI state: malformed flow input returns a status" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try conflictPlan(arena, 1);
    var state = try State.init(arena, &fixture.plan);

    try state.handle(.{ .edit_result = "{fileID: 1, bad}" });
    try state.handle(.apply_result);

    try testing.expectEqual(@as(usize, 1), state.unresolvedCount());
    try testing.expectEqualStrings("The result is not valid Unity YAML.", state.status);
}

test "merge UI state: a nested collection custom input returns a status" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try conflictPlan(arena, 1);
    var state = try State.init(arena, &fixture.plan);

    try state.handle(.{ .edit_result = "{outer: {value: 1}}" });
    try state.handle(.apply_result);

    try testing.expectEqual(@as(usize, 1), state.unresolvedCount());
    try testing.expectEqualStrings("The result is not valid Unity YAML.", state.status);
}

test "merge UI state: nested object reference members remain unresolved" {
    const nested_values = [_][]const u8{
        "{fileID: 0, extra: {value: 2}}",
        "{fileID: 0, extra: [2]}",
    };
    for (nested_values) |nested| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var fixture = try conflictPlan(arena, 1);
        var state = try State.init(arena, &fixture.plan);

        try state.handle(.{ .edit_result = nested });
        try state.handle(.apply_result);

        try testing.expectEqual(@as(usize, 1), state.unresolvedCount());
        try testing.expectEqualStrings("The result is not valid Unity YAML.", state.status);
    }
}

test "merge UI state: a sequence custom input returns a status" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try conflictPlan(arena, 1);
    var state = try State.init(arena, &fixture.plan);

    try state.handle(.{ .edit_result = "[first, second]" });
    try state.handle(.apply_result);

    try testing.expectEqual(@as(usize, 1), state.unresolvedCount());
    try testing.expectEqualStrings("The result is not valid Unity YAML.", state.status);
}

test "merge UI state: quoted non-GUID reference remains unresolved" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try conflictPlan(arena, 1);
    var state = try State.init(arena, &fixture.plan);
    const custom = "{fileID: 0, guid: \"a,b{c}\\\"d\", type: 3}";

    try state.handle(.{ .edit_result = custom });
    try state.handle(.apply_result);

    try testing.expectEqual(Outcome.active, state.outcome);
    try testing.expectEqual(@as(usize, 1), state.unresolvedCount());
    try testing.expectEqualStrings("The result is not valid Unity YAML.", state.status);
    try testing.expectError(error.InvalidResolution, core.merge.finish(arena, &fixture.plan));
}

test "merge UI state: quoted scalar punctuation applies" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try conflictPlan(arena, 1);
    var state = try State.init(arena, &fixture.plan);
    const custom = "\"a,b{c}\\\"d\"";

    try state.handle(.{ .edit_result = custom });
    try state.handle(.apply_result);

    try testing.expectEqual(Outcome.ready, state.outcome);
    try testing.expect(std.mem.indexOf(u8, try core.merge.finish(arena, &fixture.plan), custom) != null);
}

test "merge UI state: unterminated quoted scalar remains unresolved" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try conflictPlan(arena, 1);
    var state = try State.init(arena, &fixture.plan);

    try state.handle(.{ .edit_result = "\"unterminated" });
    try state.handle(.apply_result);

    try testing.expectEqual(@as(usize, 1), state.unresolvedCount());
    try testing.expectEqualStrings("The result is not valid Unity YAML.", state.status);
}

test "merge UI state: invalid double-quoted escapes remain unresolved" {
    const invalid_values = [_][]const u8{
        "\"bad\\q\"",
        "\"bad\\x1\"",
        "{fileID: 0, guid: \"bad\\q\", type: 3}",
        "{fileID: 0, guid: \"bad\\u12\", type: 3}",
    };
    for (invalid_values) |invalid| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var fixture = try conflictPlan(arena, 1);
        var state = try State.init(arena, &fixture.plan);

        try state.handle(.{ .edit_result = invalid });
        try state.handle(.apply_result);

        try testing.expectEqual(@as(usize, 1), state.unresolvedCount());
        try testing.expectEqualStrings("The result is not valid Unity YAML.", state.status);
    }
}

test "merge UI state: edit input is copied before apply" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try conflictPlan(arena, 1);
    var state = try State.init(arena, &fixture.plan);
    var input = [_]u8{ '4', '2' };

    try state.handle(.{ .edit_result = &input });
    input = .{ '9', '9' };
    try state.handle(.apply_result);

    const result = try core.merge.finish(arena, &fixture.plan);
    try testing.expect(std.mem.indexOf(u8, result, "  m_Mass: 42\n") != null);
}

test "merge UI state: abort restores every initial atomic member" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try conflictPlan(arena, 2);
    try groupConflicts(arena, &fixture.plan);
    var state = try State.init(arena, &fixture.plan);

    try state.handle(.choose_ours);
    try state.handle(.apply_result);
    try state.handle(.{ .edit_result = "7" });
    state.status = "old status";
    try state.handle(.abort);

    for (fixture.plan.operations) |operation_item| {
        try testing.expect(operation_item.resolution == .unresolved);
    }
    try testing.expectEqual(@as(?core.merge.Resolution, null), state.pending);
    try testing.expectEqualStrings("", state.status);
    try testing.expectEqual(Outcome.aborted, state.outcome);
}

test "merge UI state: abort restores an active state" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try conflictPlan(arena, 2);
    var state = try State.init(arena, &fixture.plan);

    try state.handle(.choose_ours);
    try state.handle(.apply_result);
    try testing.expectEqual(Outcome.active, state.outcome);
    try state.handle(.choose_theirs);
    try state.handle(.abort);

    for (fixture.plan.operations) |operation_item| {
        try testing.expect(operation_item.resolution == .unresolved);
    }
    try testing.expectEqual(Outcome.aborted, state.outcome);
}

test "merge UI state: abort restores resolutions that started complete" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try conflictPlan(arena, 2);
    try core.merge.resolve(arena, &fixture.plan, fixture.plan.operations[0].id, .{ .take = .ours });
    var state = try State.init(arena, &fixture.plan);

    try state.handle(.choose_theirs);
    try state.handle(.apply_result);
    try state.handle(.abort);

    try testing.expect(fixture.plan.operations[0].resolution.take == .ours);
    try testing.expect(fixture.plan.operations[1].resolution == .unresolved);
}

test "merge UI state: an empty plan is ready and handles every action safely" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const yaml = "--- !u!54 &54\nRigidbody:\n  m_Mass: 5\n";
    var fixture = try core.merge.build(arena, yaml, yaml, yaml);
    var state = try State.init(arena, &fixture.plan);

    try testing.expectEqual(Outcome.ready, state.outcome);
    try testing.expectEqual(@as(usize, 0), state.conflict_indices.len);
    try state.handle(.move_up);
    try state.handle(.move_down);
    try state.handle(.{ .select_conflict = 1 });
    try state.handle(.choose_ours);
    try state.handle(.choose_theirs);
    try state.handle(.{ .edit_result = "7" });
    try state.handle(.apply_result);
    try testing.expectEqual(Outcome.ready, state.outcome);
    try testing.expectEqual(@as(usize, 0), state.unresolvedCount());

    try state.handle(.abort);
    try testing.expectEqual(Outcome.aborted, state.outcome);
}
