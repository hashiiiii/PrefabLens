const std = @import("std");
const merge_identity = @import("merge_identity.zig");
const merge_order = @import("merge_order.zig");
const merge_model = @import("merge_model.zig");
const model = @import("model.zig");
const parser = @import("parser.zig");
const source = @import("source.zig");

const testing = std.testing;

test {
    _ = merge_order;
}

const Decision = enum { ours, theirs, common, conflict };

const DocumentNodes = struct {
    base: ?*const model.Node,
    ours: ?*const model.Node,
    theirs: ?*const model.Node,
};

const SequenceItem = struct {
    id: []const u8,
    identity: merge_identity.SequenceItemId,
    node: *const model.Node,
};

const SequenceItems = struct {
    base: []const SequenceItem,
    ours: []const SequenceItem,
    theirs: []const SequenceItem,
};

const SelectedItem = struct {
    side: merge_model.Side,
    node: *const model.Node,
};

const ComponentOwnerIndexes = struct {
    base: merge_identity.ComponentOwnerIndex,
    ours: merge_identity.ComponentOwnerIndex,
    theirs: merge_identity.ComponentOwnerIndex,
};

pub const GameObjectBundle = struct {
    game_object: merge_model.DocumentId,
    transform: merge_model.DocumentId,
    components: []const merge_model.DocumentId,
    component_items: []const merge_model.SemanticId,
    parent_child_item: ?merge_model.SemanticId,
    father_field: merge_model.SemanticId,
};

pub const ReparentChange = struct {
    child: merge_model.DocumentId,
    old_parent: ?merge_model.DocumentId,
    new_parent: ?merge_model.DocumentId,
    father_field: merge_model.SemanticId,
    old_parent_item: ?merge_model.SemanticId,
    new_parent_item: ?merge_model.SemanticId,
};

const MergeIndexes = struct {
    base: merge_identity.Index,
    ours: merge_identity.Index,
    theirs: merge_identity.Index,
};

pub fn build(
    arena: std.mem.Allocator,
    base: source.ParsedFile,
    ours: source.ParsedFile,
    theirs: source.ParsedFile,
) merge_model.Error!merge_model.MergePlan {
    try validateMergeSide(arena, base);
    try validateMergeSide(arena, ours);
    try validateMergeSide(arena, theirs);

    var operations: std.ArrayList(merge_model.Operation) = .empty;
    var atomic_operations: std.ArrayList(merge_model.AtomicOperation) = .empty;
    const component_owners = ComponentOwnerIndexes{
        .base = try merge_identity.componentOwners(arena, base.documents),
        .ours = try merge_identity.componentOwners(arena, ours.documents),
        .theirs = try merge_identity.componentOwners(arena, theirs.documents),
    };
    try validateComponentOwners(base, component_owners.base);
    try validateComponentOwners(ours, component_owners.ours);
    try validateComponentOwners(theirs, component_owners.theirs);
    const indexes = MergeIndexes{
        .base = try merge_identity.Index.init(arena, base),
        .ours = try merge_identity.Index.init(arena, ours),
        .theirs = try merge_identity.Index.init(arena, theirs),
    };

    for (base.documents) |base_document| {
        const ours_document = findDocument(ours.documents, base_document.class_id, base_document.file_id) orelse continue;
        const theirs_document = findDocument(theirs.documents, base_document.class_id, base_document.file_id) orelse continue;
        try collectMapFields(
            arena,
            &operations,
            &atomic_operations,
            .{ .class_id = base_document.class_id, .file_id = base_document.file_id },
            ours_document.type_name,
            "",
            .{
                .base = base_document.body,
                .ours = ours_document.body,
                .theirs = theirs_document.body,
            },
            base,
            ours,
            theirs,
            component_owners,
        );
    }

    try collectGameObjectOperations(
        arena,
        &operations,
        &atomic_operations,
        base,
        ours,
        theirs,
        indexes,
    );
    try collectReparentOperations(
        arena,
        &operations,
        &atomic_operations,
        indexes,
    );

    return .{
        .base = base,
        .ours = ours,
        .theirs = theirs,
        .operations = try operations.toOwnedSlice(arena),
        .atomic_operations = try atomic_operations.toOwnedSlice(arena),
    };
}

fn collectReparentOperations(
    arena: std.mem.Allocator,
    operations: *std.ArrayList(merge_model.Operation),
    atomic_operations: *std.ArrayList(merge_model.AtomicOperation),
    indexes: MergeIndexes,
) merge_model.Error!void {
    var document_iterator = indexes.base.documents.iterator();
    while (document_iterator.next()) |entry| {
        const document = entry.value_ptr.*;
        if (document.class_id != 4 and document.class_id != 224) continue;
        const child = merge_identity.documentId(document.*);
        if (indexes.ours.document(child) == null or indexes.theirs.document(child) == null) continue;
        const base_parent = try transformParent(&indexes.base, child);
        const ours_parent = try transformParent(&indexes.ours, child);
        const theirs_parent = try transformParent(&indexes.theirs, child);
        if (std.meta.eql(base_parent, ours_parent) and std.meta.eql(base_parent, theirs_parent)) continue;
        const ours_change = if (std.meta.eql(base_parent, ours_parent)) null else makeReparentChange(child, base_parent, ours_parent);
        const theirs_change = if (std.meta.eql(base_parent, theirs_parent)) null else makeReparentChange(child, base_parent, theirs_parent);

        const father_identity = merge_model.SemanticId{
            .document = child,
            .property_path = "m_Father",
        };
        const father_operation_id = findOperationBySemantic(
            operations.items,
            father_identity,
            .field,
        ) orelse return error.InvalidMerge;
        const atomic_id = operations.items[father_operation_id].atomic_id;
        var operation_ids: std.ArrayList(merge_model.OperationId) = .empty;
        try operation_ids.append(arena, father_operation_id);

        var membership_identities: std.ArrayList(merge_model.SemanticId) = .empty;
        for ([_]?ReparentChange{ ours_change, theirs_change }) |optional_change| {
            const change = optional_change orelse continue;
            if (change.old_parent_item) |identity| {
                try appendUniqueSemanticId(arena, &membership_identities, identity);
            }
            if (change.new_parent_item) |identity| {
                try appendUniqueSemanticId(arena, &membership_identities, identity);
            }
        }
        for (membership_identities.items) |identity| {
            const membership_id = findOperationBySemantic(
                operations.items,
                identity,
                .sequence_membership,
            ) orelse return error.InvalidMerge;
            try adoptOperation(arena, operations, atomic_operations, membership_id, atomic_id);
            try operation_ids.append(arena, membership_id);
        }
        if (operation_ids.items.len < 2) return error.InvalidMerge;

        const resolution: merge_model.Resolution = switch (decideReparent(
            base_parent,
            ours_parent,
            theirs_parent,
        )) {
            .ours, .common => .{ .take = .ours },
            .theirs => .{ .take = .theirs },
            .conflict => .unresolved,
        };
        for (operation_ids.items) |operation_id| {
            operations.items[operation_id].resolution = resolution;
        }
        operations.items[father_operation_id].kind = .reparent;
        atomic_operations.items[atomic_id] = .{
            .id = atomic_id,
            .kind = .reparent,
            .operation_ids = try operation_ids.toOwnedSlice(arena),
        };
    }
}

fn makeReparentChange(
    child: merge_model.DocumentId,
    old_parent: ?merge_model.DocumentId,
    new_parent: ?merge_model.DocumentId,
) ReparentChange {
    return .{
        .child = child,
        .old_parent = old_parent,
        .new_parent = new_parent,
        .father_field = .{ .document = child, .property_path = "m_Father" },
        .old_parent_item = if (old_parent) |parent| .{
            .document = parent,
            .property_path = "m_Children",
            .item_ref = .{ .file_id = child.file_id, .guid = null, .type_id = null },
        } else null,
        .new_parent_item = if (new_parent) |parent| .{
            .document = parent,
            .property_path = "m_Children",
            .item_ref = .{ .file_id = child.file_id, .guid = null, .type_id = null },
        } else null,
    };
}

fn transformParent(
    index: *const merge_identity.Index,
    child: merge_model.DocumentId,
) merge_model.Error!?merge_model.DocumentId {
    const document = index.document(child) orelse return error.UnsupportedStructure;
    const father = model.findValue(document.body.map, "m_Father") orelse return null;
    if (father.* != .ref or father.ref.guid != null) return error.UnsupportedStructure;
    if (father.ref.file_id == 0) return null;
    const parent = try indexedDocumentByFileId(index, father.ref.file_id);
    if (parent.class_id != 4 and parent.class_id != 224) return error.UnsupportedStructure;
    return merge_identity.documentId(parent.*);
}

fn decideReparent(
    base_parent: ?merge_model.DocumentId,
    ours_parent: ?merge_model.DocumentId,
    theirs_parent: ?merge_model.DocumentId,
) Decision {
    if (std.meta.eql(ours_parent, base_parent)) return .theirs;
    if (std.meta.eql(theirs_parent, base_parent)) return .ours;
    if (std.meta.eql(ours_parent, theirs_parent)) return .common;
    return .conflict;
}

pub fn gameObjectBundle(
    arena: std.mem.Allocator,
    index: *const merge_identity.Index,
    game_object_file_id: i64,
) merge_model.Error!GameObjectBundle {
    const game_object = index.document(.{ .class_id = 1, .file_id = game_object_file_id }) orelse
        return error.UnsupportedStructure;
    const component_node = model.findValue(game_object.body.map, "m_Component") orelse
        return error.UnsupportedStructure;
    if (component_node.* != .seq) return error.UnsupportedStructure;

    var components: std.ArrayList(merge_model.DocumentId) = .empty;
    var component_items: std.ArrayList(merge_model.SemanticId) = .empty;
    var transform: ?merge_model.DocumentId = null;
    for (component_node.seq) |item| {
        const item_id = merge_identity.sequenceItemId(.components, item) orelse
            return error.UnsupportedStructure;
        const component = try indexedDocumentByFileId(index, item_id.target.file_id);
        const component_id = merge_identity.documentId(component.*);
        if (component.class_id == 4 or component.class_id == 224) {
            if (transform != null) return error.InvalidMerge;
            transform = component_id;
        } else {
            try components.append(arena, component_id);
        }
        try component_items.append(arena, .{
            .document = merge_identity.documentId(game_object.*),
            .property_path = "m_Component",
            .item_ref = item_id.target,
        });
    }
    const transform_id = transform orelse return error.UnsupportedStructure;
    const transform_document = index.document(transform_id) orelse return error.UnsupportedStructure;
    const father = model.findValue(transform_document.body.map, "m_Father") orelse
        return error.UnsupportedStructure;
    if (father.* != .ref or father.ref.guid != null) return error.UnsupportedStructure;

    var parent_child_item: ?merge_model.SemanticId = null;
    if (father.ref.file_id != 0) {
        const parent = try indexedDocumentByFileId(index, father.ref.file_id);
        if (parent.class_id != 4 and parent.class_id != 224) return error.UnsupportedStructure;
        const children = model.findValue(parent.body.map, "m_Children") orelse
            return error.UnsupportedStructure;
        if (children.* != .seq) return error.UnsupportedStructure;
        var matches: usize = 0;
        for (children.seq) |child| {
            const child_id = merge_identity.sequenceItemId(.children, child) orelse
                return error.UnsupportedStructure;
            if (child_id.target.file_id == transform_id.file_id) matches += 1;
        }
        if (matches != 1) return error.InvalidMerge;
        parent_child_item = .{
            .document = merge_identity.documentId(parent.*),
            .property_path = "m_Children",
            .item_ref = .{ .file_id = transform_id.file_id, .guid = null, .type_id = null },
        };
    }
    return .{
        .game_object = merge_identity.documentId(game_object.*),
        .transform = transform_id,
        .components = try components.toOwnedSlice(arena),
        .component_items = try component_items.toOwnedSlice(arena),
        .parent_child_item = parent_child_item,
        .father_field = .{ .document = transform_id, .property_path = "m_Father" },
    };
}

fn indexedDocumentByFileId(
    index: *const merge_identity.Index,
    file_id: i64,
) merge_model.Error!*const model.Document {
    var found: ?*const model.Document = null;
    var iterator = index.documents.iterator();
    while (iterator.next()) |entry| {
        if (entry.key_ptr.file_id != file_id) continue;
        if (found != null) return error.InvalidMerge;
        found = entry.value_ptr.*;
    }
    return found orelse error.UnsupportedStructure;
}

const SubtreeBundles = struct {
    base: []const GameObjectBundle,
    ours: []const GameObjectBundle,
    theirs: []const GameObjectBundle,
};

