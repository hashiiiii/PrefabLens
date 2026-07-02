const std = @import("std");

const Pair = struct { id: u32, name: []const u8 };

// Common Unity classIDs (subset sufficient for prefab/scene/asset diffing).
// Source: Unity "YAML Class ID Reference".
const table = [_]Pair{
    .{ .id = 1, .name = "GameObject" },
    .{ .id = 2, .name = "Component" },
    .{ .id = 4, .name = "Transform" },
    .{ .id = 8, .name = "Behaviour" },
    .{ .id = 20, .name = "Camera" },
    .{ .id = 21, .name = "Material" },
    .{ .id = 23, .name = "MeshRenderer" },
    .{ .id = 25, .name = "Renderer" },
    .{ .id = 33, .name = "MeshFilter" },
    .{ .id = 64, .name = "MeshCollider" },
    .{ .id = 65, .name = "BoxCollider" },
    .{ .id = 81, .name = "AudioListener" },
    .{ .id = 82, .name = "AudioSource" },
    .{ .id = 95, .name = "Animator" },
    .{ .id = 108, .name = "Light" },
    .{ .id = 114, .name = "MonoBehaviour" },
    .{ .id = 115, .name = "MonoScript" },
    .{ .id = 135, .name = "SphereCollider" },
    .{ .id = 136, .name = "CapsuleCollider" },
    .{ .id = 137, .name = "SkinnedMeshRenderer" },
    .{ .id = 143, .name = "CharacterController" },
    .{ .id = 198, .name = "ParticleSystem" },
    .{ .id = 199, .name = "ParticleSystemRenderer" },
    .{ .id = 212, .name = "SpriteRenderer" },
    .{ .id = 222, .name = "CanvasRenderer" },
    .{ .id = 223, .name = "Canvas" },
    .{ .id = 224, .name = "RectTransform" },
    .{ .id = 225, .name = "CanvasGroup" },
    .{ .id = 320, .name = "PlayableDirector" },
    .{ .id = 1001, .name = "PrefabInstance" },
    .{ .id = 1660057539, .name = "SceneRoots" },
};

pub fn typeName(class_id: u32) ?[]const u8 {
    for (table) |p| if (p.id == class_id) return p.name;
    return null;
}

test "classID lookup covers common types and returns null for unknown" {
    try std.testing.expectEqualStrings("GameObject", typeName(1).?);
    try std.testing.expectEqualStrings("Transform", typeName(4).?);
    try std.testing.expectEqualStrings("MonoBehaviour", typeName(114).?);
    try std.testing.expectEqualStrings("MeshRenderer", typeName(23).?);
    try std.testing.expectEqualStrings("RectTransform", typeName(224).?);
    try std.testing.expectEqualStrings("PrefabInstance", typeName(1001).?);
    try std.testing.expect(typeName(999999) == null);
}
