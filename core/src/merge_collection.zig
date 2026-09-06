const std = @import("std");
const model = @import("model.zig");
const Allocator = std.mem.Allocator;

pub const Side = enum { base, ours, theirs };
pub const ItemRef = struct { side: Side, index: usize };
pub const ConflictId = u32;
pub const IdentityPolicy = enum { ordered };
pub const Input = struct {
    base: []const *const model.Node,
    ours: []const *const model.Node,
    theirs: []const *const model.Node,
    identity: IdentityPolicy = .ordered,
};
pub const Choice = union(enum) {
    take: Side,
    remove,
    ours_then_theirs,
    theirs_then_ours,
    items: []const ItemRef,
};
pub const ConflictKind = enum { ambiguous_correspondence, delete_edit, insertion_order, edit_edit };
pub const Conflict = struct {
    id: ConflictId,
    kind: ConflictKind,
    base_start: usize,
    base_end: usize,
    base: []const ItemRef,
    ours: []const ItemRef,
    theirs: []const ItemRef,
    resolution: ?[]const ItemRef = null,
};
pub const Segment = union(enum) { accepted: []const ItemRef, conflict: ConflictId };
// All allocated slices belong to the supplied arena. Input nodes remain borrowed.
pub const Plan = struct { input: Input, segments: []const Segment, conflicts: []Conflict };
pub const Error = Allocator.Error || error{ UnresolvedConflict, InvalidConflict, InvalidChoice, InvalidItemRef };

const Hunk = struct {
    start: usize,
    end: usize,
    side: Side,
    first: usize,
    last: usize,
    ambiguous: bool = false,
    anchors: []const Anchor = &.{},
};

const Anchor = struct { base: usize, side: usize };

fn equal(a: []const *const model.Node, b: []const *const model.Node) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (!model.Node.eql(left, right)) return false;
    return true;
}

fn references(arena: Allocator, side: Side, first: usize, last: usize) Allocator.Error![]const ItemRef {
    const result = try arena.alloc(ItemRef, last - first);
    for (result, first..) |*ref, i| ref.* = .{ .side = side, .index = i };
    return result;
}

// Mandatory exact matches are the anchors shared by every optimal alignment.
// Counting possible matches and deletions avoids enumerating duplicate alignments.
fn changes(arena: Allocator, base: []const *const model.Node, side: []const *const model.Node, origin: Side) Allocator.Error![]const Hunk {
    if (equal(base, side)) return &.{};
    var hunks: std.ArrayList(Hunk) = .empty;
    const max_cells = 1_000_000;
    if (base.len >= max_cells or side.len >= max_cells or (base.len + 1) > max_cells / (side.len + 1)) {
        try hunks.append(arena, .{ .start = 0, .end = base.len, .side = origin, .first = 0, .last = side.len, .ambiguous = true });
        return hunks.toOwnedSlice(arena);
    }
    const width = side.len + 1;
    const forward = try arena.alloc(u32, (base.len + 1) * width);
    const backward = try arena.alloc(u32, forward.len);
    @memset(forward, 0);
    @memset(backward, 0);
    for (base, 0..) |value, i| for (side, 0..) |other, j| {
        forward[(i + 1) * width + j + 1] = if (model.Node.eql(value, other))
            forward[i * width + j] + 1
        else
            @max(forward[i * width + j + 1], forward[(i + 1) * width + j]);
    };
    var i = base.len;
    while (i > 0) {
        i -= 1;
        var j = side.len;
        while (j > 0) {
            j -= 1;
            backward[i * width + j] = if (model.Node.eql(base[i], side[j]))
                backward[(i + 1) * width + j + 1] + 1
            else
                @max(backward[(i + 1) * width + j], backward[i * width + j + 1]);
        }
    }
    const length = backward[0];
    var previous_base: usize = 0;
    var previous_side: usize = 0;
    var ambiguous = false;
    for (base, 0..) |value, bi| {
        var candidate: ?usize = null;
        var count: usize = 0;
        var can_delete = false;
        for (0..side.len + 1) |sj| {
            if (forward[bi * width + sj] + backward[(bi + 1) * width + sj] == length) can_delete = true;
            if (sj < side.len and model.Node.eql(value, side[sj]) and
                forward[bi * width + sj] + 1 + backward[(bi + 1) * width + sj + 1] == length)
            {
                candidate = sj;
                count += 1;
            }
        }
        if (count == 1 and !can_delete) {
            const sj = candidate.?;
            if (previous_base != bi or previous_side != sj) try hunks.append(arena, .{
                .start = previous_base,
                .end = bi,
                .side = origin,
                .first = previous_side,
                .last = sj,
                .ambiguous = ambiguous,
            });
            previous_base = bi + 1;
            previous_side = sj + 1;
            ambiguous = false;
        } else if (count > 0) ambiguous = true;
    }
    if (previous_base != base.len or previous_side != side.len) try hunks.append(arena, .{
        .start = previous_base,
        .end = base.len,
        .side = origin,
        .first = previous_side,
        .last = side.len,
        .ambiguous = ambiguous,
    });
    const joined = try joinMoves(arena, base, side, hunks.items);
    return splitDeletions(arena, joined);
}