fn collectGameObjectOperations(
    arena: std.mem.Allocator,
    operations: *std.ArrayList(merge_model.Operation),
    atomic_operations: *std.ArrayList(merge_model.AtomicOperation),
    base: source.ParsedFile,
    ours: source.ParsedFile,
    theirs: source.ParsedFile,
    indexes: MergeIndexes,
) merge_model.Error!void {
    var game_object_ids: std.ArrayList(i64) = .empty;
    var seen: std.AutoHashMapUnmanaged(i64, void) = .empty;
    inline for (.{ base, ours, theirs }) |file| {
        for (file.documents) |document| {
            if (document.class_id != 1) continue;
            const entry = try seen.getOrPut(arena, document.file_id);
            if (!entry.found_existing) try game_object_ids.append(arena, document.file_id);
        }
    }

    for (game_object_ids.items) |game_object_file_id| {
        const presence = .{
            indexes.base.document(.{ .class_id = 1, .file_id = game_object_file_id }) != null,
            indexes.ours.document(.{ .class_id = 1, .file_id = game_object_file_id }) != null,
            indexes.theirs.document(.{ .class_id = 1, .file_id = game_object_file_id }) != null,
        };
        if (presence[0] == presence[1] and presence[0] == presence[2]) continue;
        if (!gameObjectChangeHasFather(indexes, game_object_file_id)) continue;
        if (try changedGameObjectParent(arena, indexes, game_object_file_id)) continue;
        const bundles = SubtreeBundles{
            .base = if (presence[0]) try gameObjectSubtree(arena, &indexes.base, game_object_file_id) else &.{},
            .ours = if (presence[1]) try gameObjectSubtree(arena, &indexes.ours, game_object_file_id) else &.{},
            .theirs = if (presence[2]) try gameObjectSubtree(arena, &indexes.theirs, game_object_file_id) else &.{},
        };
        var decision = decideGameObject(
            base,
            ours,
            theirs,
            bundles,
        );
        if (bundles.base.len == 0 and (subtreeCollidesWithFile(base, bundles.ours) or
            subtreeCollidesWithFile(base, bundles.theirs))) decision = .conflict;
        try appendGameObjectAtomic(
            arena,
            operations,
            atomic_operations,
            base,
            ours,
            theirs,
            bundles,
            decision,
        );
    }
}

fn subtreeCollidesWithFile(
    file: source.ParsedFile,
    bundles: []const GameObjectBundle,
) bool {
    for (bundles) |bundle| {
        if (fileIdExists(file, bundle.game_object.file_id)) return true;
        if (fileIdExists(file, bundle.transform.file_id)) return true;
        for (bundle.components) |component| {
            if (fileIdExists(file, component.file_id)) return true;
        }
    }
    return false;
}

fn fileIdExists(file: source.ParsedFile, file_id: i64) bool {
    for (file.documents) |document| if (document.file_id == file_id) return true;
    return false;
}

fn changedGameObjectParent(
    arena: std.mem.Allocator,
    indexes: MergeIndexes,
    game_object_file_id: i64,
) merge_model.Error!bool {
    for ([_]*const merge_identity.Index{ &indexes.base, &indexes.ours, &indexes.theirs }) |index| {
        if (index.document(.{ .class_id = 1, .file_id = game_object_file_id }) == null) continue;
        const bundle = try gameObjectBundle(arena, index, game_object_file_id);
        const parent_item = bundle.parent_child_item orelse return false;
        const parent_transform = index.document(parent_item.document) orelse return error.UnsupportedStructure;
        const parent_game_object = model.findValue(parent_transform.body.map, "m_GameObject") orelse
            return error.UnsupportedStructure;
        if (parent_game_object.* != .ref or parent_game_object.ref.guid != null) return error.UnsupportedStructure;
        const parent_file_id = parent_game_object.ref.file_id;
        const base_present = indexes.base.document(.{ .class_id = 1, .file_id = parent_file_id }) != null;
        const ours_present = indexes.ours.document(.{ .class_id = 1, .file_id = parent_file_id }) != null;
        const theirs_present = indexes.theirs.document(.{ .class_id = 1, .file_id = parent_file_id }) != null;
        return base_present != ours_present or base_present != theirs_present;
    }
    return false;
}

fn gameObjectSubtree(
    arena: std.mem.Allocator,
    index: *const merge_identity.Index,
    game_object_file_id: i64,
) merge_model.Error![]const GameObjectBundle {
    var bundles: std.ArrayList(GameObjectBundle) = .empty;
    var visited: std.AutoHashMapUnmanaged(i64, void) = .empty;
    try appendGameObjectSubtree(arena, index, game_object_file_id, &visited, &bundles);
    return bundles.toOwnedSlice(arena);
}

fn appendGameObjectSubtree(
    arena: std.mem.Allocator,
    index: *const merge_identity.Index,
    game_object_file_id: i64,
    visited: *std.AutoHashMapUnmanaged(i64, void),
    bundles: *std.ArrayList(GameObjectBundle),
) merge_model.Error!void {
    const entry = try visited.getOrPut(arena, game_object_file_id);
    if (entry.found_existing) return error.InvalidMerge;
    const bundle = try gameObjectBundle(arena, index, game_object_file_id);
    try bundles.append(arena, bundle);
    const transform = index.document(bundle.transform) orelse return error.UnsupportedStructure;
    const children = model.findValue(transform.body.map, "m_Children") orelse return;
    if (children.* != .seq) return error.UnsupportedStructure;
    for (children.seq) |child_node| {
        if (child_node.* != .ref or child_node.ref.guid != null) return error.UnsupportedStructure;
        const child_transform = try indexedDocumentByFileId(index, child_node.ref.file_id);
        if (child_transform.class_id != 4 and child_transform.class_id != 224)
            return error.UnsupportedStructure;
        const child_game_object = model.findValue(child_transform.body.map, "m_GameObject") orelse
            return error.UnsupportedStructure;
        if (child_game_object.* != .ref or child_game_object.ref.guid != null)
            return error.UnsupportedStructure;
        try appendGameObjectSubtree(
            arena,
            index,
            child_game_object.ref.file_id,
            visited,
            bundles,
        );
    }
}

fn gameObjectChangeHasFather(indexes: MergeIndexes, game_object_file_id: i64) bool {
    for ([_]*const merge_identity.Index{ &indexes.base, &indexes.ours, &indexes.theirs }) |index| {
        const game_object = index.document(.{ .class_id = 1, .file_id = game_object_file_id }) orelse continue;
        const components = model.findValue(game_object.body.map, "m_Component") orelse continue;
        if (components.* != .seq) continue;
        for (components.seq) |item| {
            const item_id = merge_identity.sequenceItemId(.components, item) orelse continue;
            var iterator = index.documents.iterator();
            while (iterator.next()) |entry| {
                const component = entry.value_ptr.*;
                if (component.file_id != item_id.target.file_id or
                    (component.class_id != 4 and component.class_id != 224)) continue;
                if (model.findValue(component.body.map, "m_Father") != null) return true;
            }
        }
    }
    return false;
}

fn decideGameObject(
    base: source.ParsedFile,
    ours: source.ParsedFile,
    theirs: source.ParsedFile,
    bundles: SubtreeBundles,
) Decision {
    if (equalBundleLists(ours, bundles.ours, base, bundles.base)) return .theirs;
    if (equalBundleLists(theirs, bundles.theirs, base, bundles.base)) return .ours;
    if (equalBundleLists(ours, bundles.ours, theirs, bundles.theirs)) return .common;
    return .conflict;
}

fn equalBundleLists(
    a_file: source.ParsedFile,
    a: []const GameObjectBundle,
    b_file: source.ParsedFile,
    b: []const GameObjectBundle,
) bool {
    if (a.len != b.len) return false;
    for (a) |a_bundle| {
        const b_bundle = for (b) |candidate| {
            if (std.meta.eql(a_bundle.game_object, candidate.game_object)) break candidate;
        } else return false;
        if (!equalBundles(a_file, a_bundle, b_file, b_bundle)) return false;
    }
    return true;
}

fn equalBundles(
    a_file: source.ParsedFile,
    a: GameObjectBundle,
    b_file: source.ParsedFile,
    b: GameObjectBundle,
) bool {
    const a_bundle = a;
    const b_bundle = b;
    if (!std.meta.eql(a_bundle.game_object, b_bundle.game_object) or
        !std.meta.eql(a_bundle.transform, b_bundle.transform) or
        a_bundle.components.len != b_bundle.components.len) return false;
    if (!equalDocumentBodies(a_file, a_bundle.game_object, b_file, b_bundle.game_object) or
        !equalDocumentBodies(a_file, a_bundle.transform, b_file, b_bundle.transform)) return false;
    for (a_bundle.components, b_bundle.components) |a_component, b_component| {
        if (!std.meta.eql(a_component, b_component) or
            !equalDocumentBodies(a_file, a_component, b_file, b_component)) return false;
    }
    return true;
}

fn equalDocumentBodies(
    a_file: source.ParsedFile,
    a_id: merge_model.DocumentId,
    b_file: source.ParsedFile,
    b_id: merge_model.DocumentId,
) bool {
    const a = findDocument(a_file.documents, a_id.class_id, a_id.file_id) orelse return false;
    const b = findDocument(b_file.documents, b_id.class_id, b_id.file_id) orelse return false;
    return model.Node.eql(a.body, b.body);
}

fn appendGameObjectAtomic(
    arena: std.mem.Allocator,
    operations: *std.ArrayList(merge_model.Operation),
    atomic_operations: *std.ArrayList(merge_model.AtomicOperation),
    base: source.ParsedFile,
    ours: source.ParsedFile,
    theirs: source.ParsedFile,
    bundles: SubtreeBundles,
    decision: Decision,
) merge_model.Error!void {
    const atomic_id: merge_model.AtomicId = @intCast(atomic_operations.items.len);
    try atomic_operations.append(arena, .{
        .id = atomic_id,
        .kind = .game_object,
        .operation_ids = &.{},
    });
    var operation_ids: std.ArrayList(merge_model.OperationId) = .empty;
    var document_ids: std.ArrayList(merge_model.DocumentId) = .empty;
    var semantic_ids: std.ArrayList(merge_model.SemanticId) = .empty;
    var transform_file_ids: std.ArrayList(i64) = .empty;
    inline for (.{ bundles.base, bundles.ours, bundles.theirs }) |side_bundles| {
        for (side_bundles) |bundle| {
            try appendUniqueDocumentId(arena, &document_ids, bundle.game_object);
            try appendUniqueDocumentId(arena, &document_ids, bundle.transform);
            if (!containsFileId(transform_file_ids.items, bundle.transform.file_id)) {
                try transform_file_ids.append(arena, bundle.transform.file_id);
            }
            for (bundle.components) |component| try appendUniqueDocumentId(arena, &document_ids, component);
            for (bundle.component_items) |item| try appendUniqueSemanticId(arena, &semantic_ids, item);
            if (bundle.parent_child_item) |item| try appendUniqueSemanticId(arena, &semantic_ids, item);
            try appendUniqueSemanticId(arena, &semantic_ids, bundle.father_field);
        }
    }
    for (operations.items) |operation| {
        if (operation.kind != .sequence_membership or
            !std.mem.eql(u8, operation.property_path, "m_Children")) continue;
        const target = operation.identity.item_ref orelse continue;
        if (!containsFileId(transform_file_ids.items, target.file_id)) continue;
        try appendUniqueSemanticId(arena, &semantic_ids, operation.identity);
    }
    const resolution = resolutionForSubtree(decision, bundles.ours, bundles.theirs);
    for (document_ids.items) |document_id| {
        try operations.append(arena, .{
            .id = @intCast(operations.items.len),
            .atomic_id = atomic_id,
            .kind = .game_object,
            .identity = .{ .document = document_id, .property_path = "" },
            .hierarchy_path = documentTypeName(base, ours, theirs, document_id),
            .property_path = "",
            .values = .{
                .base = documentValue(base, findDocumentPointer(base.documents, document_id)),
                .ours = documentValue(ours, findDocumentPointer(ours.documents, document_id)),
                .theirs = documentValue(theirs, findDocumentPointer(theirs.documents, document_id)),
            },
            .resolution = resolution,
        });
        try operation_ids.append(arena, @intCast(operations.items.len - 1));
    }
    for (semantic_ids.items) |semantic_id| {
        if (findOperationBySemantic(operations.items, semantic_id, .sequence_membership)) |operation_id| {
            try adoptOperation(
                arena,
                operations,
                atomic_operations,
                operation_id,
                atomic_id,
            );
            operations.items[operation_id].resolution = resolution;
            try operation_ids.append(arena, operation_id);
            continue;
        }
        try operations.append(arena, .{
            .id = @intCast(operations.items.len),
            .atomic_id = atomic_id,
            .kind = if (semantic_id.item_ref == null) .sequence_content else .sequence_membership,
            .identity = semantic_id,
            .hierarchy_path = documentTypeName(base, ours, theirs, semantic_id.document),
            .property_path = semantic_id.property_path,
            .values = .{
                .base = semanticValue(base, semantic_id),
                .ours = semanticValue(ours, semantic_id),
                .theirs = semanticValue(theirs, semantic_id),
            },
            .resolution = resolution,
        });
        try operation_ids.append(arena, @intCast(operations.items.len - 1));
    }
    atomic_operations.items[atomic_id].operation_ids = try operation_ids.toOwnedSlice(arena);
}

