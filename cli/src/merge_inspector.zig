const std = @import("std");
const core = @import("core");
const display = @import("display.zig");
const properties = core.merge.properties;
const Node = core.model.Node;

test "merge TUI: semantic rows hide inspector-hidden ownership fields" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const rigidbody =
        "--- !u!54 &54\nRigidbody:\n  m_GameObject: {fileID: 1}\n  m_Mass: 2\n";
    const document = try properties.parse(arena, rigidbody);
    const operation = core.merge.Operation{
        .id = 0,
        .atomic_id = 0,
        .kind = .document,
        .identity = .{ .document = .{ .class_id = 54, .file_id = 54 }, .property_path = "" },
        .property_path = "",
        .hierarchy_path = "Rigidbody",
        .values = .{
            .base = .{ .bytes = rigidbody, .node = document.node(&.{}), .span = null },
            .ours = .{ .bytes = rigidbody, .node = document.node(&.{}), .span = null },
            .theirs = .{ .bytes = rigidbody, .node = document.node(&.{}), .span = null },
        },
        .resolution = .unresolved,
    };
    const model = try build(arena, &operation, .unresolved, null);
    try std.testing.expectEqual(@as(usize, 1), model.rows.len);
    try std.testing.expectEqualStrings("Mass", model.rows[0].label);
}

test "merge TUI: unresolved semantic Result stays empty" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const rigidbody =
        "--- !u!54 &54\nRigidbody:\n  m_GameObject: {fileID: 1}\n  m_Mass: 2\n";
    const document = try properties.parse(arena, rigidbody);
    const operation = core.merge.Operation{
        .id = 0,
        .atomic_id = 0,
        .kind = .document,
        .identity = .{ .document = .{ .class_id = 54, .file_id = 54 }, .property_path = "" },
        .property_path = "",
        .hierarchy_path = "Rigidbody",
        .values = .{
            .base = .{ .bytes = rigidbody, .node = document.node(&.{}), .span = null },
            .ours = .{ .bytes = rigidbody, .node = document.node(&.{}), .span = null },
            .theirs = .{ .bytes = rigidbody, .node = document.node(&.{}), .span = null },
        },
        .resolution = .unresolved,
    };
    const model = try build(arena, &operation, .unresolved, null);
    try std.testing.expectEqualStrings("", try model.text(arena, 0, 3));
}

test "merge TUI: property comparisons expose changed children when value shapes differ" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const base = "--- !u!114 &2\nMonoBehaviour:\n  custom: old\n";
    const theirs = "--- !u!114 &2\nMonoBehaviour:\n  custom: {speed: 2, enabled: 1}\n";
    const b = try properties.parse(arena, base);
    const t = try properties.parse(arena, theirs);
    const operation = core.merge.Operation{
        .id = 0,
        .atomic_id = 0,
        .kind = .document,
        .identity = .{ .document = .{ .class_id = 114, .file_id = 2 }, .property_path = "" },
        .property_path = "",
        .hierarchy_path = "MonoBehaviour",
        .values = .{
            .base = .{ .bytes = base, .node = b.node(&.{}), .span = null },
            .ours = null,
            .theirs = .{ .bytes = theirs, .node = t.node(&.{}), .span = null },
        },
        .resolution = .unresolved,
    };
    const model = try build(arena, &operation, .{ .take = .theirs }, null);
    // A type change must not hide the fields the retained component will contain.
    try std.testing.expectEqual(@as(usize, 3), model.rows.len);
    try std.testing.expectEqualStrings("Custom.Speed", model.rows[1].label);
    try std.testing.expectEqualStrings("2", try valueText(arena, model.rows[1].values[3]));
}

test "merge TUI: dictionary field conflicts expose key and value rows" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix = "--- !u!114 &2\nMonoBehaviour:\n  m_Stats:\n";
    var fixture = try core.merge.build(
        arena,
        prefix ++ "  - key: Goblin\n    value: 1\n",
        prefix ++ "  - key: Goblin\n    value: 2\n",
        prefix ++ "  - key: Goblin\n    value: 3\n",
    );
    const operation = &fixture.plan.operations[0];
    try std.testing.expect(supports(operation));
    const model = try build(arena, operation, .unresolved, null);
    // SphereCollider already walks maps into named rows. A pair conflict must do the same
    // so Key stays visible next to the disagreed Value.
    try std.testing.expectEqual(@as(usize, 2), model.rows.len);
    try std.testing.expectEqualStrings("Key", model.rows[0].label);
    try std.testing.expectEqualStrings("Value", model.rows[1].label);
    try std.testing.expectEqualStrings("Goblin", try valueText(arena, model.rows[0].values[1]));
    try std.testing.expectEqualStrings("2", try valueText(arena, model.rows[1].values[1]));
    try std.testing.expectEqualStrings("3", try valueText(arena, model.rows[1].values[2]));
}

test "merge TUI: prefab override conflicts expose path and value rows" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix =
        "--- !u!1001 &1\n" ++
        "PrefabInstance:\n" ++
        "  m_Modification:\n" ++
        "    m_Modifications:\n" ++
        "    - target: {fileID: 40, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n" ++
        "      propertyPath: items.Array.data[0].speed\n" ++
        "      value: ";
    const suffix = "\n      objectReference: {fileID: 0}\n";
    const fixture = try core.merge.build(
        arena,
        prefix ++ "1" ++ suffix,
        prefix ++ "2" ++ suffix,
        prefix ++ "3" ++ suffix,
    );
    const operation = for (fixture.plan.operations) |*op| {
        if (op.resolution == .unresolved) break op;
    } else return error.TestUnexpectedResult;
    try std.testing.expect(supports(operation));
    const model = try build(arena, operation, .unresolved, null);
    // Variant overrides are a path plus a scalar. The tree label is not enough once ⇧R is available.
    try std.testing.expectEqual(@as(usize, 2), model.rows.len);
    try std.testing.expectEqualStrings("Path", model.rows[0].label);
    try std.testing.expectEqualStrings("Value", model.rows[1].label);
    try std.testing.expectEqualStrings("Items[0].Speed", try valueText(arena, model.rows[0].values[1]));
    try std.testing.expectEqualStrings("2", try valueText(arena, model.rows[1].values[1]));
    try std.testing.expectEqualStrings("3", try valueText(arena, model.rows[1].values[2]));
}