fn splitDeletions(arena: Allocator, hunks: []const Hunk) Allocator.Error![]const Hunk {
    var result: std.ArrayList(Hunk) = .empty;
    for (hunks) |hunk| {
        if (!hunk.ambiguous and hunk.first == hunk.last and hunk.end - hunk.start > 1) {
            // A proven deletion has no surviving correspondence to guess. Keep its
            // base occurrences separate so one delete/edit choice cannot restore
            // neighboring removals. Join possible moves before applying this rule.
            for (hunk.start..hunk.end) |index| {
                var deletion = hunk;
                deletion.start = index;
                deletion.end = index + 1;
                try result.append(arena, deletion);
            }
        } else try result.append(arena, hunk);
    }
    return result.toOwnedSlice(arena);
}

fn joinMoves(arena: Allocator, base: []const *const model.Node, side: []const *const model.Node, hunks: []const Hunk) Allocator.Error![]const Hunk {
    const joined_until = try arena.alloc(usize, hunks.len);
    for (joined_until, 0..) |*last, i| last.* = i;
    for (hunks, 0..) |removed, i| {
        for (hunks, 0..) |inserted, j| {
            if (i == j) continue;
            var shares_value = false;
            for (base[removed.start..removed.end]) |old| {
                for (side[inserted.first..inserted.last]) |added| {
                    if (model.Node.eql(old, added)) {
                        shares_value = true;
                        break;
                    }
                }
                if (shares_value) break;
            }
            if (shares_value) {
                const first = @min(i, j);
                joined_until[first] = @max(joined_until[first], @max(i, j));
            }
        }
    }
    var result: std.ArrayList(Hunk) = .empty;
    var i: usize = 0;
    while (i < hunks.len) {
        var last = joined_until[i];
        var j = i;
        while (j <= last) : (j += 1) last = @max(last, joined_until[j]);
        var hunk = hunks[i];
        if (last > i) {
            // A moved value must not be accepted separately from its removal.
            // Otherwise resolving delete/edit could keep both old and edited copies.
            hunk.end = hunks[last].end;
            hunk.last = hunks[last].last;
            hunk.ambiguous = true;
            var anchors: std.ArrayList(Anchor) = .empty;
            for (i..last) |between| {
                const left = hunks[between];
                const right = hunks[between + 1];
                for (left.end..right.start, left.last..) |base_index, side_index| {
                    try anchors.append(arena, .{ .base = base_index, .side = side_index });
                }
            }
            // Joining move endpoints changes the conflict boundary, not the exact
            // correspondence of the intervening anchors. Keep that evidence.
            hunk.anchors = try anchors.toOwnedSlice(arena);
        }
        try result.append(arena, hunk);
        i = last + 1;
    }
    return result.toOwnedSlice(arena);
}