fn resolutionForSubtree(
    decision: Decision,
    ours: []const GameObjectBundle,
    theirs: []const GameObjectBundle,
) merge_model.Resolution {
    return switch (decision) {
        .ours, .common => if (ours.len == 0) .remove else .{ .take = .ours },
        .theirs => if (theirs.len == 0) .remove else .{ .take = .theirs },
        .conflict => .unresolved,
    };
}

fn appendUniqueDocumentId(
    arena: std.mem.Allocator,
    ids: *std.ArrayList(merge_model.DocumentId),
    id: merge_model.DocumentId,
) std.mem.Allocator.Error!void {
    for (ids.items) |candidate| if (std.meta.eql(candidate, id)) return;
    try ids.append(arena, id);
}

fn containsFileId(ids: []const i64, file_id: i64) bool {
    for (ids) |candidate| if (candidate == file_id) return true;
    return false;
}

fn appendUniqueSemanticId(
    arena: std.mem.Allocator,
    ids: *std.ArrayList(merge_model.SemanticId),
    id: merge_model.SemanticId,
) std.mem.Allocator.Error!void {
    for (ids.items) |candidate| if (semanticIdEql(candidate, id)) return;
    try ids.append(arena, id);
}

fn semanticIdEql(a: merge_model.SemanticId, b: merge_model.SemanticId) bool {
    if (!std.meta.eql(a.document, b.document) or
        !std.mem.eql(u8, a.property_path, b.property_path) or
        a.override_kind != b.override_kind) return false;
    if (a.item_ref == null or b.item_ref == null) return a.item_ref == null and b.item_ref == null;
    return merge_identity.refEql(a.item_ref.?, b.item_ref.?);
}

fn findOperationBySemantic(
    operations: []const merge_model.Operation,
    identity: merge_model.SemanticId,
    kind: merge_model.OperationKind,
) ?merge_model.OperationId {
    for (operations) |operation| {
        if (operation.kind == kind and semanticIdEql(operation.identity, identity)) return operation.id;
    }
    return null;
}

fn adoptOperation(
    arena: std.mem.Allocator,
    operations: *std.ArrayList(merge_model.Operation),
    atomic_operations: *std.ArrayList(merge_model.AtomicOperation),
    operation_id: merge_model.OperationId,
    atomic_id: merge_model.AtomicId,
) merge_model.Error!void {
    const operation = &operations.items[operation_id];
    const previous_atomic_id = operation.atomic_id;
    if (previous_atomic_id == atomic_id) return;
    const previous_atomic = &atomic_operations.items[previous_atomic_id];
    var remaining: std.ArrayList(merge_model.OperationId) = .empty;
    for (previous_atomic.operation_ids) |candidate| {
        if (candidate != operation_id) try remaining.append(arena, candidate);
    }
    previous_atomic.operation_ids = try remaining.toOwnedSlice(arena);
    previous_atomic.kind = atomicKindForOperations(operations.items, previous_atomic.operation_ids);
    try appendAtomicDependency(arena, previous_atomic, atomic_id);
    operation.atomic_id = atomic_id;
}

fn appendAtomicDependency(
    arena: std.mem.Allocator,
    atomic: *merge_model.AtomicOperation,
    dependency: merge_model.AtomicId,
) std.mem.Allocator.Error!void {
    for (atomic.dependencies) |candidate| if (candidate == dependency) return;
    const dependencies = try arena.alloc(merge_model.AtomicId, atomic.dependencies.len + 1);
    @memcpy(dependencies[0..atomic.dependencies.len], atomic.dependencies);
    dependencies[atomic.dependencies.len] = dependency;
    atomic.dependencies = dependencies;
}

fn atomicKindForOperations(
    operations: []const merge_model.Operation,
    operation_ids: []const merge_model.OperationId,
) merge_model.OperationKind {
    for (operation_ids) |operation_id| if (operations[operation_id].kind == .sequence_membership)
        return .sequence_membership;
    for (operation_ids) |operation_id| if (operations[operation_id].kind == .sequence_content)
        return .sequence_content;
    return .sequence_order;
}

fn findDocumentPointer(
    documents: []const model.Document,
    id: merge_model.DocumentId,
) ?*const model.Document {
    for (documents) |*document| {
        if (document.class_id == id.class_id and document.file_id == id.file_id) return document;
    }
    return null;
}

fn documentTypeName(
    base: source.ParsedFile,
    ours: source.ParsedFile,
    theirs: source.ParsedFile,
    id: merge_model.DocumentId,
) []const u8 {
    inline for (.{ ours, base, theirs }) |file| {
        if (findDocumentPointer(file.documents, id)) |document| return document.type_name;
    }
    return "";
}

fn semanticValue(
    file: source.ParsedFile,
    identity: merge_model.SemanticId,
) ?merge_model.SideValue {
    const document = findDocumentPointer(file.documents, identity.document) orelse return null;
    var node = document.body;
    var path = std.mem.splitScalar(u8, identity.property_path, '.');
    while (path.next()) |field| {
        if (field.len == 0) continue;
        if (node.* != .map) return null;
        node = model.findValue(node.map, field) orelse return null;
    }
    const item_ref = identity.item_ref orelse return sideValue(file, node);
    if (node.* != .seq) return null;
    for (node.seq) |item| {
        const kind = merge_identity.sequenceKind(identity.document.class_id, identity.property_path) orelse
            return null;
        const item_id = merge_identity.sequenceItemId(kind, item) orelse return null;
        if (!merge_identity.refEql(item_id.target, item_ref)) continue;
        const span = file.sequence_item_spans.get(item) orelse return null;
        return .{ .node = item, .bytes = span.bytes(file.bytes), .span = span };
    }
    return null;
}

fn validateComponentOwners(
    file: source.ParsedFile,
    owners: merge_identity.ComponentOwnerIndex,
) merge_model.Error!void {
    var owner_iterator = owners.iterator();
    while (owner_iterator.next()) |entry| {
        const document = findDocumentByFileId(file.documents, entry.key_ptr.*) orelse
            return error.UnsupportedStructure;
        const game_object = model.findValue(document.body.map, "m_GameObject") orelse
            return error.UnsupportedStructure;
        if (game_object.* != .ref or game_object.ref.file_id != entry.value_ptr.*) {
            return error.UnsupportedStructure;
        }
    }
    for (file.documents) |*document| {
        const game_object = model.findValue(document.body.map, "m_GameObject") orelse continue;
        if (game_object.* != .ref) return error.UnsupportedStructure;
        const owner = owners.get(document.file_id) orelse return error.UnsupportedStructure;
        if (owner != game_object.ref.file_id) return error.UnsupportedStructure;
    }
}

fn collectMapFields(
    arena: std.mem.Allocator,
    operations: *std.ArrayList(merge_model.Operation),
    atomic_operations: *std.ArrayList(merge_model.AtomicOperation),
    document_id: merge_model.DocumentId,
    hierarchy_path: []const u8,
    parent_path: []const u8,
    nodes: DocumentNodes,
    base_file: source.ParsedFile,
    ours_file: source.ParsedFile,
    theirs_file: source.ParsedFile,
    component_owners: ComponentOwnerIndexes,
) merge_model.Error!void {
    const base_entries = mapEntries(nodes.base);
    const ours_entries = mapEntries(nodes.ours);
    const theirs_entries = mapEntries(nodes.theirs);

    for (base_entries) |entry| {
        try collectField(
            arena,
            operations,
            atomic_operations,
            document_id,
            hierarchy_path,
            parent_path,
            entry.key,
            .{
                .base = entry.value,
                .ours = findValueConst(ours_entries, entry.key),
                .theirs = findValueConst(theirs_entries, entry.key),
            },
            base_file,
            ours_file,
            theirs_file,
            component_owners,
        );
    }
    for (ours_entries) |entry| {
        if (findValueConst(base_entries, entry.key) != null) continue;
        try collectField(
            arena,
            operations,
            atomic_operations,
            document_id,
            hierarchy_path,
            parent_path,
            entry.key,
            .{
                .base = null,
                .ours = entry.value,
                .theirs = findValueConst(theirs_entries, entry.key),
            },
            base_file,
            ours_file,
            theirs_file,
            component_owners,
        );
    }
    for (theirs_entries) |entry| {
        if (findValueConst(base_entries, entry.key) != null or findValueConst(ours_entries, entry.key) != null) continue;
        try collectField(
            arena,
            operations,
            atomic_operations,
            document_id,
            hierarchy_path,
            parent_path,
            entry.key,
            .{ .base = null, .ours = null, .theirs = entry.value },
            base_file,
            ours_file,
            theirs_file,
            component_owners,
        );
    }
}

fn collectField(
    arena: std.mem.Allocator,
    operations: *std.ArrayList(merge_model.Operation),
    atomic_operations: *std.ArrayList(merge_model.AtomicOperation),
    document_id: merge_model.DocumentId,
    hierarchy_path: []const u8,
    parent_path: []const u8,
    key: []const u8,
    nodes: DocumentNodes,
    base_file: source.ParsedFile,
    ours_file: source.ParsedFile,
    theirs_file: source.ParsedFile,
    component_owners: ComponentOwnerIndexes,
) merge_model.Error!void {
    const property_path = if (parent_path.len == 0)
        try arena.dupe(u8, key)
    else
        try std.fmt.allocPrint(arena, "{s}.{s}", .{ parent_path, key });

    if (hasMap(nodes)) {
        if (hasNonMap(nodes)) return error.UnsupportedStructure;
        return collectMapFields(
            arena,
            operations,
            atomic_operations,
            document_id,
            hierarchy_path,
            property_path,
            nodes,
            base_file,
            ours_file,
            theirs_file,
            component_owners,
        );
    }
    if (hasSequence(nodes)) {
        if (equalOptional(nodes.base, nodes.ours) and equalOptional(nodes.base, nodes.theirs)) return;
        const sequence_kind = merge_identity.sequenceKind(document_id.class_id, property_path) orelse
            return error.UnsupportedStructure;
        switch (sequence_kind) {
            .components, .children => {},
            else => return error.UnsupportedStructure,
        }
        return collectSequence(
            arena,
            operations,
            atomic_operations,
            document_id,
            hierarchy_path,
            property_path,
            sequence_kind,
            nodes,
            base_file,
            ours_file,
            theirs_file,
            component_owners,
        );
    }
    if (equalOptional(nodes.base, nodes.ours) and equalOptional(nodes.base, nodes.theirs)) return;

    const decision = decide(nodes.base, nodes.ours, nodes.theirs);
    const resolution: merge_model.Resolution = switch (decision) {
        .ours, .common => if (nodes.ours == null) .remove else .{ .take = .ours },
        .theirs => if (nodes.theirs == null) .remove else .{ .take = .theirs },
        .conflict => .unresolved,
    };
    const operation_id: merge_model.OperationId = @intCast(operations.items.len);
    const atomic_id: merge_model.AtomicId = @intCast(atomic_operations.items.len);
    try operations.append(arena, .{
        .id = operation_id,
        .atomic_id = atomic_id,
        .kind = .field,
        .identity = .{ .document = document_id, .property_path = property_path },
        .hierarchy_path = hierarchy_path,
        .property_path = property_path,
        .values = .{
            .base = sideValue(base_file, nodes.base),
            .ours = sideValue(ours_file, nodes.ours),
            .theirs = sideValue(theirs_file, nodes.theirs),
        },
        .resolution = resolution,
    });
    const ids = try arena.alloc(merge_model.OperationId, 1);
    ids[0] = operation_id;
    try atomic_operations.append(arena, .{
        .id = atomic_id,
        .kind = .field,
        .operation_ids = ids,
    });
}