test "merge TUI: sequence order rows follow each side's item order" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix =
        "--- !u!1001 &1\n" ++
        "PrefabInstance:\n" ++
        "  m_Modification:\n" ++
        "    m_Modifications:\n";
    const suffix =
        "  m_SourcePrefab: {fileID: 100100000, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n";
    const name =
        "    - target: {fileID: 10, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n" ++
        "      propertyPath: m_Name\n" ++
        "      value: Root\n" ++
        "      objectReference: {fileID: 0}\n";
    const tag =
        "    - target: {fileID: 10, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n" ++
        "      propertyPath: m_TagString\n" ++
        "      value: Untagged\n" ++
        "      objectReference: {fileID: 0}\n";
    const layer =
        "    - target: {fileID: 10, guid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, type: 3}\n" ++
        "      propertyPath: m_Layer\n" ++
        "      value: 0\n" ++
        "      objectReference: {fileID: 0}\n";
    const fixture = try core.merge.build(
        arena,
        prefix ++ name ++ tag ++ layer ++ suffix,
        prefix ++ tag ++ name ++ layer ++ suffix,
        prefix ++ name ++ layer ++ tag ++ suffix,
    );
    const operation = for (fixture.plan.operations) |*op| {
        if (op.kind == .sequence_order and op.resolution == .unresolved) break op;
    } else return error.TestUnexpectedResult;
    try std.testing.expect(supports(operation));
    const model = try build(arena, operation, .unresolved, null);
    // A reorder is one list. Rows keep each side's YAML order instead of aligning by property.
    try std.testing.expectEqual(@as(usize, 3), model.rows.len);
    try std.testing.expectEqualStrings("[0]", model.rows[0].label);
    try std.testing.expectEqualStrings("[1]", model.rows[1].label);
    try std.testing.expectEqualStrings("[2]", model.rows[2].label);
    try std.testing.expectEqualStrings("Name", try valueText(arena, model.rows[0].values[0]));
    try std.testing.expectEqualStrings("Tag", try valueText(arena, model.rows[0].values[1]));
    try std.testing.expectEqualStrings("Name", try valueText(arena, model.rows[0].values[2]));
    try std.testing.expectEqualStrings("Tag", try valueText(arena, model.rows[1].values[0]));
    try std.testing.expectEqualStrings("Name", try valueText(arena, model.rows[1].values[1]));
    try std.testing.expectEqualStrings("Layer", try valueText(arena, model.rows[1].values[2]));
    try std.testing.expectEqualStrings("Layer", try valueText(arena, model.rows[2].values[0]));
    try std.testing.expectEqualStrings("Layer", try valueText(arena, model.rows[2].values[1]));
    try std.testing.expectEqualStrings("Tag", try valueText(arena, model.rows[2].values[2]));
    try std.testing.expect(!model.editable(0));
    const custom = try build(arena, operation, .{ .custom = tag ++ name ++ layer }, null);
    try std.testing.expectEqualStrings("Tag", try valueText(arena, custom.rows[0].values[3]));
    try std.testing.expectEqualStrings("Name", try valueText(arena, custom.rows[1].values[3]));
    try std.testing.expectEqualStrings("Layer", try valueText(arena, custom.rows[2].values[3]));
}

test "merge TUI: keyed reorder rows show pair keys" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  m_Stats:\n";
    const fixture = try core.merge.build(
        arena,
        prefix ++ "  - key: a\n    value: 1\n  - key: b\n    value: 2\n  - key: c\n    value: 3\n",
        prefix ++ "  - key: c\n    value: 3\n  - key: b\n    value: 2\n  - key: a\n    value: 1\n",
        prefix ++ "  - key: b\n    value: 2\n  - key: a\n    value: 1\n  - key: c\n    value: 3\n",
    );
    const operation = for (fixture.plan.operations) |*op| {
        if (op.resolution == .unresolved) break op;
    } else return error.TestUnexpectedResult;
    try std.testing.expect(supports(operation));
    const model = try build(arena, operation, .unresolved, null);
    try std.testing.expectEqual(@as(usize, 3), model.rows.len);
    try std.testing.expectEqualStrings("a", try valueText(arena, model.rows[0].values[0]));
    try std.testing.expectEqualStrings("c", try valueText(arena, model.rows[0].values[1]));
    try std.testing.expectEqualStrings("b", try valueText(arena, model.rows[0].values[2]));
    try std.testing.expectEqualStrings("b", try valueText(arena, model.rows[1].values[0]));
    try std.testing.expectEqualStrings("b", try valueText(arena, model.rows[1].values[1]));
    try std.testing.expectEqualStrings("a", try valueText(arena, model.rows[1].values[2]));
    try std.testing.expectEqualStrings("c", try valueText(arena, model.rows[2].values[0]));
    try std.testing.expectEqualStrings("a", try valueText(arena, model.rows[2].values[1]));
    try std.testing.expectEqualStrings("c", try valueText(arena, model.rows[2].values[2]));
}