fn lessThan(_: void, a: Hunk, b: Hunk) bool {
    if (a.start != b.start) return a.start < b.start;
    return a.end < b.end;
}

fn overlaps(start: usize, end: usize, hunk: Hunk) bool {
    if (start == end and hunk.start == hunk.end) return start == hunk.start;
    // A boundary insertion survives a neighboring replacement or deletion.
    if (hunk.start == hunk.end) return hunk.start > start and hunk.start < end;
    if (start == end) return start > hunk.start and start < hunk.end;
    return hunk.start < end and hunk.end > start;
}

fn candidateRefs(arena: Allocator, hunks: []const Hunk, side: Side, start: usize, end: usize) Allocator.Error![]const ItemRef {
    var refs: std.ArrayList(ItemRef) = .empty;
    var cursor = start;
    for (hunks) |hunk| {
        if (hunk.side != side) continue;
        try refs.appendSlice(arena, try references(arena, .base, cursor, hunk.start));
        try refs.appendSlice(arena, try references(arena, side, hunk.first, hunk.last));
        cursor = hunk.end;
    }
    try refs.appendSlice(arena, try references(arena, .base, cursor, end));
    return refs.toOwnedSlice(arena);
}

fn anchorIndex(anchors: []const Anchor, base_index: usize) ?usize {
    for (anchors) |anchor| if (anchor.base == base_index) return anchor.side;
    return null;
}

fn anchoredRange(moving: Hunk, edit: Hunk) ?struct { start: usize, end: usize } {
    const start = anchorIndex(moving.anchors, edit.start) orelse return null;
    if (edit.start == edit.end) {
        // An insertion is independent only when both neighboring anchors still
        // touch in the moved order. A missing neighbor supplies no order evidence.
        if (edit.start == 0) return null;
        const left = anchorIndex(moving.anchors, edit.start - 1) orelse return null;
        if (left + 1 != start) return null;
    } else {
        for (edit.start..edit.end, start..) |base_index, side_index| {
            if ((anchorIndex(moving.anchors, base_index) orelse return null) != side_index) return null;
        }
    }
    return .{ .start = start, .end = start + edit.end - edit.start };
}

fn preserveAnchorEdits(arena: Allocator, hunks: []const Hunk, selected: Side, candidate: []const ItemRef) Allocator.Error![]const ItemRef {
    var refs = candidate;
    for (hunks) |moving| {
        if (moving.anchors.len == 0 or (selected != .base and selected != moving.side)) continue;
        for (hunks) |edit| {
            if (edit.side == moving.side or edit.ambiguous) continue;
            const mapped = anchoredRange(moving, edit) orelse continue;
            const first = if (selected == .base) edit.start else mapped.start;
            const end = if (selected == .base) edit.end else mapped.end;
            for (refs, 0..) |ref, at| {
                if (ref.side != selected or ref.index != first) continue;
                const removed_count = end - first;
                if (removed_count > refs.len - at) break;
                var contiguous = true;
                for (refs[at .. at + removed_count], first..) |old, index| {
                    if (old.side != selected or old.index != index) contiguous = false;
                }
                if (!contiguous) break;
                const replacement = try references(arena, edit.side, edit.first, edit.last);
                refs = try std.mem.concat(arena, ItemRef, &.{ refs[0..at], replacement, refs[at + removed_count ..] });
                break;
            }
        }
    }
    return refs;
}

fn referencedNode(input: Input, ref: ItemRef) *const model.Node {
    return switch (ref.side) {
        .base => input.base[ref.index],
        .ours => input.ours[ref.index],
        .theirs => input.theirs[ref.index],
    };
}

fn equalRefs(input: Input, a: []const ItemRef, b: []const ItemRef) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (!model.Node.eql(referencedNode(input, left), referencedNode(input, right))) return false;
    return true;
}