fn collectSequence(
    arena: std.mem.Allocator,
    operations: *std.ArrayList(merge_model.Operation),
    atomic_operations: *std.ArrayList(merge_model.AtomicOperation),
    document_id: merge_model.DocumentId,
    hierarchy_path: []const u8,
    property_path: []const u8,
    kind: merge_identity.SequenceKind,
    nodes: DocumentNodes,
    base_file: source.ParsedFile,
    ours_file: source.ParsedFile,
    theirs_file: source.ParsedFile,
    component_owners: ComponentOwnerIndexes,
) merge_model.Error!void {
    const items = SequenceItems{
        .base = try identifiedItems(arena, kind, nodes.base),
        .ours = try identifiedItems(arena, kind, nodes.ours),
        .theirs = try identifiedItems(arena, kind, nodes.theirs),
    };
    const all_ids = try unionIds(arena, items);
    const sequence_atomic_id: merge_model.AtomicId = @intCast(atomic_operations.items.len);
    try atomic_operations.append(arena, .{
        .id = sequence_atomic_id,
        .kind = .sequence_order,
        .operation_ids = &.{},
    });
    var sequence_operation_ids: std.ArrayList(merge_model.OperationId) = .empty;
    var component_atomic_ids: std.ArrayList(merge_model.AtomicId) = .empty;
    var sequence_has_conflict = false;
    var has_sequence_item_change = false;
    var final_ids: std.ArrayList([]const u8) = .empty;

    for (all_ids) |id| {
        const base_item = findSequenceItem(items.base, id);
        const ours_item = findSequenceItem(items.ours, id);
        const theirs_item = findSequenceItem(items.theirs, id);
        const membership = decidePresence(base_item != null, ours_item != null, theirs_item != null);
        var selected = selectedItem(base_item, ours_item, theirs_item, membership);
        const delete_edit = base_item != null and ((ours_item == null and theirs_item != null and
            !model.Node.eql(base_item.?.node, theirs_item.?.node)) or
            (theirs_item == null and ours_item != null and !model.Node.eql(base_item.?.node, ours_item.?.node)));

        if (!samePresence(base_item, ours_item, theirs_item)) {
            if (kind == .components) {
                const component_atomic_id: merge_model.AtomicId = @intCast(atomic_operations.items.len);
                const component_operation_start = operations.items.len;
                try appendSequenceOperation(
                    arena,
                    operations,
                    component_atomic_id,
                    .sequence_membership,
                    document_id,
                    hierarchy_path,
                    property_path,
                    base_file,
                    ours_file,
                    theirs_file,
                    base_item,
                    ours_item,
                    theirs_item,
                    if (delete_edit) .unresolved else resolutionForPresence(membership, ours_item, theirs_item),
                );
                var component_has_conflict = delete_edit;
                if (try appendComponentDocumentOperation(
                    arena,
                    operations,
                    component_atomic_id,
                    document_id.file_id,
                    base_item,
                    ours_item,
                    theirs_item,
                    base_file,
                    ours_file,
                    theirs_file,
                    component_owners,
                )) component_has_conflict = true;
                const component_operation_ids = try arena.alloc(
                    merge_model.OperationId,
                    operations.items.len - component_operation_start,
                );
                for (component_operation_ids, component_operation_start..) |*operation_id, index| {
                    operation_id.* = @intCast(index);
                }
                if (component_has_conflict) {
                    for (operations.items[component_operation_start..]) |*operation| {
                        operation.resolution = .unresolved;
                    }
                }
                try atomic_operations.append(arena, .{
                    .id = component_atomic_id,
                    .kind = .component,
                    .operation_ids = component_operation_ids,
                });
                try component_atomic_ids.append(arena, component_atomic_id);
            } else {
                try appendSequenceOperation(
                    arena,
                    operations,
                    sequence_atomic_id,
                    .sequence_membership,
                    document_id,
                    hierarchy_path,
                    property_path,
                    base_file,
                    ours_file,
                    theirs_file,
                    base_item,
                    ours_item,
                    theirs_item,
                    if (delete_edit) .unresolved else resolutionForPresence(membership, ours_item, theirs_item),
                );
                try sequence_operation_ids.append(arena, @intCast(operations.items.len - 1));
                if (delete_edit) sequence_has_conflict = true;
            }
        }

        if (base_item != null and ours_item != null and theirs_item != null and
            (!model.Node.eql(base_item.?.node, ours_item.?.node) or
                !model.Node.eql(base_item.?.node, theirs_item.?.node)))
        {
            const content_decision = decide(base_item.?.node, ours_item.?.node, theirs_item.?.node);
            if (content_decision == .conflict) sequence_has_conflict = true;
            try appendSequenceOperation(
                arena,
                operations,
                sequence_atomic_id,
                .sequence_content,
                document_id,
                hierarchy_path,
                property_path,
                base_file,
                ours_file,
                theirs_file,
                base_item,
                ours_item,
                theirs_item,
                resolutionForDecision(content_decision, ours_item, theirs_item),
            );
            try sequence_operation_ids.append(arena, @intCast(operations.items.len - 1));
            has_sequence_item_change = true;
            selected = selectedItem(base_item, ours_item, theirs_item, content_decision);
        } else if (base_item == null and ours_item != null and theirs_item != null and
            !model.Node.eql(ours_item.?.node, theirs_item.?.node))
        {
            sequence_has_conflict = true;
            try appendSequenceOperation(
                arena,
                operations,
                sequence_atomic_id,
                .sequence_content,
                document_id,
                hierarchy_path,
                property_path,
                base_file,
                ours_file,
                theirs_file,
                base_item,
                ours_item,
                theirs_item,
                .unresolved,
            );
            try sequence_operation_ids.append(arena, @intCast(operations.items.len - 1));
            has_sequence_item_change = true;
        }

        if (selected != null) try final_ids.append(arena, id);
        if (kind == .children and !childHasFather(
            base_file,
            ours_file,
            theirs_file,
            firstSequenceItem(base_item, ours_item, theirs_item).identity.target.file_id,
        )) {
            const child_operation_start = operations.items.len;
            if (selected) |value| try appendChildDocumentsOperation(
                arena,
                operations,
                sequence_atomic_id,
                value,
                firstSequenceItem(base_item, ours_item, theirs_item).identity.target.file_id,
                base_file,
                ours_file,
                theirs_file,
            );
            for (child_operation_start..operations.items.len) |index| {
                try sequence_operation_ids.append(arena, @intCast(index));
            }
        }
    }

    const base_ids = try presentIds(arena, items.base, final_ids.items);
    const ours_ids = try presentIds(arena, items.ours, final_ids.items);
    const theirs_ids = try presentIds(arena, items.theirs, final_ids.items);
    const order = try merge_order.merge(arena, base_ids, ours_ids, theirs_ids);
    if (order.conflicts.len != 0) sequence_has_conflict = true;
    const merged_bytes = try renderSequence(
        arena,
        order.items,
        items,
        base_file,
        ours_file,
        theirs_file,
        nodes,
    );
    try appendOrderOperation(
        arena,
        operations,
        sequence_atomic_id,
        document_id,
        hierarchy_path,
        property_path,
        nodes,
        base_file,
        ours_file,
        theirs_file,
        merged_bytes,
        sequence_has_conflict,
        kind == .components and component_atomic_ids.items.len != 0 and
            !has_sequence_item_change and sameRetainedOrder(items.ours, order.items),
    );
    try sequence_operation_ids.append(arena, @intCast(operations.items.len - 1));

    const operation_ids = try sequence_operation_ids.toOwnedSlice(arena);
    if (sequence_has_conflict) {
        for (operation_ids) |operation_id| {
            operations.items[operation_id].resolution = .unresolved;
        }
    }
    const atomic_kind: merge_model.OperationKind = for (operation_ids) |operation_id| {
        const operation = operations.items[operation_id];
        if (operation.kind == .sequence_membership) break .sequence_membership;
    } else for (operation_ids) |operation_id| {
        const operation = operations.items[operation_id];
        if (operation.kind == .sequence_content) break .sequence_content;
    } else .sequence_order;
    atomic_operations.items[sequence_atomic_id] = .{
        .id = sequence_atomic_id,
        .kind = atomic_kind,
        .operation_ids = operation_ids,
        .dependencies = try component_atomic_ids.toOwnedSlice(arena),
    };
}

fn childHasFather(
    base: source.ParsedFile,
    ours: source.ParsedFile,
    theirs: source.ParsedFile,
    transform_file_id: i64,
) bool {
    for ([_]source.ParsedFile{ base, ours, theirs }) |file| {
        const transform = findDocumentByFileId(file.documents, transform_file_id) orelse continue;
        if (model.findValue(transform.body.map, "m_Father") != null) return true;
    }
    return false;
}

fn identifiedItems(
    arena: std.mem.Allocator,
    kind: merge_identity.SequenceKind,
    node: ?*const model.Node,
) merge_model.Error![]const SequenceItem {
    const sequence = node orelse return &.{};
    if (sequence.* != .seq) return error.UnsupportedStructure;
    var result: std.ArrayList(SequenceItem) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (sequence.seq) |item| {
        const identity = merge_identity.sequenceItemId(kind, item) orelse return error.UnsupportedStructure;
        const id = try sequenceId(arena, identity);
        const entry = try seen.getOrPut(arena, id);
        if (entry.found_existing) return error.MalformedInput;
        try result.append(arena, .{ .id = id, .identity = identity, .node = item });
    }
    return result.toOwnedSlice(arena);
}

fn sequenceId(arena: std.mem.Allocator, identity: merge_identity.SequenceItemId) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "{d}|{s}|{?d}|{s}|{?d}|{s}|{?d}|{?d}",
        .{
            identity.target.file_id,
            identity.target.guid orelse "",
            identity.target.type_id,
            identity.property_path orelse "",
            if (identity.added_object) |added| added.file_id else null,
            if (identity.added_object) |added| added.guid orelse "" else "",
            if (identity.added_object) |added| added.type_id else null,
            if (identity.override_kind) |override_kind| @intFromEnum(override_kind) else null,
        },
    );
}

fn unionIds(arena: std.mem.Allocator, items: SequenceItems) std.mem.Allocator.Error![]const []const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    inline for (.{ items.base, items.ours, items.theirs }) |side| {
        for (side) |item| {
            const entry = try seen.getOrPut(arena, item.id);
            if (!entry.found_existing) try ids.append(arena, item.id);
        }
    }
    return ids.toOwnedSlice(arena);
}

fn findSequenceItem(items: []const SequenceItem, id: []const u8) ?SequenceItem {
    for (items) |item| if (std.mem.eql(u8, item.id, id)) return item;
    return null;
}

fn decidePresence(base: bool, ours: bool, theirs: bool) Decision {
    if (ours == base) return .theirs;
    if (theirs == base) return .ours;
    if (ours == theirs) return .common;
    return .conflict;
}

fn samePresence(base: ?SequenceItem, ours: ?SequenceItem, theirs: ?SequenceItem) bool {
    return (base != null) == (ours != null) and (base != null) == (theirs != null);
}

fn resolutionForPresence(
    decision: Decision,
    ours: ?SequenceItem,
    theirs: ?SequenceItem,
) merge_model.Resolution {
    return switch (decision) {
        .ours, .common => if (ours == null) .remove else .{ .take = .ours },
        .theirs => if (theirs == null) .remove else .{ .take = .theirs },
        .conflict => .unresolved,
    };
}

fn resolutionForDecision(
    decision: Decision,
    ours: ?SequenceItem,
    theirs: ?SequenceItem,
) merge_model.Resolution {
    return resolutionForPresence(decision, ours, theirs);
}

fn selectedItem(
    base: ?SequenceItem,
    ours: ?SequenceItem,
    theirs: ?SequenceItem,
    decision: Decision,
) ?SelectedItem {
    return switch (decision) {
        .ours, .common => if (ours) |item| .{ .side = .ours, .node = item.node } else null,
        .theirs => if (theirs) |item| .{ .side = .theirs, .node = item.node } else null,
        .conflict => if (ours) |item| .{ .side = .ours, .node = item.node } else if (base) |item|
            .{ .side = .base, .node = item.node }
        else
            null,
    };
}

fn appendSequenceOperation(
    arena: std.mem.Allocator,
    operations: *std.ArrayList(merge_model.Operation),
    atomic_id: merge_model.AtomicId,
    operation_kind: merge_model.OperationKind,
    document_id: merge_model.DocumentId,
    hierarchy_path: []const u8,
    property_path: []const u8,
    base_file: source.ParsedFile,
    ours_file: source.ParsedFile,
    theirs_file: source.ParsedFile,
    base_item: ?SequenceItem,
    ours_item: ?SequenceItem,
    theirs_item: ?SequenceItem,
    resolution: merge_model.Resolution,
) std.mem.Allocator.Error!void {
    const identity = firstSequenceItem(base_item, ours_item, theirs_item).identity;
    try operations.append(arena, .{
        .id = @intCast(operations.items.len),
        .atomic_id = atomic_id,
        .kind = operation_kind,
        .identity = .{ .document = document_id, .property_path = property_path, .item_ref = identity.target },
        .hierarchy_path = hierarchy_path,
        .property_path = property_path,
        .values = .{
            .base = sequenceItemValue(base_file, base_item),
            .ours = sequenceItemValue(ours_file, ours_item),
            .theirs = sequenceItemValue(theirs_file, theirs_item),
        },
        .resolution = resolution,
    });
}

fn sequenceItemValue(file: source.ParsedFile, item: ?SequenceItem) ?merge_model.SideValue {
    const present = item orelse return null;
    const span = file.sequence_item_spans.get(present.node) orelse return null;
    return .{ .node = present.node, .bytes = span.bytes(file.bytes), .span = span };
}

fn firstSequenceItem(base: ?SequenceItem, ours: ?SequenceItem, theirs: ?SequenceItem) SequenceItem {
    if (base) |item| return item;
    if (ours) |item| return item;
    return theirs.?;
}

fn presentIds(
    arena: std.mem.Allocator,
    items: []const SequenceItem,
    selected: []const []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    for (items) |item| {
        for (selected) |id| {
            if (std.mem.eql(u8, item.id, id)) {
                try result.append(arena, item.id);
                break;
            }
        }
    }
    return result.toOwnedSlice(arena);
}

fn sameRetainedOrder(ours: []const SequenceItem, merged: []const []const u8) bool {
    var ours_index: usize = 0;
    var merged_index: usize = 0;
    while (true) {
        while (ours_index < ours.len and !containsId(merged, ours[ours_index].id)) : (ours_index += 1) {}
        while (merged_index < merged.len and findSequenceItem(ours, merged[merged_index]) == null) : (merged_index += 1) {}
        if (ours_index == ours.len or merged_index == merged.len) {
            return ours_index == ours.len and merged_index == merged.len;
        }
        if (!std.mem.eql(u8, ours[ours_index].id, merged[merged_index])) return false;
        ours_index += 1;
        merged_index += 1;
    }
}

