const std = @import("std");

test "Node.eql: scalars, refs, seqs, maps" {
    const a = std.testing.allocator;
    _ = a;

    // Scalars
    var s1 = Node{ .scalar = "100" };
    var s2 = Node{ .scalar = "100" };
    var s3 = Node{ .scalar = "150" };
    try std.testing.expect(Node.eql(&s1, &s2));
    try std.testing.expect(!Node.eql(&s1, &s3));

    // Refs
    var r1 = Node{ .ref = .{ .file_id = 234, .guid = "abc", .type_id = 3 } };
    var r2 = Node{ .ref = .{ .file_id = 234, .guid = "abc", .type_id = 3 } };
    var r3 = Node{ .ref = .{ .file_id = 234, .guid = "xyz", .type_id = 3 } };
    try std.testing.expect(Node.eql(&r1, &r2));
    try std.testing.expect(!Node.eql(&r1, &r3));

    // Seqs
    var seq_a = [_]*Node{ &s1, &s3 };
    var seq_b = [_]*Node{ &s2, &s3 };
    var q1 = Node{ .seq = &seq_a };
    var q2 = Node{ .seq = &seq_b };
    try std.testing.expect(Node.eql(&q1, &q2));

    // Maps
    var e_a = [_]Entry{ .{ .key = "x", .value = &s1 }, .{ .key = "y", .value = &s3 } };
    var e_b = [_]Entry{ .{ .key = "y", .value = &s3 }, .{ .key = "x", .value = &s2 } };
    var m1 = Node{ .map = &e_a };
    var m2 = Node{ .map = &e_b };
    try std.testing.expect(Node.eql(&m1, &m2));
}