pub fn build(arena: Allocator, input: Input) Error!Plan {
    var segments: std.ArrayList(Segment) = .empty;
    var conflicts: std.ArrayList(Conflict) = .empty;
    const unchanged: ?Side = if (equal(input.ours, input.theirs)) .ours else if (equal(input.base, input.ours)) .theirs else if (equal(input.base, input.theirs)) .ours else null;
    if (unchanged) |side| {
        const count = switch (side) {
            .ours => input.ours.len,
            .theirs => input.theirs.len,
            .base => input.base.len,
        };
        try segments.append(arena, .{ .accepted = try references(arena, side, 0, count) });
    } else {
        var hunks: std.ArrayList(Hunk) = .empty;
        try hunks.appendSlice(arena, try changes(arena, input.base, input.ours, .ours));
        try hunks.appendSlice(arena, try changes(arena, input.base, input.theirs, .theirs));
        std.mem.sort(Hunk, hunks.items, {}, lessThan);
        var cursor: usize = 0;
        var i: usize = 0;
        while (i < hunks.items.len) {
            const start = hunks.items[i].start;
            var end = hunks.items[i].end;
            var last = i + 1;
            while (last < hunks.items.len and overlaps(start, end, hunks.items[last])) : (last += 1) end = @max(end, hunks.items[last].end);
            const group = hunks.items[i..last];
            try segments.append(arena, .{ .accepted = try references(arena, .base, cursor, start) });
            const base = try preserveAnchorEdits(arena, group, .base, try references(arena, .base, start, end));
            const ours = try preserveAnchorEdits(arena, group, .ours, try candidateRefs(arena, group, .ours, start, end));
            const theirs = try preserveAnchorEdits(arena, group, .theirs, try candidateRefs(arena, group, .theirs, start, end));
            var ambiguous = false;
            var has_ours = false;
            var has_theirs = false;
            for (group) |hunk| {
                ambiguous = ambiguous or hunk.ambiguous;
                has_ours = has_ours or hunk.side == .ours;
                has_theirs = has_theirs or hunk.side == .theirs;
            }
            const insertion = start == end and has_ours and has_theirs;
            const accepted: ?[]const ItemRef = if (ambiguous or insertion) null else if (!has_ours) theirs else if (!has_theirs) ours else if (equalRefs(input, ours, theirs)) ours else null;
            if (accepted) |refs| {
                try segments.append(arena, .{ .accepted = refs });
            } else {
                const id: ConflictId = @intCast(conflicts.items.len);
                const kind: ConflictKind = if (ambiguous) .ambiguous_correspondence else if (insertion) .insertion_order else if (ours.len == 0 or theirs.len == 0) .delete_edit else .edit_edit;
                try conflicts.append(arena, .{ .id = id, .kind = kind, .base_start = start, .base_end = end, .base = base, .ours = ours, .theirs = theirs });
                try segments.append(arena, .{ .conflict = id });
            }
            cursor = end;
            i = last;
        }
        try segments.append(arena, .{ .accepted = try references(arena, .base, cursor, input.base.len) });
    }
    return .{ .input = input, .segments = try segments.toOwnedSlice(arena), .conflicts = try conflicts.toOwnedSlice(arena) };
}

fn contains(refs: []const ItemRef, ref: ItemRef) bool {
    for (refs) |candidate| if (std.meta.eql(candidate, ref)) return true;
    return false;
}

pub fn resolve(arena: Allocator, plan: *Plan, id: ConflictId, choice: Choice) Error!void {
    if (id >= plan.conflicts.len) return error.InvalidConflict;
    const conflict = &plan.conflicts[id];
    const selected = switch (choice) {
        .take => |side| switch (side) {
            .base => conflict.base,
            .ours => conflict.ours,
            .theirs => conflict.theirs,
        },
        .remove => &.{},
        .items => |refs| blk: {
            for (refs, 0..) |ref, i| {
                if (!contains(conflict.base, ref) and !contains(conflict.ours, ref) and !contains(conflict.theirs, ref)) return error.InvalidItemRef;
                // Repeating a reference invents an occurrence; distinct equal-valued refs remain valid.
                if (contains(refs[0..i], ref)) return error.InvalidItemRef;
            }
            break :blk refs;
        },
        .ours_then_theirs, .theirs_then_ours => blk: {
            if (conflict.kind != .insertion_order) return error.InvalidChoice;
            const first = if (choice == .ours_then_theirs) conflict.ours else conflict.theirs;
            const second = if (choice == .ours_then_theirs) conflict.theirs else conflict.ours;
            break :blk try std.mem.concat(arena, ItemRef, &.{ first, second });
        },
    };
    // Validate before replacing a previous resolution, including allocation failures.
    conflict.resolution = try arena.dupe(ItemRef, selected);
}