fn containsId(ids: []const []const u8, target: []const u8) bool {
    for (ids) |id| if (std.mem.eql(u8, id, target)) return true;
    return false;
}

fn appendOrderOperation(
    arena: std.mem.Allocator,
    operations: *std.ArrayList(merge_model.Operation),
    atomic_id: merge_model.AtomicId,
    document_id: merge_model.DocumentId,
    hierarchy_path: []const u8,
    property_path: []const u8,
    nodes: DocumentNodes,
    base_file: source.ParsedFile,
    ours_file: source.ParsedFile,
    theirs_file: source.ParsedFile,
    merged_bytes: []const u8,
    has_conflict: bool,
    keep_ours: bool,
) std.mem.Allocator.Error!void {
    var ours_value = sequenceSideValue(ours_file, nodes.ours);
    const replacement = if (keep_ours)
        if (ours_value) |value| value.bytes else ""
    else if (!has_conflict)
        try sequenceReplacement(arena, ours_file, nodes.ours, merged_bytes)
    else
        merged_bytes;
    if (!keep_ours and !has_conflict and merged_bytes.len == 0) {
        ours_value = sequenceEmptyPatchValue(ours_file, nodes.ours);
    }
    var theirs_value = sequenceSideValue(theirs_file, nodes.theirs);
    if (!has_conflict or keep_ours) {
        if (theirs_value) |*value| value.bytes = replacement;
    }
    try operations.append(arena, .{
        .id = @intCast(operations.items.len),
        .atomic_id = atomic_id,
        .kind = .sequence_order,
        .identity = .{ .document = document_id, .property_path = property_path },
        .hierarchy_path = hierarchy_path,
        .property_path = property_path,
        .values = .{
            .base = sequenceSideValue(base_file, nodes.base),
            .ours = ours_value,
            .theirs = theirs_value,
        },
        .resolution = if (ours_value != null and std.mem.eql(u8, ours_value.?.bytes, replacement))
            .{ .take = .ours }
        else
            .{ .take = .theirs },
    });
}

fn sequenceSideValue(file: source.ParsedFile, node: ?*const model.Node) ?merge_model.SideValue {
    var value = sideValue(file, node) orelse return null;
    const present = node.?;
    if (present.* == .seq and present.seq.len == 0 and value.span.?.start > 0 and
        file.bytes[value.span.?.start - 1] == ' ')
    {
        value.span.?.start -= 1;
        value.bytes = value.span.?.bytes(file.bytes);
    }
    return value;
}

fn renderSequence(
    arena: std.mem.Allocator,
    order: []const []const u8,
    items: SequenceItems,
    base_file: source.ParsedFile,
    ours_file: source.ParsedFile,
    theirs_file: source.ParsedFile,
    nodes: DocumentNodes,
) merge_model.Error![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    const destination_indent = sequenceIndent(ours_file, nodes.ours) orelse
        sequenceFieldIndent(ours_file, nodes.ours) orelse
        sequenceIndent(base_file, nodes.base) orelse
        sequenceFieldIndent(base_file, nodes.base) orelse
        sequenceIndent(theirs_file, nodes.theirs) orelse
        sequenceFieldIndent(theirs_file, nodes.theirs) orelse 0;
    for (order, 0..) |id, index| {
        const base_item = findSequenceItem(items.base, id);
        const ours_item = findSequenceItem(items.ours, id);
        const theirs_item = findSequenceItem(items.theirs, id);
        var selected = selectedItem(base_item, ours_item, theirs_item, decidePresence(
            base_item != null,
            ours_item != null,
            theirs_item != null,
        )) orelse continue;
        if (base_item != null and ours_item != null and theirs_item != null) {
            selected = selectedItem(base_item, ours_item, theirs_item, decide(
                base_item.?.node,
                ours_item.?.node,
                theirs_item.?.node,
            )) orelse selected;
        }
        const selected_file = switch (selected.side) {
            .base => base_file,
            .ours => ours_file,
            .theirs => theirs_file,
        };
        const bytes = selected_file.sequenceItemBytes(selected.node) orelse return error.UnsupportedStructure;
        if (selected.side == .ours) {
            try output.appendSlice(arena, bytes);
        } else {
            const offset = insertionOffsetForItem(ours_file, items.ours, order, index, nodes.ours);
            try output.appendSlice(arena, try reindentSequenceItem(
                arena,
                bytes,
                destination_indent,
                ours_file.lineEndingAt(offset),
            ));
        }
        try appendOursGap(arena, &output, ours_file, items.ours, id);
    }
    return output.toOwnedSlice(arena);
}

pub fn sequenceReplacement(
    arena: std.mem.Allocator,
    ours_file: source.ParsedFile,
    ours_node: ?*const model.Node,
    merged_bytes: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const node = ours_node orelse return merged_bytes;
    if (merged_bytes.len == 0) {
        if (node.* != .seq or node.seq.len == 0) {
            return if (sequenceSideValue(ours_file, node)) |value| value.bytes else "[]";
        }
        const span = ours_file.node_spans.get(node) orelse return " []";
        const source_bytes = span.bytes(ours_file.bytes);
        if (std.mem.endsWith(u8, source_bytes, "\r\n")) return " []\r\n";
        if (std.mem.endsWith(u8, source_bytes, "\n")) return " []\n";
        return " []";
    }
    if (node.* != .seq or node.seq.len != 0) return merged_bytes;
    const span = ours_file.node_spans.get(node) orelse return merged_bytes;
    const line_ending = ours_file.lineEndingAt(span.end);
    const item_bytes = if (std.mem.endsWith(u8, merged_bytes, line_ending))
        merged_bytes[0 .. merged_bytes.len - line_ending.len]
    else
        merged_bytes;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ line_ending, item_bytes });
}

fn sequenceEmptyPatchValue(file: source.ParsedFile, node: ?*const model.Node) ?merge_model.SideValue {
    var value = sequenceSideValue(file, node) orelse return null;
    const sequence = node.?;
    if (sequence.* != .seq or sequence.seq.len == 0) return value;
    const entry = file.entry_spans.get(sequence) orelse return value;
    const span = file.node_spans.get(sequence) orelse return value;
    if (entry.value.start > span.end) return value;
    value.span = .{ .start = entry.value.start, .end = span.end };
    value.bytes = value.span.?.bytes(file.bytes);
    return value;
}

fn appendOursGap(
    arena: std.mem.Allocator,
    output: *std.ArrayList(u8),
    ours_file: source.ParsedFile,
    ours_items: []const SequenceItem,
    id: []const u8,
) merge_model.Error!void {
    const ours_index = for (ours_items, 0..) |item, index| {
        if (std.mem.eql(u8, item.id, id)) break index;
    } else return;
    if (ours_index + 1 == ours_items.len) return;
    const current_span = ours_file.sequence_item_spans.get(ours_items[ours_index].node) orelse
        return error.UnsupportedStructure;
    const next_item = ours_items[ours_index + 1];
    const next_span = ours_file.sequence_item_spans.get(next_item.node) orelse
        return error.UnsupportedStructure;
    if (next_span.start < current_span.end) return error.UnsupportedStructure;
    const gap = ours_file.bytes[current_span.end..next_span.start];
    try output.appendSlice(arena, gap);
}

fn sequenceIndent(file: source.ParsedFile, node: ?*const model.Node) ?usize {
    const sequence = node orelse return null;
    if (sequence.* != .seq or sequence.seq.len == 0) return null;
    const span = file.sequence_item_spans.get(sequence.seq[0]) orelse return null;
    const end = std.mem.indexOfScalarPos(u8, file.bytes, span.start, '\n') orelse span.end;
    return leadingSpaces(file.bytes[span.start..end]);
}

fn sequenceFieldIndent(file: source.ParsedFile, node: ?*const model.Node) ?usize {
    const sequence = node orelse return null;
    const entry = file.entry_spans.get(sequence) orelse return null;
    const line_start = if (std.mem.lastIndexOfScalar(u8, file.bytes[0..entry.key.start], '\n')) |lf| lf + 1 else 0;
    return entry.key.start - line_start;
}

fn insertionOffsetForItem(
    file: source.ParsedFile,
    ours_items: []const SequenceItem,
    order: []const []const u8,
    index: usize,
    sequence_node: ?*const model.Node,
) usize {
    var previous = index;
    while (previous > 0) {
        previous -= 1;
        if (findSequenceItem(ours_items, order[previous])) |item| {
            if (file.sequence_item_spans.get(item.node)) |span| return span.end;
        }
    }
    var next = index + 1;
    while (next < order.len) : (next += 1) {
        if (findSequenceItem(ours_items, order[next])) |item| {
            if (file.sequence_item_spans.get(item.node)) |span| return span.start;
        }
    }
    if (sequence_node) |node| if (file.node_spans.get(node)) |span| return span.end;
    return file.bytes.len;
}

fn leadingSpaces(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') count += 1;
    return count;
}

pub fn reindentSequenceItem(
    arena: std.mem.Allocator,
    source_item: []const u8,
    destination_indent: usize,
    line_ending: []const u8,
) merge_model.Error![]const u8 {
    const first_lf = std.mem.indexOfScalar(u8, source_item, '\n') orelse source_item.len;
    const first_line = std.mem.trimEnd(u8, source_item[0..first_lf], "\r");
    const source_indent = leadingSpaces(first_line);
    var output: std.ArrayList(u8) = .empty;
    var cursor: usize = 0;
    while (cursor < source_item.len) {
        const relative_lf = std.mem.indexOfScalar(u8, source_item[cursor..], '\n');
        const end = if (relative_lf) |line_index| cursor + line_index else source_item.len;
        const raw_line = source_item[cursor..end];
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const indent = leadingSpaces(line);
        if (line.len != 0 and indent < source_indent) return error.UnsupportedStructure;
        if (line.len != 0) {
            try output.appendNTimes(arena, ' ', destination_indent + indent - source_indent);
            try output.appendSlice(arena, line[indent..]);
        }
        if (relative_lf != null) try output.appendSlice(arena, line_ending);
        cursor = if (relative_lf != null) end + 1 else end;
    }
    return output.toOwnedSlice(arena);
}

fn appendComponentDocumentOperation(
    arena: std.mem.Allocator,
    operations: *std.ArrayList(merge_model.Operation),
    atomic_id: merge_model.AtomicId,
    owner_file_id: i64,
    base_item: ?SequenceItem,
    ours_item: ?SequenceItem,
    theirs_item: ?SequenceItem,
    base_file: source.ParsedFile,
    ours_file: source.ParsedFile,
    theirs_file: source.ParsedFile,
    component_owners: ComponentOwnerIndexes,
) merge_model.Error!bool {
    const file_id = firstSequenceItem(base_item, ours_item, theirs_item).identity.target.file_id;
    const base_document = try componentDocument(
        base_file,
        component_owners.base,
        owner_file_id,
        file_id,
        base_item != null,
    );
    const ours_document = try componentDocument(
        ours_file,
        component_owners.ours,
        owner_file_id,
        file_id,
        ours_item != null,
    );
    const theirs_document = try componentDocument(
        theirs_file,
        component_owners.theirs,
        owner_file_id,
        file_id,
        theirs_item != null,
    );
    if (equalOptionalDocuments(base_document, ours_document) and
        equalOptionalDocuments(base_document, theirs_document)) return false;
    const document_decision = decideDocument(base_document, ours_document, theirs_document);
    const chosen_document = switch (document_decision) {
        .ours, .common => ours_document,
        .theirs => theirs_document,
        .conflict => ours_document,
    };
    const document_id = if (chosen_document) |document| merge_identity.documentId(document.*) else merge_identity.documentId((base_document orelse ours_document orelse theirs_document).?.*);
    try operations.append(arena, .{
        .id = @intCast(operations.items.len),
        .atomic_id = atomic_id,
        .kind = .component,
        .identity = .{ .document = document_id, .property_path = "" },
        .hierarchy_path = if (chosen_document) |document| document.type_name else "",
        .property_path = "",
        .values = .{
            .base = documentValue(base_file, base_document),
            .ours = documentValue(ours_file, ours_document),
            .theirs = documentValue(theirs_file, theirs_document),
        },
        .resolution = switch (document_decision) {
            .ours, .common => if (ours_document == null) .remove else .{ .take = .ours },
            .theirs => if (theirs_document == null) .remove else .{ .take = .theirs },
            .conflict => .unresolved,
        },
    });
    return document_decision == .conflict;
}

fn componentDocument(
    file: source.ParsedFile,
    owners: merge_identity.ComponentOwnerIndex,
    owner_file_id: i64,
    component_file_id: i64,
    reference_is_present: bool,
) merge_model.Error!?*const model.Document {
    const owner = owners.get(component_file_id);
    const document = findDocumentByFileId(file.documents, component_file_id);
    if (!reference_is_present) {
        if (owner != null or document != null) return error.UnsupportedStructure;
        return null;
    }
    if (owner == null or owner.? != owner_file_id or document == null) return error.UnsupportedStructure;
    return document;
}