test "merge TUI: keyed first/second reorder rows show first values" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  m_Stats:\n";
    const fixture = try core.merge.build(
        arena,
        prefix ++ "  - first: a\n    second: 1\n  - first: b\n    second: 2\n  - first: c\n    second: 3\n",
        prefix ++ "  - first: c\n    second: 3\n  - first: b\n    second: 2\n  - first: a\n    second: 1\n",
        prefix ++ "  - first: b\n    second: 2\n  - first: a\n    second: 1\n  - first: c\n    second: 3\n",
    );
    const operation = for (fixture.plan.operations) |*op| {
        if (op.resolution == .unresolved) break op;
    } else return error.TestUnexpectedResult;
    try std.testing.expect(supports(operation));
    const model = try build(arena, operation, .unresolved, null);
    try std.testing.expectEqual(@as(usize, 3), model.rows.len);
    try std.testing.expectEqualStrings("a", try valueText(arena, model.rows[0].values[0]));
    try std.testing.expectEqualStrings("c", try valueText(arena, model.rows[0].values[1]));
    try std.testing.expectEqualStrings("b", try valueText(arena, model.rows[0].values[2]));
}

test "merge TUI: custom keyed sequence result shows pair keys" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const prefix = "--- !u!114 &1\nMonoBehaviour:\n  m_Stats:\n";
    const fixture = try core.merge.build(
        arena,
        prefix ++ "  - key: a\n    value: 1\n  - key: b\n    value: 2\n  - key: c\n    value: 3\n",
        prefix ++ "  - key: c\n    value: 3\n  - key: b\n    value: 2\n  - key: a\n    value: 1\n",
        prefix ++ "  - key: b\n    value: 2\n  - key: a\n    value: 1\n  - key: c\n    value: 3\n",
    );
    const operation = for (fixture.plan.operations) |*op| {
        if (op.resolution == .unresolved) break op;
    } else return error.TestUnexpectedResult;
    try std.testing.expect(supports(operation));
    const custom = "  - key: b\n    value: 2\n  - key: a\n    value: 1\n  - key: d\n    value: 4\n";
    const model = try build(arena, operation, .{ .custom = custom }, null);
    try std.testing.expectEqual(@as(usize, 3), model.rows.len);
    try std.testing.expectEqualStrings("[0]", model.rows[0].label);
    try std.testing.expectEqualStrings("b", try valueText(arena, model.rows[0].values[3]));
    try std.testing.expectEqualStrings("a", try valueText(arena, model.rows[1].values[3]));
    try std.testing.expectEqualStrings("d", try valueText(arena, model.rows[2].values[3]));
}

test "merge TUI: game object rows show the edited name" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const fixture = try core.merge.build(
        arena,
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n  m_Name: Root\n" ++
            "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children:\n  - {fileID: 42}\n  m_Father: {fileID: 0}\n" ++
            "--- !u!1 &20\nGameObject:\n  m_Component:\n  - component: {fileID: 42}\n  - component: {fileID: 54}\n  m_Name: Child\n" ++
            "--- !u!4 &42\nTransform:\n  m_GameObject: {fileID: 20}\n  m_Children: []\n  m_Father: {fileID: 4}\n" ++
            "--- !u!54 &54\nRigidbody:\n  m_GameObject: {fileID: 20}\n  m_Mass: 1\n",
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n  m_Name: Root\n" ++
            "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children: []\n  m_Father: {fileID: 0}\n",
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n  m_Name: Root\n" ++
            "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children:\n  - {fileID: 42}\n  m_Father: {fileID: 0}\n" ++
            "--- !u!1 &20\nGameObject:\n  m_Component:\n  - component: {fileID: 42}\n  - component: {fileID: 54}\n  m_Name: Edited Child\n" ++
            "--- !u!4 &42\nTransform:\n  m_GameObject: {fileID: 20}\n  m_Children: []\n  m_Father: {fileID: 4}\n" ++
            "--- !u!54 &54\nRigidbody:\n  m_GameObject: {fileID: 20}\n  m_Mass: 1\n",
    );
    const operation = for (fixture.plan.operations) |*op| {
        if (op.kind == .game_object and op.identity.document.class_id == 1 and
            op.values.ours == null and op.values.theirs != null) break op;
    } else return error.TestUnexpectedResult;
    try std.testing.expect(supports(operation));
    const model = try build(arena, operation, .{ .take = .theirs }, null);
    var name_row: ?usize = null;
    for (model.rows, 0..) |row, index| {
        if (std.mem.eql(u8, row.label, "Name")) name_row = index;
    }
    const index = name_row orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Child", try valueText(arena, model.rows[index].values[0]));
    try std.testing.expectEqualStrings("—", try valueText(arena, model.rows[index].values[1]));
    try std.testing.expectEqualStrings("Edited Child", try valueText(arena, model.rows[index].values[2]));
    try std.testing.expectEqualStrings("Edited Child", try valueText(arena, model.rows[index].values[3]));
}

test "merge TUI: reparent rows show GameObject names" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const fixture = try core.merge.build(arena, reparentBase, reparentOurs, reparentTheirs);
    const operation = for (fixture.plan.operations) |*op| {
        if (op.kind == .reparent and op.resolution == .unresolved) break op;
    } else return error.TestUnexpectedResult;
    try std.testing.expect(supports(operation));
    const model = try build(arena, operation, .unresolved, &fixture.plan);
    try std.testing.expectEqual(@as(usize, 1), model.rows.len);
    try std.testing.expectEqualStrings("Father", model.rows[0].label);
    try std.testing.expectEqualStrings("Root", try valueText(arena, model.rows[0].values[0]));
    try std.testing.expectEqualStrings("Parent A", try valueText(arena, model.rows[0].values[1]));
    try std.testing.expectEqualStrings("Parent B", try valueText(arena, model.rows[0].values[2]));
    try std.testing.expect(!model.editable(0));
}

