const std = @import("std");
const merge_model = @import("merge_model.zig");
const model = @import("model.zig");
const prefab = @import("prefab.zig");
const source = @import("source.zig");

const testing = std.testing;

pub const Index = struct {
    documents: std.AutoHashMapUnmanaged(merge_model.DocumentId, *const model.Document),

    pub fn init(arena: std.mem.Allocator, parsed: source.ParsedFile) merge_model.Error!Index {
        try rejectDuplicateDocuments(arena, parsed.documents);
        var documents: std.AutoHashMapUnmanaged(merge_model.DocumentId, *const model.Document) = .empty;
        for (parsed.documents) |*parsed_document| {
            try documents.put(arena, documentId(parsed_document.*), parsed_document);
        }
        return .{ .documents = documents };
    }

    pub fn document(self: *const Index, id: merge_model.DocumentId) ?*const model.Document {
        return self.documents.get(id);
    }
};

pub fn documentId(document: model.Document) merge_model.DocumentId {
    return .{ .class_id = document.class_id, .file_id = document.file_id };
}

pub fn refEql(a: merge_model.RefId, b: merge_model.RefId) bool {
    if (a.file_id != b.file_id or a.type_id != b.type_id) return false;
    if (a.guid == null or b.guid == null) return a.guid == null and b.guid == null;
    return std.mem.eql(u8, a.guid.?, b.guid.?);
}

pub fn rejectDuplicateDocuments(
    arena: std.mem.Allocator,
    documents: []const model.Document,
) merge_model.Error!void {
    var identifiers: std.AutoHashMapUnmanaged(merge_model.DocumentId, void) = .empty;
    for (documents) |document| {
        const result = try identifiers.getOrPut(arena, documentId(document));
        if (result.found_existing) return error.MalformedInput;
    }
}

pub const SequenceKind = enum {
    components,
    children,
    prefab_properties,
    prefab_added_components,
    prefab_removed_components,
    prefab_added_game_objects,
    prefab_removed_game_objects,
};

pub fn sequenceKind(class_id: u32, property_path: []const u8) ?SequenceKind {
    if (class_id == 1 and std.mem.eql(u8, property_path, "m_Component")) return .components;
    if ((class_id == 4 or class_id == 224) and std.mem.eql(u8, property_path, "m_Children")) return .children;
    if (class_id != 1001) return null;
    if (std.mem.eql(u8, property_path, "m_Modification.m_Modifications")) return .prefab_properties;
    if (std.mem.eql(u8, property_path, "m_Modification.m_AddedComponents")) return .prefab_added_components;
    if (std.mem.eql(u8, property_path, "m_Modification.m_RemovedComponents")) return .prefab_removed_components;
    if (std.mem.eql(u8, property_path, "m_Modification.m_AddedGameObjects")) return .prefab_added_game_objects;
    if (std.mem.eql(u8, property_path, "m_Modification.m_RemovedGameObjects")) return .prefab_removed_game_objects;
    return null;
}

pub const SequenceItemId = struct {
    target: merge_model.RefId,
    property_path: ?[]const u8 = null,
    added_object: ?merge_model.RefId = null,
    override_kind: ?merge_model.PrefabOverrideKind = null,
};

pub fn sequenceItemId(kind: SequenceKind, item: *const model.Node) ?SequenceItemId {
    return switch (kind) {
        .components => itemFileIdField(item, "component"),
        .children => directFileId(item),
        .prefab_properties => propertyOverride(item),
        .prefab_added_components => addedOverride(item, .added_component),
        .prefab_removed_components => directReference(item, .removed_component),
        .prefab_added_game_objects => addedOverride(item, .added_game_object),
        .prefab_removed_game_objects => directReference(item, .removed_game_object),
    };
}

fn itemFileIdField(item: *const model.Node, field: []const u8) ?SequenceItemId {
    if (item.* != .map) return null;
    return directFileId(model.findValue(item.map, field) orelse return null);
}

fn directFileId(item: *const model.Node) ?SequenceItemId {
    const target = prefab.reference(item) orelse return null;
    return .{ .target = .{ .file_id = target.file_id, .guid = null, .type_id = null } };
}

fn propertyOverride(item: *const model.Node) ?SequenceItemId {
    if (item.* != .map) return null;
    const target = refId(prefab.reference(model.findValue(item.map, "target")) orelse return null);
    const path = model.findValue(item.map, "propertyPath") orelse return null;
    if (path.* != .scalar) return null;
    return .{
        .target = target,
        .property_path = path.scalar,
        .override_kind = .property,
    };
}

fn addedOverride(item: *const model.Node, kind: merge_model.PrefabOverrideKind) ?SequenceItemId {
    if (item.* != .map) return null;
    const target = refId(prefab.reference(model.findValue(item.map, "targetCorrespondingSourceObject")) orelse return null);
    const added_object = refId(prefab.reference(model.findValue(item.map, "addedObject")) orelse return null);
    return .{
        .target = target,
        .added_object = added_object,
        .override_kind = kind,
    };
}

fn directReference(
    item: *const model.Node,
    override_kind: ?merge_model.PrefabOverrideKind,
) ?SequenceItemId {
    const target = prefab.reference(item) orelse return null;
    return .{ .target = refId(target), .override_kind = override_kind };
}

fn refId(value: model.Ref) merge_model.RefId {
    return .{ .file_id = value.file_id, .guid = value.guid, .type_id = value.type_id };
}