fn decideDocument(
    base: ?*const model.Document,
    ours: ?*const model.Document,
    theirs: ?*const model.Document,
) Decision {
    if (equalOptionalDocuments(ours, base)) return .theirs;
    if (equalOptionalDocuments(theirs, base)) return .ours;
    if (equalOptionalDocuments(ours, theirs)) return .common;
    return .conflict;
}

fn equalOptionalDocuments(a: ?*const model.Document, b: ?*const model.Document) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.class_id == b.?.class_id and a.?.file_id == b.?.file_id and
        model.Node.eql(a.?.body, b.?.body);
}

fn findDocumentByFileId(documents: []const model.Document, file_id: i64) ?*const model.Document {
    for (documents) |*document| if (document.file_id == file_id) return document;
    return null;
}

fn documentValue(file: source.ParsedFile, document: ?*const model.Document) ?merge_model.SideValue {
    const present = document orelse return null;
    for (file.documents, file.document_spans) |*candidate, span| {
        if (candidate == present) return .{ .node = present.body, .bytes = span.whole.bytes(file.bytes), .span = span.whole };
    }
    return null;
}

fn appendChildDocumentsOperation(
    arena: std.mem.Allocator,
    operations: *std.ArrayList(merge_model.Operation),
    atomic_id: merge_model.AtomicId,
    selected: SelectedItem,
    transform_file_id: i64,
    base_file: source.ParsedFile,
    ours_file: source.ParsedFile,
    theirs_file: source.ParsedFile,
) merge_model.Error!void {
    const ours_value = try childDocumentValue(arena, ours_file, transform_file_id);
    if (ours_value != null) return;
    const base_value = try childDocumentValue(arena, base_file, transform_file_id);
    const theirs_value = try childDocumentValue(arena, theirs_file, transform_file_id);
    _ = switch (selected.side) {
        .base => base_value,
        .ours => ours_value,
        .theirs => theirs_value,
    } orelse return error.UnsupportedStructure;
    const game_object_id = gameObjectId(selected.node, switch (selected.side) {
        .base => base_file,
        .ours => ours_file,
        .theirs => theirs_file,
    }, transform_file_id) orelse return error.UnsupportedStructure;
    try operations.append(arena, .{
        .id = @intCast(operations.items.len),
        .atomic_id = atomic_id,
        .kind = .game_object,
        .identity = .{ .document = .{ .class_id = 1, .file_id = game_object_id }, .property_path = "" },
        .hierarchy_path = "GameObject",
        .property_path = "",
        .values = .{ .base = base_value, .ours = ours_value, .theirs = theirs_value },
        .resolution = switch (selected.side) {
            .base => .{ .take = .base },
            .ours => .{ .take = .ours },
            .theirs => .{ .take = .theirs },
        },
    });
}

fn childDocumentValue(
    arena: std.mem.Allocator,
    file: source.ParsedFile,
    transform_file_id: i64,
) merge_model.Error!?merge_model.SideValue {
    const transform = findDocumentByFileId(file.documents, transform_file_id) orelse return null;
    const game_object_id = gameObjectId(transform.body, file, transform_file_id) orelse
        return error.UnsupportedStructure;
    const game_object = findDocument(file.documents, 1, game_object_id) orelse return error.UnsupportedStructure;
    const game_object_value = documentValue(file, findDocumentByFileId(file.documents, game_object_id)) orelse
        return error.UnsupportedStructure;
    const transform_value = documentValue(file, transform) orelse return error.UnsupportedStructure;
    var bytes: std.ArrayList(u8) = .empty;
    try bytes.appendSlice(arena, game_object_value.bytes);
    try bytes.appendSlice(arena, transform_value.bytes);
    return .{
        .node = game_object.body,
        .bytes = try bytes.toOwnedSlice(arena),
        .span = .{
            .start = @min(game_object_value.span.?.start, transform_value.span.?.start),
            .end = @max(game_object_value.span.?.end, transform_value.span.?.end),
        },
    };
}

fn gameObjectId(
    _: *const model.Node,
    file: source.ParsedFile,
    transform_file_id: i64,
) ?i64 {
    const transform = findDocumentByFileId(file.documents, transform_file_id) orelse return null;
    const game_object = model.findValue(transform.body.map, "m_GameObject") orelse return null;
    if (game_object.* != .ref) return null;
    return game_object.ref.file_id;
}

fn findDocument(documents: []const model.Document, class_id: u32, file_id: i64) ?model.Document {
    for (documents) |document| {
        if (document.class_id == class_id and document.file_id == file_id) return document;
    }
    return null;
}

fn mapEntries(node: ?*const model.Node) []const model.Entry {
    const present = node orelse return &.{};
    return switch (present.*) {
        .map => |entries| entries,
        else => &.{},
    };
}

fn findValueConst(entries: []const model.Entry, key: []const u8) ?*const model.Node {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.value;
    }
    return null;
}

fn hasMap(nodes: DocumentNodes) bool {
    inline for (.{ nodes.base, nodes.ours, nodes.theirs }) |node| {
        if (node) |present| if (present.* == .map) return true;
    }
    return false;
}

fn hasNonMap(nodes: DocumentNodes) bool {
    inline for (.{ nodes.base, nodes.ours, nodes.theirs }) |node| {
        if (node) |present| if (present.* != .map) return true;
    }
    return false;
}

fn hasSequence(nodes: DocumentNodes) bool {
    inline for (.{ nodes.base, nodes.ours, nodes.theirs }) |node| {
        if (node) |present| if (present.* == .seq) return true;
    }
    return false;
}

fn sideValue(file: source.ParsedFile, node: ?*const model.Node) ?merge_model.SideValue {
    const present = node orelse return null;
    return .{
        .node = present,
        .bytes = file.nodeBytes(present) orelse "",
        .span = file.node_spans.get(present),
    };
}

fn equalOptional(a: ?*const model.Node, b: ?*const model.Node) bool {
    if (a == null or b == null) return a == null and b == null;
    return model.Node.eql(a.?, b.?);
}

fn decide(base: ?*const model.Node, ours: ?*const model.Node, theirs: ?*const model.Node) Decision {
    if (equalOptional(ours, base)) return .theirs;
    if (equalOptional(theirs, base)) return .ours;
    if (equalOptional(ours, theirs)) return .common;
    return .conflict;
}

pub fn parseMergeSide(arena: std.mem.Allocator, bytes: []const u8) merge_model.Error!source.ParsedFile {
    if (bytes.len != 0 and !parser.isUnityYaml(bytes)) return error.MalformedInput;
    const parsed = try parser.parseSpanned(arena, bytes);
    try validateMergeSide(arena, parsed);
    return parsed;
}

fn validateMergeSide(arena: std.mem.Allocator, parsed: source.ParsedFile) merge_model.Error!void {
    if (parsed.bytes.len != 0 and !parser.isUnityYaml(parsed.bytes)) return error.MalformedInput;
    if (parsed.diagnostics.len != 0) return error.MalformedInput;
    try merge_identity.rejectDuplicateDocuments(arena, parsed.documents);
}

fn yamlWithValue(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "--- !u!114 &1\nMonoBehaviour:\n  m_Value: {s}\n",
        .{value},
    );
}

fn expectResult(
    arena: std.mem.Allocator,
    expected: ?[]const u8,
    built: @import("merge.zig").BuildResult,
) !void {
    if (expected) |value| {
        try testing.expectEqual(@as(usize, 0), built.plan.unresolvedCount());
        const line = try std.fmt.allocPrint(arena, "  m_Value: {s}\n", .{value});
        try testing.expect(std.mem.indexOf(u8, built.partial, line) != null);
    } else {
        try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
    }
}

test "merge planner: applies every scalar three-way rule symmetrically" {
    const Case = struct { base: []const u8, ours: []const u8, theirs: []const u8, result: ?[]const u8 };
    const cases = [_]Case{
        .{ .base = "5", .ours = "5", .theirs = "8", .result = "8" },
        .{ .base = "5", .ours = "12", .theirs = "5", .result = "12" },
        .{ .base = "5", .ours = "12", .theirs = "12", .result = "12" },
        .{ .base = "5", .ours = "12", .theirs = "8", .result = null },
    };
    for (cases) |case| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const base = try yamlWithValue(arena, case.base);
        const ours = try yamlWithValue(arena, case.ours);
        const theirs = try yamlWithValue(arena, case.theirs);
        const first = try @import("merge.zig").build(arena, base, ours, theirs);
        const second = try @import("merge.zig").build(arena, base, theirs, ours);
        try expectResult(arena, case.result, first);
        try expectResult(arena, case.result, second);
    }
}

test "merge planner: compares the complete object reference" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try yamlWithValue(arena, "{fileID: 7, guid: aaa, type: 3}");
    const ours = try yamlWithValue(arena, "{fileID: 7, guid: bbb, type: 3}");
    const theirs = try yamlWithValue(arena, "{fileID: 7, guid: ccc, type: 3}");
    const built = try @import("merge.zig").build(arena, base, ours, theirs);
    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
}

test "merge planner: rejects a changed sequence without a safe identity" {
    const base = "--- !u!114 &1\nMonoBehaviour:\n  m_Unknown:\n  - 1\n  - 2\n";
    const ours = "--- !u!114 &1\nMonoBehaviour:\n  m_Unknown:\n  - 1\n  - 3\n";
    const theirs = "--- !u!114 &1\nMonoBehaviour:\n  m_Unknown:\n  - 1\n  - 2\n";
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.UnsupportedStructure, @import("merge.zig").build(arena_state.allocator(), base, ours, theirs));
}

test "merge planner: combines independent component additions" {
    const fixture = @import("merge_test_support.zig").load("sequence-add", false);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var built = try @import("merge.zig").build(arena, fixture.base, fixture.ours, fixture.theirs);

    try testing.expectEqualStrings(fixture.expected, built.partial);
    try testing.expect(@import("merge_test_support.zig").findOperationByKind(&built.plan, .sequence_membership) != null);
    try testing.expect(@import("merge_test_support.zig").findOperationByKind(&built.plan, .sequence_order) != null);
    var component_count: usize = 0;
    for (built.plan.atomic_operations) |atomic| {
        if (atomic.kind != .component) continue;
        component_count += 1;
        try testing.expectEqual(@as(usize, 2), atomic.operation_ids.len);
    }
    try testing.expectEqual(@as(usize, 2), component_count);
    try @import("merge_test_support.zig").expectAtomicResolutionsAreWhole(&built.plan);
}

test "merge planner: keeps an existing component field edit separate from sequence membership" {
    const base =
        "--- !u!1 &100\nGameObject:\n  m_Component:\n  - component: {fileID: 400}\n" ++
        "--- !u!4 &400\nTransform:\n  m_GameObject: {fileID: 100}\n  m_Value: 0\n  m_Children: []\n  m_Father: {fileID: 0}\n";
    const ours =
        "--- !u!1 &100\nGameObject:\n  m_Component:\n  - component: {fileID: 400}\n  - component: {fileID: 540}\n" ++
        "--- !u!4 &400\nTransform:\n  m_GameObject: {fileID: 100}\n  m_Value: 0\n  m_Children: []\n  m_Father: {fileID: 0}\n" ++
        "--- !u!54 &540\nRigidbody:\n  m_GameObject: {fileID: 100}\n";
    const theirs =
        "--- !u!1 &100\nGameObject:\n  m_Component:\n  - component: {fileID: 400}\n  - component: {fileID: 650}\n" ++
        "--- !u!4 &400\nTransform:\n  m_GameObject: {fileID: 100}\n  m_Value: 1\n  m_Children: []\n  m_Father: {fileID: 0}\n" ++
        "--- !u!65 &650\nBoxCollider:\n  m_GameObject: {fileID: 100}\n";
    const expected =
        "--- !u!1 &100\nGameObject:\n  m_Component:\n  - component: {fileID: 400}\n  - component: {fileID: 540}\n  - component: {fileID: 650}\n" ++
        "--- !u!4 &400\nTransform:\n  m_GameObject: {fileID: 100}\n  m_Value: 1\n  m_Children: []\n  m_Father: {fileID: 0}\n" ++
        "--- !u!54 &540\nRigidbody:\n  m_GameObject: {fileID: 100}\n" ++
        "--- !u!65 &650\nBoxCollider:\n  m_GameObject: {fileID: 100}\n";
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const built = try @import("merge.zig").build(arena_state.allocator(), base, ours, theirs);

    try testing.expectEqualStrings(expected, built.partial);
}

test "merge planner: holds a component delete and edit conflict" {
    const support = @import("merge_test_support.zig");
    const fixture = support.load("sequence-delete-edit", true);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var built = try @import("merge.zig").build(arena, fixture.base, fixture.ours, fixture.theirs);

    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
    try testing.expectEqualStrings(fixture.base, built.partial);
    try testing.expect(support.findOperationByKind(&built.plan, .sequence_membership) != null);
    try testing.expect(support.findOperationByKind(&built.plan, .component) != null);
    try support.expectAtomicResolutionsAreWhole(&built.plan);
}