const reparentBase =
    "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n  m_Name: Root\n" ++
    "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children:\n  - {fileID: 40}\n  - {fileID: 41}\n  - {fileID: 42}\n  m_Father: {fileID: 0}\n" ++
    "--- !u!1 &10\nGameObject:\n  m_Component:\n  - component: {fileID: 40}\n  m_Name: Parent A\n" ++
    "--- !u!4 &40\nTransform:\n  m_GameObject: {fileID: 10}\n  m_Children: []\n  m_Father: {fileID: 4}\n" ++
    "--- !u!1 &11\nGameObject:\n  m_Component:\n  - component: {fileID: 41}\n  m_Name: Parent B\n" ++
    "--- !u!4 &41\nTransform:\n  m_GameObject: {fileID: 11}\n  m_Children: []\n  m_Father: {fileID: 4}\n" ++
    "--- !u!1 &20\nGameObject:\n  m_Component:\n  - component: {fileID: 42}\n  m_Name: Child\n" ++
    "--- !u!4 &42\nTransform:\n  m_GameObject: {fileID: 20}\n  m_Children: []\n  m_Father: {fileID: 4}\n";

const reparentOurs =
    "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n  m_Name: Root\n" ++
    "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children:\n  - {fileID: 40}\n  - {fileID: 41}\n  m_Father: {fileID: 0}\n" ++
    "--- !u!1 &10\nGameObject:\n  m_Component:\n  - component: {fileID: 40}\n  m_Name: Parent A\n" ++
    "--- !u!4 &40\nTransform:\n  m_GameObject: {fileID: 10}\n  m_Children:\n  - {fileID: 42}\n  m_Father: {fileID: 4}\n" ++
    "--- !u!1 &11\nGameObject:\n  m_Component:\n  - component: {fileID: 41}\n  m_Name: Parent B\n" ++
    "--- !u!4 &41\nTransform:\n  m_GameObject: {fileID: 11}\n  m_Children: []\n  m_Father: {fileID: 4}\n" ++
    "--- !u!1 &20\nGameObject:\n  m_Component:\n  - component: {fileID: 42}\n  m_Name: Child\n" ++
    "--- !u!4 &42\nTransform:\n  m_GameObject: {fileID: 20}\n  m_Children: []\n  m_Father: {fileID: 40}\n";

const reparentTheirs =
    "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n  m_Name: Root\n" ++
    "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children:\n  - {fileID: 40}\n  - {fileID: 41}\n  m_Father: {fileID: 0}\n" ++
    "--- !u!1 &10\nGameObject:\n  m_Component:\n  - component: {fileID: 40}\n  m_Name: Parent A\n" ++
    "--- !u!4 &40\nTransform:\n  m_GameObject: {fileID: 10}\n  m_Children: []\n  m_Father: {fileID: 4}\n" ++
    "--- !u!1 &11\nGameObject:\n  m_Component:\n  - component: {fileID: 41}\n  m_Name: Parent B\n" ++
    "--- !u!4 &41\nTransform:\n  m_GameObject: {fileID: 11}\n  m_Children:\n  - {fileID: 42}\n  m_Father: {fileID: 4}\n" ++
    "--- !u!1 &20\nGameObject:\n  m_Component:\n  - component: {fileID: 42}\n  m_Name: Child\n" ++
    "--- !u!4 &42\nTransform:\n  m_GameObject: {fileID: 20}\n  m_Children: []\n  m_Father: {fileID: 41}\n";

test "merge TUI: literal property keys remain distinct from nested paths and array indices" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const base = "--- !u!114 &2\nMonoBehaviour:\n  custom.value: 1\n  custom: {value: 2}\n  items[0]: 3\n  items: [4]\n";
    const theirs = "--- !u!114 &2\nMonoBehaviour:\n  custom.value: 5\n  custom: {value: 6}\n  items[0]: 7\n  items: [8]\n";
    const fixture = try core.merge.build(arena, base, "", theirs);
    const model = try build(arena, &fixture.plan.operations[0], .{ .take = .theirs }, null);
    // Display paths must identify the same fields as the source-preserving edit paths.
    try std.testing.expectEqual(@as(usize, 4), model.rows.len);
    for ([_][]const u8{ "[\"custom.value\"]", "Custom.Value", "[\"items[0]\"]", "Items[0]" }, model.rows) |expected, row| {
        try std.testing.expectEqualStrings(expected, row.label);
    }
}

pub const Row = struct {
    path: []const properties.Segment,
    label: []const u8,
    values: [4]?*const Node,
    changed: bool,
};

pub const Model = struct {
    documents: [4]?properties.Document,
    rows: []const Row,

    pub fn editable(self: Model, index: usize) bool {
        if (index >= self.rows.len) return false;
        const row = self.rows[index];
        if (self.documents[3]) |result| {
            return result.editable(row.path);
        }
        // A missing Result document is not editable. Synthetic Path/Value tables have no documents.
        for (self.documents) |document| {
            if (document != null) return false;
        }
        if (std.mem.eql(u8, row.label, "Path") or std.mem.eql(u8, row.label, "Key")) return false;
        // Sequence order is one list choice. An index row is not a cell you can edit.
        if (row.path.len == 1 and row.path[0] == .index) return false;
        // Reparent is one parent choice. The displayed name is not YAML to edit.
        if (row.path.len == 1 and row.path[0] == .key and std.mem.eql(u8, row.path[0].key, "m_Father")) return false;
        for (row.values) |node| {
            if (node) |value| {
                if (value.* != .scalar and value.* != .ref) return false;
            }
        }
        return true;
    }

    pub fn text(self: Model, arena: std.mem.Allocator, index: usize, column: usize) ![]const u8 {
        if (self.documents[column]) |document| {
            if (document.input(self.rows[index].path)) |input| if (input.len == 0) return "<empty>";
        }
        const rendered = try valueText(arena, self.rows[index].values[column]);
        if (column == 3 and (std.mem.eql(u8, rendered, "—") or std.mem.eql(u8, rendered, "-"))) return "";
        return rendered;
    }
};