pub fn materialize(arena: Allocator, plan: *const Plan) Error![]const ItemRef {
    var refs: std.ArrayList(ItemRef) = .empty;
    for (plan.segments) |segment| switch (segment) {
        .accepted => |accepted| try refs.appendSlice(arena, accepted),
        .conflict => |id| try refs.appendSlice(arena, plan.conflicts[id].resolution orelse return error.UnresolvedConflict),
    };
    return refs.toOwnedSlice(arena);
}

fn testInput(arena: Allocator, base: []const u8, ours: []const u8, theirs: []const u8) !Input {
    var input: Input = undefined;
    inline for (.{ "base", "ours", "theirs" }, .{ base, ours, theirs }) |field, text| {
        const nodes = try arena.alloc(*const model.Node, text.len);
        for (text, 0..) |_, i| {
            const node = try arena.create(model.Node);
            node.* = .{ .scalar = text[i .. i + 1] };
            nodes[i] = node;
        }
        @field(input, field) = nodes;
    }
    input.identity = .ordered;
    return input;
}

fn expectText(arena: Allocator, plan: *const Plan, expected: []const u8) !void {
    const refs = try materialize(arena, plan);
    try std.testing.expectEqual(expected.len, refs.len);
    for (refs, expected) |ref, char| {
        const nodes = switch (ref.side) {
            .base => plan.input.base,
            .ours => plan.input.ours,
            .theirs => plan.input.theirs,
        };
        try std.testing.expectEqual(char, nodes[ref.index].scalar[0]);
    }
}

test "complete equality and one unchanged side preserve every occurrence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Complete equality is valid evidence even when individual occurrences repeat.
    for ([_][4][]const u8{
        .{ "", "", "", "" },         .{ "aa", "aaa", "aaa", "aaa" },
        .{ "ab", "ab", "ba", "ba" }, .{ "ab", "", "ab", "" },
    }) |case| {
        const plan = try build(a, try testInput(a, case[0], case[1], case[2]));
        try expectText(a, &plan, case[3]);
    }
}

test "independent replacements removals and insertion gaps combine" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][4][]const u8{
        .{ "ab", "Ab", "aB", "AB" },
        .{ "abcd", "acd", "abcD", "acD" },
        .{ "ab", "axb", "aby", "axby" },
        .{ "ab", "xb", "ayb", "xyb" },
    }) |case| {
        const plan = try build(a, try testInput(a, case[0], case[1], case[2]));
        try expectText(a, &plan, case[3]);
    }
}

test "same gap choices concatenate insertion blocks and retain independent edits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var plan = try build(a, try testInput(a, "abc", "axybc", "azbC"));
    try std.testing.expectEqual(@as(usize, 1), plan.conflicts.len);
    try std.testing.expectEqual(ConflictKind.insertion_order, plan.conflicts[0].kind);
    try std.testing.expectError(error.UnresolvedConflict, materialize(a, &plan));
    try resolve(a, &plan, 0, .ours_then_theirs);
    try expectText(a, &plan, "axyzbC");
    try resolve(a, &plan, 0, .theirs_then_ours);
    try expectText(a, &plan, "azxybC");
}

test "equal local insertions retain two occurrences when complete sides differ" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var plan = try build(a, try testInput(a, "abc", "axbc", "axbC"));
    try std.testing.expectEqual(@as(usize, 1), plan.conflicts.len);
    try resolve(a, &plan, 0, .ours_then_theirs);
    try expectText(a, &plan, "axxbC");
}