test "merge planner: groups a component document with its owner reference" {
    const fixture = @import("merge_test_support.zig").load("component-add", false);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var built = try @import("merge.zig").build(arena_state.allocator(), fixture.base, fixture.ours, fixture.theirs);
    const operation = @import("merge_test_support.zig").findAtomicByKind(&built.plan, .component).?;
    try testing.expect(operation.operation_ids.len >= 2);
    try testing.expect(std.mem.indexOf(u8, built.partial, "--- !u!54 &54") != null);
    try testing.expect(std.mem.indexOf(u8, built.partial, "component: {fileID: 54}") != null);
}

test "merge planner: combines the same component addition from both sides" {
    const fixture = @import("merge_test_support.zig").load("component-add", false);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var built = try @import("merge.zig").build(
        arena_state.allocator(),
        fixture.base,
        fixture.theirs,
        fixture.theirs,
    );

    try testing.expectEqual(@as(usize, 0), built.plan.unresolvedCount());
    try testing.expectEqualStrings(fixture.expected, built.partial);
    try testing.expectEqual(
        @as(usize, 2),
        @import("merge_test_support.zig").findAtomicByKind(&built.plan, .component).?.operation_ids.len,
    );
}

test "merge planner: reports different content for the same added component" {
    const fixture = @import("merge_test_support.zig").load("component-add", false);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const theirs = try std.mem.replaceOwned(u8, arena, fixture.theirs, "m_Mass: 1", "m_Mass: 2");

    const built = try @import("merge.zig").build(arena, fixture.base, fixture.theirs, theirs);

    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
    try testing.expectEqualStrings(fixture.base, built.partial);
}

test "merge planner: removes a component document with its owner reference" {
    const fixture = @import("merge_test_support.zig").load("component-delete", false);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var built = try @import("merge.zig").build(arena_state.allocator(), fixture.base, fixture.ours, fixture.theirs);
    const operation = @import("merge_test_support.zig").findAtomicByKind(&built.plan, .component).?;
    try testing.expect(operation.operation_ids.len >= 2);
    try testing.expectEqualStrings(fixture.expected, built.partial);
}

test "merge planner: adds a component to a valid owner sequence" {
    const base =
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n  m_Name: Root\n" ++
        "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children: []\n  m_Father: {fileID: 0}\n";
    const theirs =
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n  - component: {fileID: 54}\n  m_Name: Root\n" ++
        "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children: []\n  m_Father: {fileID: 0}\n" ++
        "--- !u!54 &54\nRigidbody:\n  m_GameObject: {fileID: 1}\n  m_Mass: 1\n";
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const built = try @import("merge.zig").build(arena_state.allocator(), base, base, theirs);

    try testing.expectEqualStrings(theirs, built.partial);
}

test "merge planner: adds two components to a valid owner sequence" {
    const base =
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n  m_Name: Root\n" ++
        "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children: []\n  m_Father: {fileID: 0}\n";
    const theirs =
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n  - component: {fileID: 54}\n  - component: {fileID: 65}\n  m_Name: Root\n" ++
        "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children: []\n  m_Father: {fileID: 0}\n" ++
        "--- !u!54 &54\nRigidbody:\n  m_GameObject: {fileID: 1}\n  m_Mass: 1\n" ++
        "--- !u!65 &65\nBoxCollider:\n  m_GameObject: {fileID: 1}\n  m_IsTrigger: 0\n";
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const built = try @import("merge.zig").build(arena_state.allocator(), base, base, theirs);

    try testing.expectEqualStrings(theirs, built.partial);
}

test "merge planner: composes component choices with an independent order choice" {
    const base =
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n  - component: {fileID: 54}\n  - component: {fileID: 65}\n  - component: {fileID: 66}\n" ++
        "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children: []\n  m_Father: {fileID: 0}\n" ++
        "--- !u!54 &54\nRigidbody:\n  m_GameObject: {fileID: 1}\n  m_Mass: 1\n" ++
        "--- !u!65 &65\nBoxCollider:\n  m_GameObject: {fileID: 1}\n  m_IsTrigger: 0\n" ++
        "--- !u!66 &66\nMeshCollider:\n  m_GameObject: {fileID: 1}\n  m_Convex: 0\n";
    const ours =
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 65}\n  # Keep with component 65.\n  - component: {fileID: 4}\n  - component: {fileID: 54}\n  - component: {fileID: 66}\n" ++
        "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children: []\n  m_Father: {fileID: 0}\n" ++
        "--- !u!54 &54\nRigidbody:\n  m_GameObject: {fileID: 1}\n  m_Mass: 2\n" ++
        "--- !u!65 &65\nBoxCollider:\n  m_GameObject: {fileID: 1}\n  m_IsTrigger: 0\n" ++
        "--- !u!66 &66\nMeshCollider:\n  m_GameObject: {fileID: 1}\n  m_Convex: 0\n";
    const theirs =
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n  - component: {fileID: 66}\n  - component: {fileID: 65}\n" ++
        "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children: []\n  m_Father: {fileID: 0}\n" ++
        "--- !u!65 &65\nBoxCollider:\n  m_GameObject: {fileID: 1}\n  m_IsTrigger: 0\n" ++
        "--- !u!66 &66\nMeshCollider:\n  m_GameObject: {fileID: 1}\n  m_Convex: 0\n";
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var built = try @import("merge.zig").build(arena, base, ours, theirs);
    const component = @import("merge_test_support.zig").findOperationByKind(&built.plan, .component).?;
    const order = @import("merge_test_support.zig").findOperationByKind(&built.plan, .sequence_order).?;

    try @import("merge.zig").resolve(arena, &built.plan, component.id, .{ .take = .ours });
    try @import("merge.zig").resolve(arena, &built.plan, order.id, .{ .take = .theirs });
    const finished = try @import("merge.zig").finish(arena, &built.plan);

    const component_4 = std.mem.indexOf(u8, finished, "component: {fileID: 4}").?;
    const component_66 = std.mem.indexOf(u8, finished, "component: {fileID: 66}").?;
    const component_65 = std.mem.indexOf(u8, finished, "component: {fileID: 65}").?;
    try testing.expect(std.mem.indexOf(u8, finished, "component: {fileID: 54}") != null);
    try testing.expect(std.mem.indexOf(u8, finished, "--- !u!54 &54") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        finished,
        "  - component: {fileID: 65}\n  # Keep with component 65.\n",
    ) != null);
    try testing.expect(component_4 < component_66 and component_66 < component_65);

    var reversed = try @import("merge.zig").build(arena, base, theirs, ours);
    const reversed_component = @import("merge_test_support.zig").findOperationByKind(&reversed.plan, .component).?;
    const reversed_order = @import("merge_test_support.zig").findOperationByKind(&reversed.plan, .sequence_order).?;
    try @import("merge.zig").resolve(arena, &reversed.plan, reversed_component.id, .remove);
    try @import("merge.zig").resolve(arena, &reversed.plan, reversed_order.id, .{ .take = .theirs });
    const reversed_finished = try @import("merge.zig").finish(arena, &reversed.plan);

    try testing.expect(std.mem.indexOf(u8, reversed_finished, "component: {fileID: 54}") == null);
    try testing.expect(std.mem.indexOf(u8, reversed_finished, "--- !u!54 &54") == null);
}

test "merge planner: keeps a component gap when the next component is deleted" {
    const base =
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n" ++
        "  - component: {fileID: 54}\n  # Keep with component 54.\n  - component: {fileID: 65}\n" ++
        "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children: []\n  m_Father: {fileID: 0}\n" ++
        "--- !u!54 &54\nRigidbody:\n  m_GameObject: {fileID: 1}\n  m_Mass: 1\n" ++
        "--- !u!65 &65\nBoxCollider:\n  m_GameObject: {fileID: 1}\n  m_IsTrigger: 0\n";
    const theirs =
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n" ++
        "  - component: {fileID: 54}\n" ++
        "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children: []\n  m_Father: {fileID: 0}\n" ++
        "--- !u!54 &54\nRigidbody:\n  m_GameObject: {fileID: 1}\n  m_Mass: 1\n";
    const expected =
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n" ++
        "  - component: {fileID: 54}\n  # Keep with component 54.\n" ++
        "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children: []\n  m_Father: {fileID: 0}\n" ++
        "--- !u!54 &54\nRigidbody:\n  m_GameObject: {fileID: 1}\n  m_Mass: 1\n";
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const built = try @import("merge.zig").build(arena_state.allocator(), base, base, theirs);

    try testing.expectEqualStrings(expected, built.partial);
}

test "merge planner: rejects a component reference without its document" {
    const base =
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n" ++
        "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children: []\n  m_Father: {fileID: 0}\n";
    const ours =
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n  - component: {fileID: 54}\n" ++
        "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children: []\n  m_Father: {fileID: 0}\n";
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    try testing.expectError(
        error.UnsupportedStructure,
        @import("merge.zig").build(arena_state.allocator(), base, ours, base),
    );
}

test "merge planner: rejects a component document without its owner reference" {
    const base =
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n" ++
        "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children: []\n  m_Father: {fileID: 0}\n";
    const ours = base ++
        "--- !u!54 &54\nRigidbody:\n  m_GameObject: {fileID: 1}\n  m_Mass: 1\n";
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    try testing.expectError(
        error.UnsupportedStructure,
        @import("merge.zig").build(arena_state.allocator(), base, ours, base),
    );
}

test "merge planner: leaves every part of a delete-edit conflict unchanged" {
    const fixture = @import("merge_test_support.zig").load("component-delete-edit", true);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const built = try @import("merge.zig").build(arena_state.allocator(), fixture.base, fixture.ours, fixture.theirs);
    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
    try testing.expectEqualStrings(fixture.partial.?, built.partial);
    try testing.expect(std.mem.indexOf(u8, built.partial, "--- !u!54 &54") != null);
    try testing.expect(std.mem.indexOf(u8, built.partial, "component: {fileID: 54}") != null);
}

test "merge planner: applies an independent component while another component is unresolved" {
    const base =
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n  - component: {fileID: 54}\n" ++
        "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children: []\n  m_Father: {fileID: 0}\n" ++
        "--- !u!54 &54\nRigidbody:\n  m_GameObject: {fileID: 1}\n  m_Mass: 1\n";
    const ours =
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n" ++
        "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children: []\n  m_Father: {fileID: 0}\n";
    const theirs =
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n  - component: {fileID: 54}\n  - component: {fileID: 65}\n" ++
        "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children: []\n  m_Father: {fileID: 0}\n" ++
        "--- !u!54 &54\nRigidbody:\n  m_GameObject: {fileID: 1}\n  m_Mass: 2\n" ++
        "--- !u!65 &65\nBoxCollider:\n  m_GameObject: {fileID: 1}\n  m_IsTrigger: 0\n";
    const expected =
        "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n  - component: {fileID: 54}\n  - component: {fileID: 65}\n" ++
        "--- !u!4 &4\nTransform:\n  m_GameObject: {fileID: 1}\n  m_Children: []\n  m_Father: {fileID: 0}\n" ++
        "--- !u!54 &54\nRigidbody:\n  m_GameObject: {fileID: 1}\n  m_Mass: 1\n" ++
        "--- !u!65 &65\nBoxCollider:\n  m_GameObject: {fileID: 1}\n  m_IsTrigger: 0\n";
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const built = try @import("merge.zig").build(arena_state.allocator(), base, ours, theirs);

    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
    try testing.expectEqualStrings(expected, built.partial);
}

test "merge planner: one choice resolves a complete component operation" {
    const fixture = @import("merge_test_support.zig").load("component-delete-edit", true);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var built = try @import("merge.zig").build(arena, fixture.base, fixture.ours, fixture.theirs);
    const operation = @import("merge_test_support.zig").findOperationByKind(&built.plan, .component).?;

    try @import("merge.zig").resolve(arena, &built.plan, operation.id, .{ .take = .theirs });
    try testing.expectEqual(@as(usize, 0), built.plan.unresolvedCount());
    try @import("merge_test_support.zig").expectAtomicResolutionsAreWhole(&built.plan);
    try testing.expectEqualStrings(fixture.expected, try @import("merge.zig").finish(arena, &built.plan));
}

test "merge planner: resolves a component delete and edit conflict with the selected side" {
    const support = @import("merge_test_support.zig");
    const fixture = support.load("sequence-delete-edit", true);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var built = try @import("merge.zig").build(arena, fixture.base, fixture.ours, fixture.theirs);
    const component = support.findOperationByKind(&built.plan, .component).?;

    try @import("merge.zig").resolve(arena, &built.plan, component.id, .{ .take = .theirs });

    try testing.expectEqualStrings(fixture.expected, try @import("merge.zig").finish(arena, &built.plan));
}

test "merge planner: applies an order change from one side" {
    const support = @import("merge_test_support.zig");
    const fixture = support.load("sequence-reorder-one-side", false);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var built = try @import("merge.zig").build(arena, fixture.base, fixture.ours, fixture.theirs);

    try testing.expectEqualStrings(fixture.expected, built.partial);
    try testing.expect(support.findOperationByKind(&built.plan, .sequence_order) != null);
    try testing.expect(support.findAtomicByKind(&built.plan, .sequence_order) != null);
    try support.expectAtomicResolutionsAreWhole(&built.plan);
}