pub fn supports(operation: *const core.merge.Operation) bool {
    if (operation.kind == .prefab_override) return true;
    if (operation.kind == .sequence_order) return sequenceOrderSupported(operation);
    if (keyedPairSequenceSupported(operation)) return true;
    if (operation.kind == .reparent) return true;
    if (operation.kind == .field) {
        var saw_map = false;
        for ([_]?core.merge.SideValue{ operation.values.base, operation.values.ours, operation.values.theirs }) |value| {
            const present = value orelse continue;
            const node = present.node orelse return false;
            if (node.* != .map) return false;
            saw_map = true;
        }
        return saw_map;
    }
    if (operation.kind != .component and operation.kind != .document and operation.kind != .game_object) return false;
    for ([_]?core.merge.SideValue{ operation.values.base, operation.values.ours, operation.values.theirs }) |value| if (value) |present| {
        const node = present.node orelse return false;
        if (node.* != .map) return false;
    };
    return true;
}

pub fn build(
    arena: std.mem.Allocator,
    operation: *const core.merge.Operation,
    resolution: core.merge.Resolution,
    plan: ?*const core.merge.MergePlan,
) !Model {
    if (operation.kind == .prefab_override) return buildPrefabOverride(arena, operation, resolution);
    if (operation.kind == .sequence_order or keyedPairSequenceSupported(operation)) return buildSequenceOrder(arena, operation, resolution);
    if (operation.kind == .reparent) return buildReparent(arena, operation, resolution, plan);
    if (operation.kind == .field) {
        const roots: [4]?*const Node = .{
            if (operation.values.base) |value| value.node else null,
            if (operation.values.ours) |value| value.node else null,
            if (operation.values.theirs) |value| value.node else null,
            switch (resolution) {
                .take => |side| if (operation.values.get(side)) |value| value.node else null,
                .custom => |text| try customFieldRoot(arena, operation, text),
                else => null,
            },
        };
        var builder: Builder = .{ .arena = arena, .documents = @splat(null) };
        try builder.walk(&.{}, "", roots);
        return .{ .documents = @splat(null), .rows = try builder.rows.toOwnedSlice(arena) };
    }
    const result_bytes: ?[]const u8 = switch (resolution) {
        .take => |side| if (operation.values.get(side)) |value| value.bytes else null,
        .custom => |value| value,
        .unresolved, .remove => null,
    };
    var documents: [4]?properties.Document = @splat(null);
    for ([_]?[]const u8{
        if (operation.values.base) |v| v.bytes else null,
        if (operation.values.ours) |v| v.bytes else null,
        if (operation.values.theirs) |v| v.bytes else null,
        result_bytes,
    }, 0..) |bytes, i| {
        if (bytes) |present| documents[i] = properties.parse(arena, present) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
    }
    var builder: Builder = .{ .arena = arena, .documents = documents };
    var roots: [4]?*const Node = @splat(null);
    for (documents, 0..) |document, i| if (document) |present| {
        roots[i] = present.node(&.{});
    };
    try builder.walk(&.{}, "", roots);
    return .{ .documents = documents, .rows = try builder.rows.toOwnedSlice(arena) };
}

fn buildPrefabOverride(
    arena: std.mem.Allocator,
    operation: *const core.merge.Operation,
    resolution: core.merge.Resolution,
) !Model {
    const path_text = try core.displayPropertyPath(arena, operation.identity.property_path);
    const path_node = try scalarNode(arena, path_text);
    const rows = try arena.alloc(Row, 2);
    rows[0] = .{
        .path = try arena.dupe(properties.Segment, &.{.{ .key = "propertyPath" }}),
        .label = "Path",
        .values = .{ path_node, path_node, path_node, path_node },
        .changed = false,
    };
    rows[1] = .{
        .path = try arena.dupe(properties.Segment, &.{.{ .key = "value" }}),
        .label = "Value",
        .values = .{
            if (operation.values.base) |value| value.node else null,
            if (operation.values.ours) |value| value.node else null,
            if (operation.values.theirs) |value| value.node else null,
            switch (resolution) {
                .take => |side| if (operation.values.get(side)) |value| value.node else null,
                .custom => |text| if (std.mem.indexOfAny(u8, text, "\r\n") == null) try scalarNode(arena, text) else null,
                else => null,
            },
        },
        .changed = true,
    };
    return .{ .documents = @splat(null), .rows = rows };
}

fn sequenceOrderSupported(operation: *const core.merge.Operation) bool {
    var saw_seq = false;
    for ([_]?core.merge.SideValue{ operation.values.base, operation.values.ours, operation.values.theirs }) |value| {
        const present = value orelse continue;
        const node = present.node orelse return false;
        if (node.* != .seq) return false;
        saw_seq = true;
    }
    return saw_seq;
}

fn keyedPairSequenceSupported(operation: *const core.merge.Operation) bool {
    if (operation.kind != .field) return false;
    if (!sequenceOrderSupported(operation)) return false;
    for ([_]?core.merge.SideValue{ operation.values.base, operation.values.ours, operation.values.theirs }) |value| {
        const present = value orelse continue;
        const node = present.node orelse continue;
        if (node.* != .seq) continue;
        for (node.seq) |item| {
            if (item.* != .map) continue;
            if (Node.asScalar(item.get("key")) != null or Node.asScalar(item.get("first")) != null) return true;
        }
    }
    return false;
}

