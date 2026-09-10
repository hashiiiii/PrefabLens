const std = @import("std");
const merge_model = @import("merge_model.zig");
const model = @import("model.zig");
const Node = model.Node;
const testing = std.testing;

pub const Assets = std.StringHashMapUnmanaged([]const u8);

pub fn isTransformClass(class_id: u32) bool {
    return class_id == 4 or class_id == 224;
}

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
            const path = Node.asScalar(item.get("propertyPath")) orelse continue;
            const target = Node.asRef(item.get("target"));
            return Modification.init(
                target,
                path,
                item.get("value"),
                item.get("objectReference"),
            );
        }
        return null;
    }
};

pub fn modifications(doc: *const model.Document) ModificationIterator {
    const modification = doc.body.get("m_Modification") orelse return .{ .items = &.{} };
    if (modification.* != .map) return .{ .items = &.{} };
    const list = modification.get("m_Modifications") orelse return .{ .items = &.{} };
    if (list.* != .seq) return .{ .items = &.{} };
    return .{ .items = list.seq };
}

pub const Override = struct {
    kind: merge_model.PrefabOverrideKind,
    target: ?model.Ref,
    property_path: []const u8 = "",
    object: ?model.Ref = null,
    item: *const model.Node,
};

pub const OverrideIterator = struct {
    fields: []const model.Entry,
    field_index: usize = 0,
    item_index: usize = 0,

    pub fn next(self: *OverrideIterator) ?Override {
        while (self.field_index < self.fields.len) {
            const field = self.fields[self.field_index];
            const kind = overrideKind(field.key) orelse {
                self.field_index += 1;
                self.item_index = 0;
                continue;
            };
            if (field.value.* != .seq or self.item_index >= field.value.seq.len) {
                self.field_index += 1;
                self.item_index = 0;
                continue;
            }
            const item = field.value.seq[self.item_index];
            self.item_index += 1;
            return overrideItem(kind, item);
        }
        return null;
    }
};

pub fn overrides(doc: *const model.Document) OverrideIterator {
    const modification = doc.body.get("m_Modification") orelse
        return .{ .fields = &.{} };
    if (modification.* != .map) return .{ .fields = &.{} };
    return .{ .fields = modification.map };
}

fn overrideKind(field: []const u8) ?merge_model.PrefabOverrideKind {
    if (std.mem.eql(u8, field, "m_Modifications")) return .property;
    if (std.mem.eql(u8, field, "m_AddedComponents")) return .added_component;
    if (std.mem.eql(u8, field, "m_RemovedComponents")) return .removed_component;
    if (std.mem.eql(u8, field, "m_AddedGameObjects")) return .added_game_object;
    if (std.mem.eql(u8, field, "m_RemovedGameObjects")) return .removed_game_object;
    return null;
}

pub fn overrideItem(kind: merge_model.PrefabOverrideKind, item: *const model.Node) Override {
    if (kind == .removed_component or kind == .removed_game_object) {
        const removed = Node.asRef(item);
        return .{ .kind = kind, .target = removed, .object = removed, .item = item };
    }
    if (kind == .property) {
        const path = item.get("propertyPath");
        return .{
            .kind = kind,
            .target = Node.asRef(item.get("target")),
            .property_path = Node.asScalar(path) orelse "",
            .object = Node.asRef(setObjectReference(item.get("objectReference"))),
            .item = item,
        };
    }
    return .{
        .kind = kind,
        .target = Node.asRef(item.get("targetCorrespondingSourceObject")),
        .object = Node.asRef(item.get("addedObject")),
        .item = item,
    };
}

fn setObjectReference(node: ?*Node) ?*Node {
    const value_node = node orelse return null;
    return switch (value_node.*) {
        .ref => |value| if (value.file_id != 0 or value.guid != null) value_node else null,
        else => null,
    };
}

pub fn sourceGuid(doc: *const model.Document) ?[]const u8 {
    const source = Node.asRef(doc.body.get("m_SourcePrefab")) orelse return null;
    return source.guid;
}

pub fn scalarModificationValue(doc: *const model.Document, property_path: []const u8) ?[]const u8 {
    var target_file_id: ?i64 = null;
    var result: ?[]const u8 = null;
    var iterator = modifications(doc);
    while (iterator.next()) |modification| {
        if (!std.mem.eql(u8, modification.property_path, property_path)) continue;
        const value = modification.value orelse continue;
        if (target_file_id == null) target_file_id = modification.targetFileId();
        if (modification.targetFileId() == target_file_id.?) result = value.asScalar();
    }
    return result;
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

test "prefab: scalar lookup keeps the first target and its last duplicate" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const docs = try @import("parser.zig").parse(arena_state.allocator(),
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 8, guid: source-guid, type: 3}
        \\      propertyPath: m_Name
        \\      value: First
        \\    - target: {fileID: 8, guid: source-guid, type: 3}
        \\      propertyPath: m_Name
        \\      value: Last
        \\    - target: {fileID: 9, guid: source-guid, type: 3}
        \\      propertyPath: m_Name
        \\      value: Other target
    );

    // The first target identifies the instance. Only its later duplicate may replace the name.
    try testing.expectEqualStrings("Last", scalarModificationValue(&docs[0], "m_Name").?);
}

test "prefab: override iterator keeps source order for all kinds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const documents = try @import("parser.zig").parse(arena_state.allocator(),
        \\--- !u!1001 &100100000
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_RemovedGameObjects:
        \\    - {fileID: 5, guid: source, type: 3}
        \\    m_Modifications:
        \\    - target: {fileID: 1, guid: source, type: 3}
        \\      propertyPath: m_Name
        \\      value: Root
        \\      objectReference: {fileID: 0}
        \\    m_AddedComponents:
        \\    - targetCorrespondingSourceObject: {fileID: 2, guid: source, type: 3}
        \\      insertIndex: -1
        \\      addedObject: {fileID: 3}
        \\    m_RemovedComponents:
        \\    - {fileID: 4, guid: source, type: 3}
        \\    m_AddedGameObjects:
        \\    - targetCorrespondingSourceObject: {fileID: 6, guid: source, type: 3}
        \\      insertIndex: -1
        \\      addedObject: {fileID: 7}
    );
    var iterator = overrides(&documents[0]);
    const kinds = [_]@import("merge_model.zig").PrefabOverrideKind{
        .removed_game_object,
        .property,
        .added_component,
        .removed_component,
        .added_game_object,
    };
    const objects = [_]?i64{ 5, null, 3, 4, 7 };
    for (kinds, objects) |kind, object| {
        const override = iterator.next().?;
        try testing.expectEqual(kind, override.kind);
        try testing.expectEqual(object, if (override.object) |value| value.file_id else null);
    }
    try testing.expect(iterator.next() == null);
}