test "merge identity: document and references use stable Unity identifiers" {
    const id = documentId(.{ .class_id = 4, .file_id = 900, .type_name = "Transform", .body = undefined });
    try testing.expectEqual(@as(u32, 4), id.class_id);
    try testing.expectEqual(@as(i64, 900), id.file_id);

    const a = merge_model.RefId{ .file_id = 7, .guid = "aaa", .type_id = 3 };
    const b = merge_model.RefId{ .file_id = 7, .guid = "bbb", .type_id = 3 };
    try testing.expect(!refEql(a, b));
}

test "merge identity: index finds a document by class and file identifier" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = try @import("parser.zig").parseSpanned(arena, "--- !u!1 &7\nGameObject:\n  m_Name: Player\n");
    const index = try Index.init(arena, parsed);

    const document = index.document(.{ .class_id = 1, .file_id = 7 }).?;

    try testing.expectEqualStrings("GameObject", document.type_name);
}

test "merge identity: known sequences use Unity reference fields" {
    var component_ref = model.Node{ .ref = .{ .file_id = 42, .guid = "not-identity", .type_id = 3 } };
    var component_entries = [_]model.Entry{.{ .key = "component", .value = &component_ref }};
    var component = model.Node{ .map = &component_entries };
    const component_id = sequenceItemId(.components, &component).?;
    try testing.expectEqual(@as(i64, 42), component_id.target.file_id);
    try testing.expect(component_id.target.guid == null);
    try testing.expect(component_id.target.type_id == null);
    try testing.expect(component_id.override_kind == null);

    var target = model.Node{ .ref = .{ .file_id = 7, .guid = "aaa", .type_id = 3 } };
    var added = model.Node{ .ref = .{ .file_id = 8, .guid = "bbb", .type_id = 3 } };
    var added_entries = [_]model.Entry{
        .{ .key = "targetCorrespondingSourceObject", .value = &target },
        .{ .key = "addedObject", .value = &added },
    };
    var added_item = model.Node{ .map = &added_entries };
    const added_id = sequenceItemId(.prefab_added_components, &added_item).?;
    try testing.expectEqual(@as(i64, 7), added_id.target.file_id);
    try testing.expectEqual(@as(i64, 8), added_id.added_object.?.file_id);
    try testing.expectEqual(merge_model.PrefabOverrideKind.added_component, added_id.override_kind.?);
}

test "merge identity: every Prefab sequence uses its semantic fields" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const documents = try @import("parser.zig").parse(arena,
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 1, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: Player
        \\    m_AddedComponents:
        \\    - targetCorrespondingSourceObject: {fileID: 2, guid: aaa, type: 3}
        \\      addedObject: {fileID: 3}
        \\    m_RemovedComponents:
        \\    - {fileID: 4, guid: aaa, type: 3}
        \\    m_AddedGameObjects:
        \\    - targetCorrespondingSourceObject: {fileID: 5, guid: aaa, type: 3}
        \\      addedObject: {fileID: 6}
        \\    m_RemovedGameObjects:
        \\    - {fileID: 7, guid: aaa, type: 3}
    );
    const modification = model.findValue(documents[0].body.map, "m_Modification").?.map;

    const property = sequenceItemId(
        .prefab_properties,
        model.findValue(modification, "m_Modifications").?.seq[0],
    ).?;
    try testing.expectEqualStrings("m_Name", property.property_path.?);
    try testing.expectEqual(merge_model.PrefabOverrideKind.property, property.override_kind.?);

    const cases = [_]struct {
        field: []const u8,
        kind: SequenceKind,
        target: i64,
        added_object: ?i64,
        override_kind: merge_model.PrefabOverrideKind,
    }{
        .{ .field = "m_AddedComponents", .kind = .prefab_added_components, .target = 2, .added_object = 3, .override_kind = .added_component },
        .{ .field = "m_RemovedComponents", .kind = .prefab_removed_components, .target = 4, .added_object = null, .override_kind = .removed_component },
        .{ .field = "m_AddedGameObjects", .kind = .prefab_added_game_objects, .target = 5, .added_object = 6, .override_kind = .added_game_object },
        .{ .field = "m_RemovedGameObjects", .kind = .prefab_removed_game_objects, .target = 7, .added_object = null, .override_kind = .removed_game_object },
    };
    for (cases) |case| {
        const item = model.findValue(modification, case.field).?.seq[0];
        const identity = sequenceItemId(case.kind, item).?;
        try testing.expectEqual(case.target, identity.target.file_id);
        try testing.expectEqual(case.added_object, if (identity.added_object) |added_object| added_object.file_id else null);
        try testing.expectEqual(case.override_kind, identity.override_kind.?);
    }

    var child = model.Node{ .ref = .{ .file_id = 8 } };
    try testing.expectEqual(@as(i64, 8), sequenceItemId(.children, &child).?.target.file_id);
}

test "merge identity: sequence classification uses class and property path" {
    try testing.expectEqual(SequenceKind.components, sequenceKind(1, "m_Component").?);
    try testing.expectEqual(SequenceKind.children, sequenceKind(224, "m_Children").?);
    try testing.expectEqual(SequenceKind.prefab_properties, sequenceKind(1001, "m_Modification.m_Modifications").?);
    try testing.expect(sequenceKind(114, "m_Component") == null);
    try testing.expect(sequenceKind(1001, "m_Unknown") == null);
}