test "merge planner: combines a child addition with a compatible reorder" {
    const support = @import("merge_test_support.zig");
    const fixture = support.load("sequence-reorder-compatible", false);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var built = try @import("merge.zig").build(arena, fixture.base, fixture.ours, fixture.theirs);

    try testing.expectEqualStrings(fixture.expected, built.partial);
    try testing.expect(support.findOperationByKind(&built.plan, .sequence_membership) != null);
    try testing.expect(support.findOperationByKind(&built.plan, .sequence_order) != null);
    try testing.expect(support.findOperationByKind(&built.plan, .game_object) != null);
    try support.expectAtomicResolutionsAreWhole(&built.plan);
}

test "merge planner: adds a child to an inline empty sequence" {
    const base =
        "--- !u!1 &100\nGameObject:\n  m_Component:\n  - component: {fileID: 400}\n" ++
        "--- !u!4 &400\nTransform:\n  m_GameObject: {fileID: 100}\n  m_Children: []\n  m_Father: {fileID: 0}\n";
    const theirs =
        "--- !u!1 &100\nGameObject:\n  m_Component:\n  - component: {fileID: 400}\n" ++
        "--- !u!4 &400\nTransform:\n  m_GameObject: {fileID: 100}\n  m_Children:\n  - {fileID: 410}\n  m_Father: {fileID: 0}\n" ++
        "--- !u!1 &110\nGameObject:\n  m_Component:\n  - component: {fileID: 410}\n" ++
        "--- !u!4 &410\nTransform:\n  m_GameObject: {fileID: 110}\n  m_Children: []\n  m_Father: {fileID: 400}\n";
    const expected =
        "--- !u!1 &100\nGameObject:\n  m_Component:\n  - component: {fileID: 400}\n" ++
        "--- !u!4 &400\nTransform:\n  m_GameObject: {fileID: 100}\n  m_Children:\n  - {fileID: 410}\n  m_Father: {fileID: 0}\n" ++
        "--- !u!1 &110\nGameObject:\n  m_Component:\n  - component: {fileID: 410}\n" ++
        "--- !u!4 &410\nTransform:\n  m_GameObject: {fileID: 110}\n  m_Children: []\n  m_Father: {fileID: 400}\n";
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const built = try @import("merge.zig").build(arena_state.allocator(), base, base, theirs);

    try testing.expectEqualStrings(expected, built.partial);
}

test "merge planner: deletes the final child from a block sequence" {
    const block =
        "--- !u!1 &100\nGameObject:\n  m_Component:\n  - component: {fileID: 400}\n" ++
        "--- !u!4 &400\nTransform:\n  m_GameObject: {fileID: 100}\n  m_Children:\n  - {fileID: 410}\n  m_Father: {fileID: 0}\n" ++
        "--- !u!1 &110\nGameObject:\n  m_Component:\n  - component: {fileID: 410}\n" ++
        "--- !u!4 &410\nTransform:\n  m_GameObject: {fileID: 110}\n  m_Children: []\n  m_Father: {fileID: 400}\n";
    const inline_empty =
        "--- !u!1 &100\nGameObject:\n  m_Component:\n  - component: {fileID: 400}\n" ++
        "--- !u!4 &400\nTransform:\n  m_GameObject: {fileID: 100}\n  m_Children: []\n  m_Father: {fileID: 0}\n" ++
        "--- !u!1 &110\nGameObject:\n  m_Component:\n  - component: {fileID: 410}\n" ++
        "--- !u!4 &410\nTransform:\n  m_GameObject: {fileID: 110}\n  m_Children: []\n  m_Father: {fileID: 0}\n";
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const built = try @import("merge.zig").build(arena_state.allocator(), block, block, inline_empty);

    try testing.expectEqualStrings(inline_empty, built.partial);
}

test "merge planner: keeps inline spacing after deleting the final child" {
    const block =
        "--- !u!1 &100\nGameObject:\n  m_Component:\n  - component: {fileID: 400}\n" ++
        "--- !u!4 &400\nTransform:\n  m_GameObject: {fileID: 100}\n  m_Children:\n  - {fileID: 410}\n  m_Father: {fileID: 0}\n" ++
        "--- !u!1 &110\nGameObject:\n  m_Component:\n  - component: {fileID: 410}\n" ++
        "--- !u!4 &410\nTransform:\n  m_GameObject: {fileID: 110}\n  m_Children: []\n  m_Father: {fileID: 400}\n";
    const inline_empty =
        "--- !u!1 &100\nGameObject:\n  m_Component:\n  - component: {fileID: 400}\n" ++
        "--- !u!4 &400\nTransform:\n  m_GameObject: {fileID: 100}\n  m_Children: []\n  m_Father: {fileID: 0}\n" ++
        "--- !u!1 &110\nGameObject:\n  m_Component:\n  - component: {fileID: 410}\n" ++
        "--- !u!4 &410\nTransform:\n  m_GameObject: {fileID: 110}\n  m_Children: []\n  m_Father: {fileID: 0}\n";
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const built = try @import("merge.zig").build(arena_state.allocator(), block, inline_empty, block);

    try testing.expectEqualStrings(inline_empty, built.partial);
}

test "merge planner: rejects a changed Prefab override sequence until its rules exist" {
    const base =
        "--- !u!1001 &1001\nPrefabInstance:\n  m_Modification:\n    m_Modifications:\n" ++
        "    - target: {fileID: 1, guid: aaa, type: 3}\n      propertyPath: m_Name\n      value: Old\n";
    const ours =
        "--- !u!1001 &1001\nPrefabInstance:\n  m_Modification:\n    m_Modifications:\n" ++
        "    - target: {fileID: 1, guid: aaa, type: 3}\n      propertyPath: m_Name\n      value: New\n";
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    try testing.expectError(
        error.UnsupportedStructure,
        @import("merge.zig").build(arena_state.allocator(), base, ours, base),
    );
}

test "merge planner: holds conflicting child orders" {
    const support = @import("merge_test_support.zig");
    const fixture = support.load("sequence-reorder-conflict", true);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var built = try @import("merge.zig").build(arena, fixture.base, fixture.ours, fixture.theirs);

    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
    try testing.expectEqualStrings(fixture.partial.?, built.partial);
    try testing.expect(support.findOperationByKind(&built.plan, .sequence_order) != null);
    try support.expectAtomicResolutionsAreWhole(&built.plan);
}

test "merge planner: keeps an unchanged unknown sequence byte-for-byte" {
    const yaml = "--- !u!114 &1\nMonoBehaviour:\n  # Keep this order and spelling.\n  m_Unknown:\n  - 01\n  - 2\n";
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const built = try @import("merge.zig").build(arena_state.allocator(), yaml, yaml, yaml);
    try testing.expectEqualStrings(yaml, built.partial);
}

test "merge planner: rejects a non-Unity merge side" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.MalformedInput, parseMergeSide(arena_state.allocator(), "value: 1\n"));
}

test "merge planner: rejects a merge side with parser diagnostics" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const malformed = "--- !u!114 &bad\nMonoBehaviour:\n  value: 1\n";
    try testing.expectError(error.MalformedInput, parseMergeSide(arena_state.allocator(), malformed));
}

test "merge planner: rejects duplicate document identifiers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const duplicate =
        "--- !u!1 &7\nGameObject:\n  m_Name: First\n" ++
        "--- !u!1 &7\nGameObject:\n  m_Name: Second\n";
    try testing.expectError(error.MalformedInput, parseMergeSide(arena_state.allocator(), duplicate));
}

test "merge planner: rejects malformed input through the merge facade" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const unity = "--- !u!114 &1\nMonoBehaviour:\n  value: 1\n";
    try testing.expectError(
        error.MalformedInput,
        @import("merge.zig").build(arena_state.allocator(), "value: 1\n", unity, unity),
    );
}

test "merge planner: rejects duplicate documents through the merge facade" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const duplicate =
        "--- !u!1 &7\nGameObject:\n  m_Name: First\n" ++
        "--- !u!1 &7\nGameObject:\n  m_Name: Second\n";
    try testing.expectError(
        error.MalformedInput,
        @import("merge.zig").build(arena_state.allocator(), duplicate, duplicate, duplicate),
    );
}

test "merge planner: adds a field to its matching document" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base =
        "--- !u!114 &1\nMonoBehaviour:\n  m_Name: First\n" ++
        "--- !u!114 &2\nMonoBehaviour:\n  m_Value: 5\n";
    const theirs =
        "--- !u!114 &1\nMonoBehaviour:\n  m_Name: First\n" ++
        "--- !u!114 &2\nMonoBehaviour:\n  m_Value: 5\n  m_Enabled: 1\n";

    const built = try @import("merge.zig").build(arena, base, base, theirs);

    try testing.expectEqualStrings(theirs, built.partial);
}

test "merge planner: removes a field when the other side is unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try yamlWithValue(arena, "5");
    const removed = "--- !u!114 &1\nMonoBehaviour:\n";

    const first = try @import("merge.zig").build(arena, base, base, removed);
    const second = try @import("merge.zig").build(arena, base, removed, base);

    try testing.expectEqualStrings(removed, first.partial);
    try testing.expectEqualStrings(removed, second.partial);
}

test "merge planner: keeps our bytes for a common semantic value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try yamlWithValue(arena, "5");
    const ours = try yamlWithValue(arena, "'12'");
    const theirs = try yamlWithValue(arena, "\"12\"");

    const built = try @import("merge.zig").build(arena, base, ours, theirs);

    try testing.expectEqualStrings(ours, built.partial);
}

test "merge facade: retains a custom resolution" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try yamlWithValue(arena, "5");
    const ours = try yamlWithValue(arena, "8");
    const theirs = try yamlWithValue(arena, "12");
    var custom = [_]u8{ '4', '2' };
    var built = try @import("merge.zig").build(arena, base, ours, theirs);

    try @import("merge.zig").resolve(arena, &built.plan, 0, .{ .custom = &custom });
    custom = .{ '9', '9' };
    const result = try @import("merge.zig").finish(arena, &built.plan);

    try testing.expect(std.mem.indexOf(u8, result, "  m_Value: 42\n") != null);
}

test "merge facade: rejects an invalid custom value and keeps the atomic operation unresolved" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try yamlWithValue(arena, "1");
    const ours = try yamlWithValue(arena, "2");
    const theirs = try yamlWithValue(arena, "3");
    var built = try @import("merge.zig").build(arena, base, ours, theirs);

    try testing.expectError(
        error.InvalidResolution,
        @import("merge.zig").resolve(arena, &built.plan, 0, .{ .custom = "{x: 1}" }),
    );
    try testing.expectEqual(@as(usize, 1), built.plan.unresolvedCount());
}

test "merge facade: restores an atomic operation when its patches overlap" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = "--- !u!114 &1\nMonoBehaviour:\n  first: 1\n  second: 1\n";
    const ours = "--- !u!114 &1\nMonoBehaviour:\n  first: 2\n  second: 2\n";
    const theirs = "--- !u!114 &1\nMonoBehaviour:\n  first: 3\n  second: 3\n";
    var built = try @import("merge.zig").build(arena, base, ours, theirs);
    const operation_ids = try arena.dupe(merge_model.OperationId, &.{ 0, 1 });
    built.plan.operations[1].atomic_id = 0;
    built.plan.operations[1].values.ours.?.span = built.plan.operations[0].values.ours.?.span;
    built.plan.atomic_operations[0].operation_ids = operation_ids;
    built.plan.atomic_operations = built.plan.atomic_operations[0..1];

    try testing.expectError(
        error.InvalidMerge,
        @import("merge.zig").resolve(arena, &built.plan, 0, .{ .take = .theirs }),
    );
    try testing.expect(built.plan.operations[0].resolution == .unresolved);
    try testing.expect(built.plan.operations[1].resolution == .unresolved);
}

test "merge facade: rejects a custom value for an automatically resolved field" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try yamlWithValue(arena, "1");
    const ours = try yamlWithValue(arena, "1");
    const theirs = try yamlWithValue(arena, "2");
    var built = try @import("merge.zig").build(arena, base, ours, theirs);

    try testing.expectError(
        error.InvalidResolution,
        @import("merge.zig").resolve(arena, &built.plan, 0, .{ .custom = "3" }),
    );
    try testing.expectEqualStrings(theirs, try @import("merge.zig").finish(arena, &built.plan));
}

test "merge facade: permits a revised custom value for an original conflict" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try yamlWithValue(arena, "1");
    const ours = try yamlWithValue(arena, "2");
    const theirs = try yamlWithValue(arena, "3");
    var built = try @import("merge.zig").build(arena, base, ours, theirs);

    try @import("merge.zig").resolve(arena, &built.plan, 0, .{ .custom = "4" });
    try @import("merge.zig").resolve(arena, &built.plan, 0, .{ .custom = "5" });
    try testing.expectEqualStrings(
        try yamlWithValue(arena, "5"),
        try @import("merge.zig").finish(arena, &built.plan),
    );
}
