const std = @import("std");
const model = @import("model.zig");
const Node = model.Node;
const testing = std.testing;

pub const Assets = std.StringHashMapUnmanaged([]const u8);

pub const Modification = struct {
    target: ?model.Ref,
    property_path: []const u8,
    value: ?*Node,
    object_reference: ?*Node,

    pub fn init(target: ?model.Ref, property_path: []const u8, value: ?*Node, raw_object_reference: ?*Node) Modification {
        return .{
            .target = target,
            .property_path = property_path,
            .value = value,
            .object_reference = setObjectReference(raw_object_reference),
        };
    }

    pub fn targetFileId(self: Modification) i64 {
        return if (self.target) |target| target.file_id else 0;
    }

    pub fn effectiveValue(self: Modification) ?*Node {
        return self.object_reference orelse self.value;
    }

    pub fn key(self: Modification, arena: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        return std.fmt.allocPrint(arena, "{d}:{s}", .{ self.targetFileId(), self.property_path });
    }
};

pub const ModificationIterator = struct {
    items: []*Node,
    index: usize = 0,

    pub fn next(self: *ModificationIterator) ?Modification {
        while (self.index < self.items.len) {
            const item = self.items[self.index];
            self.index += 1;
            if (item.* != .map) continue;
            const path = model.findValue(item.map, "propertyPath") orelse continue;
            if (path.* != .scalar) continue;
            const target = if (model.findValue(item.map, "target")) |node|
                switch (node.*) {
                    .ref => |value| value,
                    else => null,
                }
            else
                null;
            return Modification.init(
                target,
                path.scalar,
                model.findValue(item.map, "value"),
                model.findValue(item.map, "objectReference"),
            );
        }
        return null;
    }
};

pub fn modifications(doc: *const model.Document) ModificationIterator {
    const modification = model.findValue(doc.body.map, "m_Modification") orelse return .{ .items = &.{} };
    if (modification.* != .map) return .{ .items = &.{} };
    const list = model.findValue(modification.map, "m_Modifications") orelse return .{ .items = &.{} };
    if (list.* != .seq) return .{ .items = &.{} };
    return .{ .items = list.seq };
}

fn setObjectReference(node: ?*Node) ?*Node {
    const reference = node orelse return null;
    return switch (reference.*) {
        .ref => |value| if (value.file_id != 0 or value.guid != null) reference else null,
        else => null,
    };
}

pub fn sourceGuid(doc: *const model.Document) ?[]const u8 {
    const source = model.findValue(doc.body.map, "m_SourcePrefab") orelse return null;
    return switch (source.*) {
        .ref => |value| value.guid,
        else => null,
    };
}

pub fn scalarModificationValue(doc: *const model.Document, property_path: []const u8) ?[]const u8 {
    var iterator = modifications(doc);
    while (iterator.next()) |modification| {
        if (!std.mem.eql(u8, modification.property_path, property_path)) continue;
        const value = modification.value orelse continue;
        return switch (value.*) {
            .scalar => |scalar| scalar,
            else => null,
        };
    }
    return null;
}

test "prefab: modifications skip malformed entries in source order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const docs = try @import("parser.zig").parse(arena,
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - invalid
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      value: missing-path
        \\    - target: {fileID: 8, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: First
        \\    - target: {fileID: 9, guid: aaa, type: 3}
        \\      propertyPath: maxHp
        \\      value: 100
    );

    var iterator = modifications(&docs[0]);
    const first = iterator.next().?;
    const second = iterator.next().?;
    try testing.expectEqual(@as(i64, 8), first.targetFileId());
    try testing.expectEqualStrings("m_Name", first.property_path);
    try testing.expectEqual(@as(i64, 9), second.targetFileId());
    try testing.expectEqualStrings("maxHp", second.property_path);
    try testing.expect(iterator.next() == null);
}

test "prefab: effective value prefers a set object reference" {
    var scalar = Node{ .scalar = "100" };
    var empty_ref = Node{ .ref = .{ .file_id = 0 } };
    var set_ref = Node{ .ref = .{ .file_id = 42 } };

    const scalar_mod = Modification.init(null, "value", &scalar, &empty_ref);
    const ref_mod = Modification.init(null, "reference", &scalar, &set_ref);
    try testing.expect(scalar_mod.effectiveValue() == &scalar);
    try testing.expect(ref_mod.effectiveValue() == &set_ref);
}

test "prefab: source and scalar lookups keep serialized values" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const docs = try @import("parser.zig").parse(arena_state.allocator(),
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 8, guid: source-guid, type: 3}
        \\      propertyPath: m_Name
        \\      value: Cylinder
        \\  m_SourcePrefab: {fileID: 100100000, guid: source-guid, type: 3}
    );

    try testing.expectEqualStrings("source-guid", sourceGuid(&docs[0]).?);
    try testing.expectEqualStrings("Cylinder", scalarModificationValue(&docs[0], "m_Name").?);
}