fn buildSequenceOrder(
    arena: std.mem.Allocator,
    operation: *const core.merge.Operation,
    resolution: core.merge.Resolution,
) !Model {
    const sides: [3]?*const Node = .{
        if (operation.values.base) |value| value.node else null,
        if (operation.values.ours) |value| value.node else null,
        if (operation.values.theirs) |value| value.node else null,
    };
    const result = try sequenceResultNode(arena, operation, resolution);
    var count: usize = 0;
    for (sides) |node| if (node) |seq| {
        if (seq.* == .seq) count = @max(count, seq.seq.len);
    };
    if (result) |seq| {
        if (seq.* == .seq) count = @max(count, seq.seq.len);
    }
    const rows = try arena.alloc(Row, count);
    for (rows, 0..) |*row, index| {
        var values: [4]?*const Node = .{
            try sequenceItemLabelNode(arena, sequenceItemAt(sides[0], index)),
            try sequenceItemLabelNode(arena, sequenceItemAt(sides[1], index)),
            try sequenceItemLabelNode(arena, sequenceItemAt(sides[2], index)),
            try sequenceItemLabelNode(arena, sequenceItemAt(result, index)),
        };
        var changed = false;
        var first: ?*const Node = null;
        for (values[0..3]) |node| {
            if (first == null) {
                first = node;
            } else {
                changed = changed or !equal(first, node);
            }
        }
        row.* = .{
            .path = try arena.dupe(properties.Segment, &.{.{ .index = index }}),
            .label = try std.fmt.allocPrint(arena, "[{d}]", .{index}),
            .values = values,
            .changed = changed,
        };
    }
    return .{ .documents = @splat(null), .rows = rows };
}

fn sequenceResultNode(
    arena: std.mem.Allocator,
    operation: *const core.merge.Operation,
    resolution: core.merge.Resolution,
) !?*const Node {
    return switch (resolution) {
        .take => |side| if (operation.values.get(side)) |value| value.node else null,
        .custom => |text| parseSequenceResult(arena, text),
        .unresolved, .remove => null,
    };
}

fn parseSequenceResult(arena: std.mem.Allocator, text: []const u8) ?*const Node {
    const trimmed = std.mem.trimEnd(u8, text, " \r\n");
    if (trimmed.len == 0) return null;
    const body = indentBlock(arena, trimmed, 4) catch return null;
    if (sequenceFromWrapped(arena, std.fmt.allocPrint(arena, "--- !u!114 &1\nMonoBehaviour:\n  items:\n{s}", .{body}) catch return null)) |node| return node;
    if (sequenceFromWrapped(arena, std.fmt.allocPrint(arena, "--- !u!114 &1\nMonoBehaviour:\n  items: {s}\n", .{trimmed}) catch return null)) |node| return node;
    return null;
}

fn indentBlock(arena: std.mem.Allocator, text: []const u8, spaces: usize) ![]const u8 {
    var min_indent: usize = std.math.maxInt(usize);
    var probe = std.mem.splitScalar(u8, text, '\n');
    while (probe.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.trimStart(u8, line, " ").len == 0) continue;
        var indent: usize = 0;
        while (indent < line.len and line[indent] == ' ') indent += 1;
        min_indent = @min(min_indent, indent);
    }
    if (min_indent == std.math.maxInt(usize)) min_indent = 0;
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.trimStart(u8, line, " ").len == 0) continue;
        try out.appendNTimes(arena, ' ', spaces);
        try out.appendSlice(arena, line[@min(min_indent, line.len)..]);
        try out.append(arena, '\n');
    }
    return out.toOwnedSlice(arena);
}

fn sequenceFromWrapped(arena: std.mem.Allocator, wrapped: []const u8) ?*const Node {
    const document = properties.parse(arena, wrapped) catch return null;
    const node = document.node(&.{.{ .key = "items" }}) orelse return null;
    return switch (node.*) {
        .seq => |items| if (items.len == 0) null else node,
        else => null,
    };
}

fn sequenceItemAt(node: ?*const Node, index: usize) ?*const Node {
    const seq = node orelse return null;
    if (seq.* != .seq or index >= seq.seq.len) return null;
    return seq.seq[index];
}

fn sequenceItemLabelNode(arena: std.mem.Allocator, node: ?*const Node) !?*const Node {
    const item = node orelse return null;
    return try scalarNode(arena, try sequenceItemLabel(arena, item));
}

fn sequenceItemLabel(arena: std.mem.Allocator, node: *const Node) ![]const u8 {
    if (node.* == .map) {
        if (Node.asScalar(node.get("propertyPath"))) |path| return core.displayPropertyPath(arena, path);
        if (Node.asScalar(node.get("key"))) |key| return key;
        if (Node.asScalar(node.get("first"))) |first| return first;
    }
    return valueText(arena, node);
}

fn buildReparent(
    arena: std.mem.Allocator,
    operation: *const core.merge.Operation,
    resolution: core.merge.Resolution,
    plan: ?*const core.merge.MergePlan,
) !Model {
    const present = plan orelse return .{ .documents = @splat(null), .rows = &.{} };
    const values: [4]?*const Node = .{
        try fatherLabelNode(arena, present, .base, operation.values.base),
        try fatherLabelNode(arena, present, .ours, operation.values.ours),
        try fatherLabelNode(arena, present, .theirs, operation.values.theirs),
        try fatherResultNode(arena, present, operation, resolution),
    };
    var changed = false;
    var first: ?*const Node = null;
    for (values[0..3]) |node| {
        if (first == null) {
            first = node;
        } else {
            changed = changed or !equal(first, node);
        }
    }
    const rows = try arena.alloc(Row, 1);
    rows[0] = .{
        .path = try arena.dupe(properties.Segment, &.{.{ .key = "m_Father" }}),
        .label = try core.displayPropertyPath(arena, "m_Father"),
        .values = values,
        .changed = changed,
    };
    return .{ .documents = @splat(null), .rows = rows };
}

