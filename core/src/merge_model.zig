const model = @import("model.zig");
const source = @import("source.zig");

pub const OperationId = u32;
pub const AtomicId = u32;
pub const Error = @import("parser.zig").Error || error{
    MalformedInput,
    UnsupportedStructure,
    InvalidResolution,
    InvalidMerge,
};
pub const Side = enum { base, ours, theirs };
pub const OperationKind = enum {
    field,
    sequence_membership,
    sequence_content,
    sequence_order,
    component,
    game_object,
    reparent,
    prefab_override,
};

pub const DocumentId = struct { class_id: u32, file_id: i64 };
pub const RefId = struct { file_id: i64, guid: ?[]const u8, type_id: ?i64 };

pub const SemanticId = struct {
    document: DocumentId,
    property_path: []const u8,
    item_ref: ?RefId = null,
    override_kind: ?PrefabOverrideKind = null,
};

pub const PrefabOverrideKind = enum {
    property,
    added_component,
    removed_component,
    added_game_object,
    removed_game_object,
};

pub const SideValue = struct {
    node: ?*const model.Node,
    bytes: []const u8,
    span: ?source.Span,
};

pub const Values = struct {
    base: ?SideValue,
    ours: ?SideValue,
    theirs: ?SideValue,
};

pub const Resolution = union(enum) {
    unresolved,
    take: Side,
    remove,
    custom: []const u8,
};

pub const Operation = struct {
    id: OperationId,
    atomic_id: AtomicId,
    kind: OperationKind,
    identity: SemanticId,
    hierarchy_path: []const u8,
    property_path: []const u8,
    values: Values,
    resolution: Resolution,
    dependencies: []const AtomicId = &.{},
};

pub const AtomicOperation = struct {
    id: AtomicId,
    kind: OperationKind,
    operation_ids: []const OperationId,
    dependencies: []const AtomicId = &.{},
};

pub const MergePlan = struct {
    base: source.ParsedFile,
    ours: source.ParsedFile,
    theirs: source.ParsedFile,
    operations: []Operation,
    atomic_operations: []AtomicOperation,

    pub fn unresolvedCount(self: MergePlan) usize {
        var count: usize = 0;
        for (self.atomic_operations) |atomic| {
            for (atomic.operation_ids) |id| {
                const operation = operationByIdConst(&self, id) orelse unreachable;
                if (operation.resolution == .unresolved) {
                    count += 1;
                    break;
                }
            }
        }
        return count;
    }
};

pub fn operationById(plan: *MergePlan, id: OperationId) ?*Operation {
    for (plan.operations) |*operation| {
        if (operation.id == id) return operation;
    }
    return null;
}

pub fn operationByIdConst(plan: *const MergePlan, id: OperationId) ?*const Operation {
    for (plan.operations) |*operation| {
        if (operation.id == id) return operation;
    }
    return null;
}

pub fn atomicById(plan: *MergePlan, id: AtomicId) ?*AtomicOperation {
    for (plan.atomic_operations) |*operation| {
        if (operation.id == id) return operation;
    }
    return null;
}