test "duplicate correspondence conflicts stay local and explicit items retain occurrences" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var plan = try build(a, try testInput(a, "aaxbc", "axbc", "aaxBc"));
    // It is unknown which a was removed, but the independent B edit is certain.
    try std.testing.expectEqual(@as(usize, 1), plan.conflicts.len);
    try std.testing.expectEqual(ConflictKind.ambiguous_correspondence, plan.conflicts[0].kind);
    try resolve(a, &plan, 0, .{ .items = &.{.{ .side = .base, .index = 1 }} });
    try expectText(a, &plan, "axBc");
    try std.testing.expectError(error.InvalidItemRef, resolve(a, &plan, 0, .{ .items = &.{.{ .side = .theirs, .index = 3 }} }));
    try expectText(a, &plan, "axBc");
}

test "separate delete edit conflicts resolve independently without dropping accepted changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var plan = try build(a, try testInput(a, "abcde", "bde", "AbCdE"));
    try std.testing.expectEqual(@as(usize, 2), plan.conflicts.len);
    try std.testing.expectEqual(ConflictKind.delete_edit, plan.conflicts[0].kind);
    try std.testing.expectError(error.InvalidChoice, resolve(a, &plan, 0, .ours_then_theirs));
    try std.testing.expectError(error.InvalidConflict, resolve(a, &plan, 99, .remove));
    try resolve(a, &plan, 0, .{ .take = .theirs });
    try std.testing.expectError(error.UnresolvedConflict, materialize(a, &plan));
    try resolve(a, &plan, 1, .remove);
    try expectText(a, &plan, "AbdE");
}

test "move and edit uncertainty remains resolvable instead of inventing identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var plan = try build(a, try testInput(a, "abc", "bac", "Abc"));
    try std.testing.expect(plan.conflicts.len > 0);
    for (plan.conflicts) |conflict| try resolve(a, &plan, conflict.id, .{ .take = .ours });
    try expectText(a, &plan, "bac");
}

test "large duplicate alignment is bounded and yields a resolvable conflict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try a.alloc(u8, 2000);
    @memset(text, 'a');
    var plan = try build(a, try testInput(a, text, text[0..1999], "b"));
    try std.testing.expectEqual(@as(usize, 1), plan.conflicts.len);
    try resolve(a, &plan, 0, .{ .take = .theirs });
    try expectText(a, &plan, "b");
}

test "a moved item's removal and insertion resolve together" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var plan = try build(a, try testInput(a, "abcd", "bcad", "AbcD"));
    // Choosing the edit must not also retain the old value at the moved position.
    try std.testing.expectEqual(@as(usize, 1), plan.conflicts.len);
    try resolve(a, &plan, 0, .{ .take = .theirs });
    try expectText(a, &plan, "AbcD");
    try resolve(a, &plan, 0, .{ .take = .ours });
    try expectText(a, &plan, "bcaD");
}

test "explicit item references cannot invent duplicate occurrences" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var plan = try build(a, try testInput(a, "a", "b", "c"));
    try std.testing.expectError(error.InvalidItemRef, resolve(a, &plan, 0, .{ .items = &.{
        .{ .side = .ours, .index = 0 }, .{ .side = .ours, .index = 0 },
    } }));
    try std.testing.expectError(error.UnresolvedConflict, materialize(a, &plan));
    try resolve(a, &plan, 0, .{ .items = &.{ .{ .side = .ours, .index = 0 }, .{ .side = .theirs, .index = 0 } } });
    try expectText(a, &plan, "bc");
}