fn fatherResultNode(
    arena: std.mem.Allocator,
    plan: *const core.merge.MergePlan,
    operation: *const core.merge.Operation,
    resolution: core.merge.Resolution,
) !?*const Node {
    return switch (resolution) {
        .take => |side| try fatherLabelNode(arena, plan, side, operation.values.get(side)),
        .custom => |text| try fatherCustomNode(arena, plan, text),
        .unresolved, .remove => null,
    };
}

fn fatherCustomNode(
    arena: std.mem.Allocator,
    plan: *const core.merge.MergePlan,
    text: []const u8,
) !?*const Node {
    const file = if (plan.ours.documents.len != 0) plan.ours else plan.theirs;
    const wrapped = try std.fmt.allocPrint(arena, "father: {s}\n", .{text});
    const document = properties.parse(arena, wrapped) catch return try scalarNode(arena, text);
    const node = document.node(&.{.{ .key = "father" }}) orelse return try scalarNode(arena, text);
    const ref = Node.asRef(node) orelse return try scalarNode(arena, text);
    return try scalarNode(arena, try fatherDisplay(arena, file, ref));
}

fn fatherLabelNode(
    arena: std.mem.Allocator,
    plan: *const core.merge.MergePlan,
    side: core.merge.Side,
    value: ?core.merge.SideValue,
) !?*const Node {
    const present = value orelse return null;
    const ref = Node.asRef(present.node) orelse {
        if (present.node) |node| return try scalarNode(arena, try valueText(arena, node));
        return try scalarNode(arena, present.bytes);
    };
    return try scalarNode(arena, try fatherDisplay(arena, plan.file(side), ref));
}

fn fatherDisplay(arena: std.mem.Allocator, file: core.source.ParsedFile, ref: core.model.Ref) ![]const u8 {
    if (ref.file_id == 0) return "None";
    const object = gameObjectForRef(file, ref) orelse
        return try std.fmt.allocPrint(arena, "#{d}", .{ref.file_id});
    const name = Node.asScalar(object.body.get("m_Name")) orelse "(GameObject)";
    if (gameObjectNameCount(file, name) <= 1) return name;
    return try objectPath(arena, file, object);
}

fn gameObjectForRef(file: core.source.ParsedFile, ref: core.model.Ref) ?*const core.model.Document {
    const document = documentByFileId(file, ref.file_id) orelse return null;
    if (document.class_id == 1) return document;
    if (document.class_id != 4 and document.class_id != 224) return null;
    const owner = Node.asRef(document.body.get("m_GameObject")) orelse return null;
    const object = documentByFileId(file, owner.file_id) orelse return null;
    return if (object.class_id == 1) object else null;
}

fn documentByFileId(file: core.source.ParsedFile, file_id: i64) ?*const core.model.Document {
    for (file.documents) |*document| {
        if (document.file_id == file_id) return document;
    }
    return null;
}

fn gameObjectNameCount(file: core.source.ParsedFile, name: []const u8) usize {
    var count: usize = 0;
    for (file.documents) |document| {
        if (document.class_id != 1) continue;
        const current = Node.asScalar(document.body.get("m_Name")) orelse continue;
        if (std.mem.eql(u8, current, name)) count += 1;
    }
    return count;
}

fn objectPath(
    arena: std.mem.Allocator,
    file: core.source.ParsedFile,
    object: *const core.model.Document,
) ![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var current: ?*const core.model.Document = object;
    var guard: usize = 0;
    while (current) |present| : (guard += 1) {
        if (guard > 64) break;
        try names.append(arena, Node.asScalar(present.body.get("m_Name")) orelse "(GameObject)");
        const transform = transformForGameObject(file, present.file_id) orelse break;
        const father = Node.asRef(transform.body.get("m_Father")) orelse break;
        if (father.file_id == 0) break;
        current = gameObjectForRef(file, father);
        if (current) |parent| {
            if (parent.file_id == present.file_id) break;
        }
    }
    if (names.items.len == 0) return "(GameObject)";
    var i = names.items.len;
    var out: std.ArrayList(u8) = .empty;
    while (i > 0) {
        i -= 1;
        if (out.items.len != 0) try out.appendSlice(arena, " / ");
        try out.appendSlice(arena, names.items[i]);
    }
    return out.toOwnedSlice(arena);
}

fn transformForGameObject(file: core.source.ParsedFile, object_id: i64) ?*const core.model.Document {
    for (file.documents) |*document| {
        if (document.class_id != 4 and document.class_id != 224) continue;
        const owner = Node.asRef(document.body.get("m_GameObject")) orelse continue;
        if (owner.file_id == object_id) return document;
    }
    return null;
}

fn customFieldRoot(
    arena: std.mem.Allocator,
    operation: *const core.merge.Operation,
    text: []const u8,
) !?*const Node {
    const template = operation.values.theirs orelse operation.values.ours orelse operation.values.base orelse return null;
    const node = template.node orelse return null;
    if (node.* != .map) return null;
    const scalar = customFieldScalar(text) orelse return null;
    const entries = try arena.dupe(core.model.Entry, node.map);
    for (entries) |*entry| {
        if (std.mem.eql(u8, entry.key, "value") or std.mem.eql(u8, entry.key, "second")) {
            const value_node = try arena.create(Node);
            value_node.* = .{ .scalar = scalar };
            entry.value = value_node;
        }
    }
    const copy = try arena.create(Node);
    copy.* = .{ .map = entries };
    return copy;
}

fn customFieldScalar(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \r\n");
    if (trimmed.len == 0) return null;
    if (std.mem.indexOfAny(u8, trimmed, "\r\n") == null) return trimmed;
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    var found: ?[]const u8 = null;
    while (lines.next()) |raw| {
        const content = std.mem.trimStart(u8, std.mem.trimEnd(u8, raw, "\r"), " ");
        if (std.mem.startsWith(u8, content, "value:")) {
            found = std.mem.trim(u8, content["value:".len..], " ");
        }
    }
    return found;
}

fn scalarNode(arena: std.mem.Allocator, text: []const u8) !*const Node {
    const node = try arena.create(Node);
    node.* = .{ .scalar = text };
    return node;
}

const Builder = struct {
    arena: std.mem.Allocator,
    documents: [4]?properties.Document,
    rows: std.ArrayList(Row) = .empty,

    fn walk(self: *Builder, path: []const properties.Segment, label: []const u8, nodes: [4]?*const Node) std.mem.Allocator.Error!void {
        var map_only = true;
        var seq_only = true;
        var has_map = false;
        var has_seq = false;
        for (nodes) |node| if (node) |value| {
            map_only = map_only and value.* == .map;
            seq_only = seq_only and value.* == .seq;
            has_map = has_map or value.* == .map;
            has_seq = has_seq or value.* == .seq;
        };
        const mixed = !map_only and !seq_only and (has_map or has_seq);
        if (mixed) try self.append(path, label, nodes);
        var descendants = false;
        if (has_map) {
            var keys: std.StringHashMapUnmanaged(void) = .empty;
            for (nodes) |node| if (node) |value| {
                if (value.* != .map) continue;
                for (value.map) |entry| {
                    const found = try keys.getOrPut(self.arena, entry.key);
                    if (found.found_existing) continue;
                    if (path.len == 0 and core.isHiddenPropertyPath(entry.key)) continue;
                    var children: [4]?*const Node = @splat(null);
                    for (nodes, 0..) |parent, i| if (parent) |present| {
                        if (present.* == .map) children[i] = present.get(entry.key);
                    };
                    const child_path = try std.mem.concat(self.arena, properties.Segment, &.{ path, &.{.{ .key = entry.key }} });
                    const child_label = if (std.mem.indexOfAny(u8, entry.key, ".[]\"") != null)
                        try std.fmt.allocPrint(self.arena, "{s}[{s}]", .{ label, try std.json.Stringify.valueAlloc(self.arena, entry.key, .{}) })
                    else
                        try std.fmt.allocPrint(self.arena, "{s}{s}{s}", .{ label, if (label.len == 0) "" else ".", try core.displayPropertyPath(self.arena, entry.key) });
                    try self.walk(child_path, child_label, children);
                }
            };
            descendants = keys.count() != 0;
        }
        if (has_seq) {
            var count: usize = 0;
            for (nodes) |node| if (node) |value| {
                if (value.* == .seq) count = @max(count, value.seq.len);
            };
            for (0..count) |index| {
                var children: [4]?*const Node = @splat(null);
                for (nodes, 0..) |parent, i| if (parent) |value| {
                    if (value.* == .seq and index < value.seq.len) children[i] = value.seq[index];
                };
                const child_path = try std.mem.concat(self.arena, properties.Segment, &.{ path, &.{.{ .index = index }} });
                try self.walk(child_path, try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ label, index }), children);
            }
            descendants = descendants or count != 0;
        }
        if (!mixed and !descendants) try self.append(path, label, nodes);
    }

    fn append(self: *Builder, path: []const properties.Segment, label: []const u8, nodes: [4]?*const Node) !void {
        if (path.len == 0) return;
        var compared = false;
        var first: ?*const Node = null;
        var any_document = false;
        for (self.documents) |document| if (document != null) {
            any_document = true;
        };
        var changed = if (any_document) self.documents[0] == null else false;
        if (any_document) {
            for (nodes, self.documents) |node, document| {
                // A removed component is one existence change, not a change to every unchanged property.
                if (document == null) continue;
                if (compared) {
                    changed = changed or !equal(first, node);
                } else {
                    first = node;
                    compared = true;
                }
            }
        } else {
            for (nodes) |node| {
                if (compared) {
                    changed = changed or !equal(first, node);
                } else {
                    first = node;
                    compared = true;
                }
            }
        }
        try self.rows.append(self.arena, .{ .path = path, .label = label, .values = nodes, .changed = changed });
    }
};

fn equal(a: ?*const Node, b: ?*const Node) bool {
    if (a == null or b == null) return a == null and b == null;
    return Node.eql(a.?, b.?);
}

pub fn valueText(arena: std.mem.Allocator, node: ?*const Node) ![]const u8 {
    const value = node orelse return "—";
    return switch (value.*) {
        .scalar => |text| if (text.len == 0) "<empty>" else text,
        .ref => |ref| switch (display.refDisplay(ref, null)) {
            .none => "None",
            .path, .builtin => |name| name,
            .guid => |guid| try std.fmt.allocPrint(arena, "guid:{s} #{d}", .{ guid, ref.file_id }),
            .file_id => |id| try std.fmt.allocPrint(arena, "#{d}", .{id}),
        },
        .map => |entries| try std.fmt.allocPrint(arena, "{d} fields", .{entries.len}),
        .seq => |items| try std.fmt.allocPrint(arena, "{d} items", .{items.len}),
    };
}