test "a field named id does not declare collection identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var key = model.Node{ .scalar = "same" };
    var old = model.Node{ .scalar = "old" };
    var left = model.Node{ .scalar = "left" };
    var right = model.Node{ .scalar = "right" };
    var base_entries = [_]model.Entry{ .{ .key = "id", .value = &key }, .{ .key = "value", .value = &old } };
    var ours_entries = [_]model.Entry{ .{ .key = "id", .value = &key }, .{ .key = "value", .value = &left } };
    var theirs_entries = [_]model.Entry{ .{ .key = "id", .value = &key }, .{ .key = "value", .value = &right } };
    var base = model.Node{ .map = &base_entries };
    var ours = model.Node{ .map = &ours_entries };
    var theirs = model.Node{ .map = &theirs_entries };
    var plan = try build(a, .{ .base = &.{&base}, .ours = &.{&ours}, .theirs = &.{&theirs} });
    try std.testing.expectEqual(@as(usize, 1), plan.conflicts.len);
    try std.testing.expectError(error.UnresolvedConflict, materialize(a, &plan));
    try resolve(a, &plan, 0, .{ .take = .base });
    const refs = try materialize(a, &plan);
    try std.testing.expect(model.Node.eql(&base, referencedNode(plan.input, refs[0])));
}

test "joined moves retain independent anchor edits in either side order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The move is uncertain, but b remains an exact anchor on the moving side.
    // Choosing that move must retain the independently established b-to-B edit.
    for ([_]Side{ .ours, .theirs }) |moving_side| {
        const input = if (moving_side == .ours)
            try testInput(a, "abcde", "bcade", "aBcde")
        else
            try testInput(a, "abcde", "aBcde", "bcade");
        var plan = try build(a, input);
        try std.testing.expectEqual(@as(usize, 1), plan.conflicts.len);
        try resolve(a, &plan, 0, .{ .take = moving_side });
        try expectText(a, &plan, "Bcade");
        try resolve(a, &plan, 0, .{ .take = .base });
        try expectText(a, &plan, "aBcde");
    }
}

test "joined moves retain anchored deletions and insertion gaps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][2][]const u8{ .{ "acde", "cade" }, .{ "abxcde", "bxcade" } }) |case| {
        var plan = try build(a, try testInput(a, "abcde", "bcade", case[0]));
        try std.testing.expectEqual(@as(usize, 1), plan.conflicts.len);
        try resolve(a, &plan, 0, .{ .take = .ours });
        try expectText(a, &plan, case[1]);
        try resolve(a, &plan, 0, .{ .take = .base });
        try expectText(a, &plan, case[0]);
    }
}

test "shrink edit resolution does not restore independently deleted neighbors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]Side{ .ours, .theirs }) |shrinking_side| {
        const input = if (shrinking_side == .ours)
            try testInput(a, "abc", "a", "abC")
        else
            try testInput(a, "abc", "abC", "a");
        const editing_side: Side = if (shrinking_side == .ours) .theirs else .ours;
        var plan = try build(a, input);
        // Only c is disputed. Choosing its edit must preserve the accepted b removal.
        try std.testing.expectEqual(@as(usize, 1), plan.conflicts.len);
        try resolve(a, &plan, 0, .{ .take = editing_side });
        try expectText(a, &plan, "aC");
        try resolve(a, &plan, 0, .{ .take = shrinking_side });
        try expectText(a, &plan, "a");
        try resolve(a, &plan, 0, .{ .take = .base });
        try expectText(a, &plan, "ac");
    }
}

test "shrink edit choices preserve neighboring insertions and removals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Shrinking removes b, c, and d. The other side edits c and inserts X after d.
    // The insertion gap survives even when both of its former neighbors move apart.
    for ([_]Side{ .ours, .theirs }) |shrinking_side| {
        const input = if (shrinking_side == .ours)
            try testInput(a, "abcde", "ae", "abCdXe")
        else
            try testInput(a, "abcde", "abCdXe", "ae");
        const editing_side: Side = if (shrinking_side == .ours) .theirs else .ours;
        var plan = try build(a, input);
        try std.testing.expectEqual(@as(usize, 1), plan.conflicts.len);
        try resolve(a, &plan, 0, .{ .take = editing_side });
        try expectText(a, &plan, "aCXe");
        try resolve(a, &plan, 0, .remove);
        try expectText(a, &plan, "aXe");
    }
}
