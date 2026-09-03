const std = @import("std");
const model = @import("model.zig");
const source_map = @import("source.zig");
const Node = model.Node;
const Entry = model.Entry;
const Document = model.Document;

pub const Error = std.mem.Allocator.Error || error{NestingTooDeep};

const testing = std.testing;

fn parseOne(arena: std.mem.Allocator, src: []const u8) !Document {
    const docs = try parse(arena, src);
    try testing.expectEqual(@as(usize, 1), docs.len);
    return docs[0];
}

test "parse: single document header + flat scalar fields" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\%YAML 1.1
        \\%TAG !u! tag:unity3d.com,2011:
        \\--- !u!1 &123456789
        \\GameObject:
        \\  m_Name: Player
        \\  m_IsActive: 1
    ;
    const doc = try parseOne(arena, src);
    try testing.expectEqual(@as(u32, 1), doc.class_id);
    try testing.expectEqual(@as(i64, 123456789), doc.file_id);
    try testing.expectEqualStrings("GameObject", doc.type_name);

    const name = model.findValue(doc.body.map, "m_Name").?;
    try testing.expectEqualStrings("Player", name.scalar);
    const active = model.findValue(doc.body.map, "m_IsActive").?;
    try testing.expectEqualStrings("1", active.scalar);
}

test "parseSpanned: retains exact source slices" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const src =
        "%YAML 1.1\r\n" ++
        "%TAG !u! tag:unity3d.com,2011:\r\n" ++
        "--- !u!1 &1\r\n" ++
        "GameObject:\r\n" ++
        "  # Keep this comment.\r\n" ++
        "  m_Name: \"Robot\\\"A\"\r\n" ++
        "  m_Component:\r\n" ++
        "  - component: {fileID: 4}\r\n" ++
        "\r\n" ++
        "--- !u!4 &4\r\n" ++
        "Transform:\r\n" ++
        "  m_GameObject: {fileID: 1}\r\n";

    const parsed = try parseSpanned(arena_state.allocator(), src);
    try testing.expectEqual(source_map.LineEnding.crlf, parsed.line_ending);
    try testing.expectEqual(@as(usize, 2), parsed.documents.len);
    try testing.expectEqualStrings(
        "--- !u!1 &1\r\nGameObject:\r\n  # Keep this comment.\r\n  m_Name: \"Robot\\\"A\"\r\n  m_Component:\r\n  - component: {fileID: 4}\r\n\r\n",
        parsed.documentBytes(0),
    );
    try testing.expectEqualStrings("1", parsed.document_spans[0].class_id.bytes(src));
    try testing.expectEqualStrings("1", parsed.document_spans[0].file_id.bytes(src));
    const components = model.findValue(parsed.documents[0].body.map, "m_Component").?;
    const item = components.seq[0];
    try testing.expectEqualStrings(
        "  - component: {fileID: 4}\r\n",
        parsed.sequenceItemBytes(item).?,
    );
    const component_ref = model.findValue(item.map, "component").?;
    try testing.expectEqualStrings("{fileID: 4}", parsed.nodeBytes(component_ref).?);
    const name = model.findValue(parsed.documents[0].body.map, "m_Name").?;
    try testing.expectEqualStrings("\"Robot\\\"A\"", parsed.nodeBytes(name).?);
}

test "parseSpanned: reports malformed syntax without changing parse" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const src = "--- !u!bad &oops\nGameObject:\n  missing colon\n";

    const parsed = try parseSpanned(arena_state.allocator(), src);
    try testing.expect(parsed.diagnostics.len >= 2);
    const docs = try parse(arena_state.allocator(), src);
    try testing.expectEqual(@as(usize, 1), docs.len);
}

test "parseSpanned: records container and nested entry spans" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const src = "--- !u!1 &1\nGameObject:\n  m_Component:\n  - component: {fileID: 4}\n    propertyPath: m_Name\n  m_Vector: {x: 1, y: 2}\n";
    const parsed = try parseSpanned(arena_state.allocator(), src);
    const body = parsed.documents[0].body;
    try testing.expectEqualStrings("  - component: {fileID: 4}\n    propertyPath: m_Name\n", parsed.nodeBytes(model.findValue(body.map, "m_Component").?).?);
    const components = model.findValue(body.map, "m_Component").?;
    try testing.expectEqualStrings("  - component: {fileID: 4}\n    propertyPath: m_Name\n", parsed.sequenceItemBytes(components.seq[0]).?);
    try testing.expectEqualStrings("  - component: {fileID: 4}\n    propertyPath: m_Name\n", parsed.nodeBytes(components.seq[0]).?);
    const component = model.findValue(components.seq[0].map, "component").?;
    try testing.expect(parsed.entry_spans.get(component) != null);
    const property = model.findValue(components.seq[0].map, "propertyPath").?;
    try testing.expect(parsed.entry_spans.get(property) != null);
    const vector = model.findValue(body.map, "m_Vector").?;
    const x = model.findValue(vector.map, "x").?;
    try testing.expect(parsed.entry_spans.get(x) != null);
}

test "parseSpanned: selects adjacent line ending at EOF" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const src = "--- !u!1 &1\r\nGameObject:\r\n  m_Name: A\n";
    const parsed = try parseSpanned(arena_state.allocator(), src);
    try testing.expectEqualStrings("\n", parsed.lineEndingAt(src.len));
}

test "parseSpanned: recognizes a direct document header after a UTF-8 BOM" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const src = "\xEF\xBB\xBF--- !u!114 &1\nMonoBehaviour:\n  m_Name: Existing\n";

    const parsed = try parseSpanned(arena_state.allocator(), src);

    try testing.expectEqual(@as(usize, 1), parsed.documents.len);
    try testing.expectEqual(@as(u32, 114), parsed.documents[0].class_id);
    try testing.expectEqual(@as(i64, 1), parsed.documents[0].file_id);
    try testing.expectEqualStrings(src, parsed.documentBytes(0));
    try testing.expectEqualStrings("--- !u!114 &1", parsed.document_spans[0].header.bytes(src));
    const name = model.findValue(parsed.documents[0].body.map, "m_Name").?;
    try testing.expectEqualStrings("Existing", parsed.nodeBytes(name).?);
}

test "parse: multiple documents" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\--- !u!1 &100
        \\GameObject:
        \\  m_Name: A
        \\--- !u!4 &200
        \\Transform:
        \\  m_GameObject: {fileID: 100}
    ;
    const docs = try parse(arena, src);
    try testing.expectEqual(@as(usize, 2), docs.len);
    try testing.expectEqual(@as(i64, 100), docs[0].file_id);
    try testing.expectEqual(@as(u32, 4), docs[1].class_id);
    try testing.expectEqualStrings("Transform", docs[1].type_name);
}

test "parse: stripped flag on PrefabInstance documents" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\--- !u!1 &500 stripped
        \\GameObject:
        \\  m_Name: NestedRoot
    ;
    const doc = try parseOne(arena, src);
    try testing.expect(doc.stripped);
}

test "parse: nested map and block sequence of refs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Component:
        \\  - component: {fileID: 4}
        \\  - component: {fileID: 114}
        \\  m_Layer: 0
    ;
    const doc = try parseOne(arena, src);
    const comps = model.findValue(doc.body.map, "m_Component").?;
    try testing.expectEqual(@as(usize, 2), comps.seq.len);
    const first = model.findValue(comps.seq[0].map, "component").?;
    try testing.expectEqual(@as(i64, 4), first.ref.file_id);
}

test "parse: ref with guid and type, and a non-ref flow map (vector)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\--- !u!114 &114
        \\MonoBehaviour:
        \\  m_Script: {fileID: 11500000, guid: abcdef0123456789, type: 3}
        \\  m_LocalPosition: {x: 1, y: 2, z: 3}
        \\  maxHp: 100
    ;
    const doc = try parseOne(arena, src);
    const script = model.findValue(doc.body.map, "m_Script").?;
    try testing.expectEqual(@as(i64, 11500000), script.ref.file_id);
    try testing.expectEqualStrings("abcdef0123456789", script.ref.guid.?);
    try testing.expectEqual(@as(i64, 3), script.ref.type_id.?);

    const pos = model.findValue(doc.body.map, "m_LocalPosition").?;
    // A flow map without fileID stays a .map, not a .ref.
    const x = model.findValue(pos.map, "x").?;
    try testing.expectEqualStrings("1", x.scalar);

    const hp = model.findValue(doc.body.map, "maxHp").?;
    try testing.expectEqualStrings("100", hp.scalar);
}

test "parse: multi-entry sequence map (modifications)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: Renamed
        \\      objectReference: {fileID: 0}
    ;
    const doc = try parseOne(arena, src);
    const mod = model.findValue(doc.body.map, "m_Modification").?;
    const mods = model.findValue(mod.map, "m_Modifications").?;
    try testing.expectEqual(@as(usize, 1), mods.seq.len);
    const item = mods.seq[0];
    try testing.expectEqualStrings("m_Name", model.findValue(item.map, "propertyPath").?.scalar);
    try testing.expectEqualStrings("Renamed", model.findValue(item.map, "value").?.scalar);
    try testing.expectEqual(@as(i64, 7), model.findValue(item.map, "target").?.ref.file_id);
}

test "parse: non-empty flow sequence of refs and scalars" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_List: [{fileID: 7}, 2]
    ;
    // parseFlowSeq's non-empty path: even with nested flow maps, split only on top-level
    // commas, parsing each element as a ref/scalar.
    const doc = try parseOne(arena, src);
    const list = model.findValue(doc.body.map, "m_List").?;
    try testing.expectEqual(@as(usize, 2), list.seq.len);
    try testing.expectEqual(@as(i64, 7), list.seq[0].ref.file_id);
    try testing.expectEqualStrings("2", list.seq[1].scalar);
}

test "parse: quoted scalar and empty flow seq" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: "Hello: World"
        \\  m_TagString: []
    ;
    const doc = try parseOne(arena, src);
    try testing.expectEqualStrings("Hello: World", model.findValue(doc.body.map, "m_Name").?.scalar);
    const tags = model.findValue(doc.body.map, "m_TagString").?;
    try testing.expectEqual(@as(usize, 0), tags.seq.len);
}

test "parse: block sequence of plain scalars" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Layers:
        \\  - Default
        \\  - Water
    ;
    const doc = try parseOne(arena, src);
    const layers = model.findValue(doc.body.map, "m_Layers").?;
    try testing.expectEqual(@as(usize, 2), layers.seq.len);
    try testing.expectEqualStrings("Default", layers.seq[0].scalar);
    try testing.expectEqualStrings("Water", layers.seq[1].scalar);
}

test "parse: same-indent sequence inside a sequence map item" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 7}
        \\      addedObjects:
        \\      - {fileID: 1}
        \\      - {fileID: 2}
    ;
    const doc = try parseOne(arena, src);
    const mod = model.findValue(doc.body.map, "m_Modification").?;
    const mods = model.findValue(mod.map, "m_Modifications").?;
    try testing.expectEqual(@as(usize, 1), mods.seq.len);
    const item = mods.seq[0];
    try testing.expectEqual(@as(i64, 7), model.findValue(item.map, "target").?.ref.file_id);
    const added = model.findValue(item.map, "addedObjects").?;
    try testing.expectEqual(@as(usize, 2), added.seq.len);
    try testing.expectEqual(@as(i64, 1), added.seq[0].ref.file_id);
    try testing.expectEqual(@as(i64, 2), added.seq[1].ref.file_id);
}

test "parse: deeply nested flow value is rejected instead of overflowing the stack" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A scale that reproduces the depth that once overflowed the stack (crashed at ~14000 levels).
    // 5000 is far beyond any sane limit yet fits within the 200 KB file budget.
    const depth = 5000;
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(arena, "--- !u!114 &1\nMonoBehaviour:\n  m_Field: ");
    for (0..depth) |_| try src.appendSlice(arena, "{a: ");
    try src.appendSlice(arena, "1");
    for (0..depth) |_| try src.append(arena, '}');

    try testing.expectError(error.NestingTooDeep, parse(arena, src.items));
}

test "parse: allocation failure reaches the caller" {
    var buffer: [1]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);

    try testing.expectError(
        error.OutOfMemory,
        parse(fixed.allocator(), "--- !u!1 &1\nGameObject:\n  m_Name: A\n"),
    );
}

test "parse: sequence document body degrades to an empty map instead of crashing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Unity never writes a sequence as a document body, but hostile input can. Downstream
    // reads body.map unconditionally, so body must always be a map.
    const src =
        \\--- !u!1 &1
        \\GameObject:
        \\  - rogue
    ;
    const doc = try parseOne(arena, src);
    try testing.expectEqual(@as(usize, 0), doc.body.map.len);
}

test "parse: non-scalar guid in a ref degrades to null instead of crashing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\--- !u!114 &1
        \\MonoBehaviour:
        \\  m_Script: {fileID: 1, guid: {x: 1}, type: 3}
    ;
    const doc = try parseOne(arena, src);
    const script = model.findValue(doc.body.map, "m_Script").?;
    try testing.expectEqual(@as(i64, 1), script.ref.file_id);
    try testing.expect(script.ref.guid == null);
}

test "parse: CRLF line endings parse identically to LF" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src = "--- !u!1 &123\r\nGameObject:\r\n  m_Name: Player\r\n  m_IsActive: 1\r\n";
    const doc = try parseOne(arena, src);
    try testing.expectEqual(@as(u32, 1), doc.class_id);
    try testing.expectEqual(@as(i64, 123), doc.file_id);
    try testing.expectEqualStrings("GameObject", doc.type_name);
    try testing.expectEqualStrings("Player", model.findValue(doc.body.map, "m_Name").?.scalar);
    try testing.expectEqualStrings("1", model.findValue(doc.body.map, "m_IsActive").?.scalar);
}

test "parse: comment lines are skipped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\# leading comment before any document
        \\--- !u!1 &1
        \\# a comment at the document's top level
        \\GameObject:
        \\  # a comment among fields
        \\  m_Name: Player
        \\  m_IsActive: 1
    ;
    const doc = try parseOne(arena, src);
    try testing.expectEqualStrings("Player", model.findValue(doc.body.map, "m_Name").?.scalar);
    try testing.expectEqualStrings("1", model.findValue(doc.body.map, "m_IsActive").?.scalar);
}

test "parse: double-quoted scalar resolves backslash escapes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: "a\"b\\c"
    ;
    // scalar holds the literal value, not the source form (\" -> ", \\ -> \).
    const doc = try parseOne(arena, src);
    try testing.expectEqualStrings("a\"b\\c", model.findValue(doc.body.map, "m_Name").?.scalar);
}

test "parse: malformed class id and anchor default to 0" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\--- !u!xx &yy
        \\GameObject:
        \\  m_Name: A
    ;
    // diff's first-occurrence-wins (duplicate fileID) relies on this fall-through to 0,
    // so pin that it degrades to 0 rather than a parse error.
    const doc = try parseOne(arena, src);
    try testing.expectEqual(@as(u32, 0), doc.class_id);
    try testing.expectEqual(@as(i64, 0), doc.file_id);
}

test "parse: single-quoted scalar is unquoted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: 'Hello: World'
    ;
    const doc = try parseOne(arena, src);
    try testing.expectEqualStrings("Hello: World", model.findValue(doc.body.map, "m_Name").?.scalar);
}

test "parseSpanned: quoted punctuation stays in one flow entry" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const src =
        \\--- !u!114 &1
        \\MonoBehaviour:
        \\  m_Double: {fileID: 7, guid: "a,b{c}\"d", type: 3}
        \\  m_Single: {fileID: 8, guid: 'a,b{c}''d', type: 3}
    ;

    const parsed = try parseSpanned(arena_state.allocator(), src);

    try testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);
    const double = model.findValue(parsed.documents[0].body.map, "m_Double").?;
    try testing.expectEqualStrings("a,b{c}\"d", double.ref.guid.?);
    const single = model.findValue(parsed.documents[0].body.map, "m_Single").?;
    try testing.expectEqualStrings("a,b{c}'d", single.ref.guid.?);
}

test "parseSpanned: nested object reference members produce diagnostics" {
    const nested_values = [_][]const u8{
        "{fileID: 1, extra: {value: 2}}",
        "{fileID: 1, extra: [2]}",
    };
    for (nested_values) |nested| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const src = try std.fmt.allocPrint(
            arena_state.allocator(),
            "--- !u!114 &1\nMonoBehaviour:\n  value: {s}\n",
            .{nested},
        );

        const parsed = try parseSpanned(arena_state.allocator(), src);

        try testing.expect(parsed.diagnostics.len != 0);
    }
}

test "parseSpanned: object reference fileID must be an integer scalar" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const parsed = try parseSpanned(
        arena_state.allocator(),
        "--- !u!114 &1\nMonoBehaviour:\n  value: {fileID: invalid}\n",
    );

    try testing.expect(parsed.diagnostics.len != 0);
}

test "parseSpanned: invalid double-quoted escapes produce diagnostics" {
    const invalid_values = [_][]const u8{
        "\"bad\\q\"",
        "\"bad\\x1\"",
        "{fileID: 0, guid: \"bad\\q\", type: 3}",
        "{fileID: 0, guid: \"bad\\u12\", type: 3}",
    };
    for (invalid_values) |invalid| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const src = try std.fmt.allocPrint(
            arena_state.allocator(),
            "--- !u!114 &1\nMonoBehaviour:\n  value: {s}\n",
            .{invalid},
        );

        const parsed = try parseSpanned(arena_state.allocator(), src);

        try testing.expect(parsed.diagnostics.len != 0);
    }
}

test "parseSpanned: quotes inside plain flow scalars stay plain" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const src =
        \\--- !u!114 &1
        \\MonoBehaviour:
        \\  m_Single: {x: can't, y: 2}
        \\  m_Double: {x: a"b, y: 2}
    ;

    const parsed = try parseSpanned(arena_state.allocator(), src);

    try testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);
    const single = model.findValue(parsed.documents[0].body.map, "m_Single").?;
    try testing.expectEqualStrings("can't", model.findValue(single.map, "x").?.scalar);
    try testing.expectEqualStrings("2", model.findValue(single.map, "y").?.scalar);
    const double = model.findValue(parsed.documents[0].body.map, "m_Double").?;
    try testing.expectEqualStrings("a\"b", model.findValue(double.map, "x").?.scalar);
    try testing.expectEqualStrings("2", model.findValue(double.map, "y").?.scalar);
}

test "parseSpanned: malformed flow values produce diagnostics and valid spans" {
    const malformed_values = [_][]const u8{
        "{fileID: 1, bad}",
        "{fileID: 1",
        "{fileID: 1, guid: \"bad}",
        "[{fileID: 1}",
    };
    for (malformed_values) |malformed| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const src = try std.fmt.allocPrint(
            arena_state.allocator(),
            "--- !u!114 &1\nMonoBehaviour:\n  value: {s}\n",
            .{malformed},
        );

        const parsed = try parseSpanned(arena_state.allocator(), src);

        try testing.expect(parsed.diagnostics.len != 0);
        var spans = parsed.entry_spans.iterator();
        while (spans.next()) |entry| {
            try testing.expect(entry.value_ptr.whole.end <= src.len);
            try testing.expect(entry.value_ptr.key.end <= src.len);
            try testing.expect(entry.value_ptr.value.end <= src.len);
        }
    }
}

test "parseSpanned: unterminated quoted scalar produces a diagnostic" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const parsed = try parseSpanned(
        arena_state.allocator(),
        "--- !u!114 &1\nMonoBehaviour:\n  value: \"unterminated\n",
    );

    try testing.expect(parsed.diagnostics.len != 0);
}

const Line = struct {
    indent: usize,
    text: []const u8,
    whole: source_map.Span,
    content: source_map.Span,
};

const Parser = struct {
    arena: std.mem.Allocator,
    lines: []const Line,
    source_bytes: []const u8,
    pos: usize = 0,
    node_spans: std.AutoHashMapUnmanaged(*const Node, source_map.Span) = .empty,
    entry_spans: std.AutoHashMapUnmanaged(*const Node, source_map.EntrySpan) = .empty,
    sequence_item_spans: std.AutoHashMapUnmanaged(*const Node, source_map.Span) = .empty,
    document_spans: std.ArrayList(source_map.DocumentSpan) = .empty,
    diagnostics: std.ArrayList(source_map.Diagnostic) = .empty,

    fn peek(self: *const Parser) ?Line {
        return if (self.pos < self.lines.len) self.lines[self.pos] else null;
    }
    fn advance(self: *Parser) ?Line {
        const l = self.peek() orelse return null;
        self.pos += 1;
        return l;
    }
};

// Break into meaningful logical lines (indent + content). Drop blank lines, `%` directives,
// and `#` comments.
fn tokenize(arena: std.mem.Allocator, source_bytes: []const u8) std.mem.Allocator.Error![]Line {
    var lines: std.ArrayList(Line) = .empty;
    var start: usize = 0;
    while (start <= source_bytes.len) {
        const end = std.mem.indexOfScalarPos(u8, source_bytes, start, '\n') orelse source_bytes.len;
        const whole_end = if (end < source_bytes.len) end + 1 else end;
        const raw_end = if (end > start and source_bytes[end - 1] == '\r') end - 1 else end;
        // Treat a leading UTF-8 BOM as metadata. Keep the original line span so
        // source patches still include the BOM and retain all original offsets.
        const bom_len: usize = if (start == 0 and std.mem.startsWith(u8, source_bytes, "\xEF\xBB\xBF")) 3 else 0;
        const raw_start = start + bom_len;
        const raw = source_bytes[raw_start..raw_end];
        var indent: usize = 0;
        while (indent < raw.len and raw[indent] == ' ') indent += 1;
        const content = raw[indent..];
        if (content.len != 0 and content[0] != '%' and content[0] != '#') {
            try lines.append(arena, .{
                .indent = indent,
                .text = content,
                .whole = .{ .start = start, .end = whole_end },
                .content = .{ .start = raw_start + indent, .end = raw_end },
            });
        }
        if (end == source_bytes.len) break;
        start = whole_end;
    }
    return lines.toOwnedSlice(arena);
}

pub fn parse(arena: std.mem.Allocator, source_bytes: []const u8) Error![]Document {
    return (try parseSpanned(arena, source_bytes)).documents;
}

pub fn parseSpanned(arena: std.mem.Allocator, source_bytes: []const u8) Error!source_map.ParsedFile {
    var p = Parser{ .arena = arena, .source_bytes = source_bytes, .lines = try tokenize(arena, source_bytes) };
    var docs: std.ArrayList(Document) = .empty;
    while (p.peek()) |line| {
        if (!std.mem.startsWith(u8, line.text, "---")) {
            _ = p.advance();
            continue;
        }
        const doc_start = line.whole.start;
        const header = line;
        try docs.append(arena, try parseDocument(&p));
        const doc_end = if (p.peek()) |next| next.whole.start else source_bytes.len;
        try p.document_spans.append(arena, .{
            .whole = .{ .start = doc_start, .end = doc_end },
            .header = header.content,
            .class_id = spanToken(source_bytes, header.text, header.content.start, "!u!"),
            .file_id = spanToken(source_bytes, header.text, header.content.start, "&"),
        });
    }
    return .{
        .bytes = source_bytes,
        .documents = try docs.toOwnedSlice(arena),
        .document_spans = try p.document_spans.toOwnedSlice(arena),
        .node_spans = p.node_spans,
        .entry_spans = p.entry_spans,
        .sequence_item_spans = p.sequence_item_spans,
        .diagnostics = try p.diagnostics.toOwnedSlice(arena),
        .line_ending = if (std.mem.indexOf(u8, source_bytes, "\r\n") != null) .crlf else .lf,
    };
}

fn parseDocument(p: *Parser) Error!Document {
    const header = p.advance().?; // "--- !u!1 &123 [stripped]"
    var class_id: u32 = 0;
    var file_id: i64 = 0;
    var stripped = false;
    var valid_class = false;
    var valid_file = false;
    var toks = std.mem.tokenizeScalar(u8, header.text, ' ');
    while (toks.next()) |t| {
        if (std.mem.startsWith(u8, t, "!u!")) {
            class_id = std.fmt.parseInt(u32, t[3..], 10) catch 0;
            valid_class = std.fmt.parseInt(u32, t[3..], 10) catch null != null;
        } else if (std.mem.startsWith(u8, t, "&")) {
            file_id = std.fmt.parseInt(i64, t[1..], 10) catch 0;
            valid_file = std.fmt.parseInt(i64, t[1..], 10) catch null != null;
        } else if (std.mem.eql(u8, t, "stripped")) {
            stripped = true;
        }
    }
    if (!valid_class or !valid_file) try p.diagnostics.append(p.arena, .invalid_document_header);

    var type_name: []const u8 = "";
    var body: *Node = undefined;
    if (p.peek()) |first| {
        if (!std.mem.startsWith(u8, first.text, "---")) {
            _ = p.advance(); // the "TypeName:" line at indent 0
            if (!std.mem.endsWith(u8, first.text, ":")) try p.diagnostics.append(p.arena, .missing_type_name);
            type_name = stripTrailingColon(first.text);
            body = try parseBlock(p, indentOfNext(p, 2), 0);
            // Downstream reads body.map unconditionally. A malformed body parsed as a
            // sequence must not escape as a non-map node.
            if (body.* != .map) body = try emptyMap(p.arena);
        } else {
            body = try emptyMap(p.arena);
        }
    } else {
        body = try emptyMap(p.arena);
    }

    return Document{
        .class_id = class_id,
        .file_id = file_id,
        .type_name = type_name,
        .stripped = stripped,
        .body = body,
    };
}

fn spanToken(source_bytes: []const u8, text: []const u8, text_start: usize, marker: []const u8) source_map.Span {
    const at = std.mem.indexOf(u8, text, marker) orelse return .{ .start = text_start, .end = text_start };
    const start = text_start + at + marker.len;
    var end = start;
    while (end < source_bytes.len and source_bytes[end] != ' ' and source_bytes[end] != '\r' and source_bytes[end] != '\n') end += 1;
    return .{ .start = start, .end = end };
}

fn spanForSlice(source_bytes: []const u8, slice: []const u8) ?source_map.Span {
    const source_start = @intFromPtr(source_bytes.ptr);
    const slice_start = @intFromPtr(slice.ptr);
    if (slice_start < source_start) return null;
    const start = slice_start - source_start;
    if (start > source_bytes.len or slice.len > source_bytes.len - start) return null;
    return .{ .start = start, .end = start + slice.len };
}

// Indent of the body's first field (Unity uses 2, handled leniently): peek at the next line,
// use its indent if deeper than 0, otherwise the default.
fn indentOfNext(p: *const Parser, default_indent: usize) usize {
    if (p.peek()) |l| if (l.indent > 0 and !std.mem.startsWith(u8, l.text, "---")) return l.indent;
    return default_indent;
}

// Unity YAML nesting is at most a few levels. A generously margined cap to reject
// hostile input that would overflow the stack up front.
const max_nesting_depth: usize = 128;

// Parse a block (mapping or sequence) whose entries line up exactly at `indent`.
fn parseBlock(p: *Parser, indent: usize, depth: usize) Error!*Node {
    if (depth > max_nesting_depth) return error.NestingTooDeep;
    const first = p.peek() orelse return emptyMap(p.arena);
    if (first.indent < indent or std.mem.startsWith(u8, first.text, "---")) return emptyMap(p.arena);
    if (std.mem.startsWith(u8, first.text, "- ") or std.mem.eql(u8, first.text, "-")) {
        return parseSeq(p, indent, depth);
    }
    return parseMap(p, indent, depth);
}

fn parseMap(p: *Parser, indent: usize, depth: usize) Error!*Node {
    var entries: std.ArrayList(Entry) = .empty;
    const start = if (p.peek()) |first| first.whole.start else 0;
    while (p.peek()) |line| {
        if (line.indent != indent) break;
        if (std.mem.startsWith(u8, line.text, "---")) break;
        if (std.mem.startsWith(u8, line.text, "- ") or std.mem.eql(u8, line.text, "-")) break;
        _ = p.advance();
        const kv = splitKeyValue(line.text);
        if (!kv.has_colon) try p.diagnostics.append(p.arena, .invalid_map_entry);
        const value = if (kv.value.len == 0)
            try parseNestedValue(p, indent, depth)
        else
            try parseValue(p, kv.value, depth);
        if (kv.has_colon) {
            const key_start = line.content.start + (@intFromPtr(kv.key.ptr) - @intFromPtr(line.text.ptr));
            const value_start = line.content.start + (@intFromPtr(kv.value.ptr) - @intFromPtr(line.text.ptr));
            try p.entry_spans.put(p.arena, value, .{ .whole = line.whole, .key = .{ .start = key_start, .end = key_start + kv.key.len }, .value = .{ .start = value_start, .end = value_start + kv.value.len } });
        }
        try entries.append(p.arena, .{ .key = kv.key, .value = value });
    }
    const node = try makeNode(p.arena, .{ .map = try entries.toOwnedSlice(p.arena) });
    const end = if (p.pos > 0) p.lines[p.pos - 1].whole.end else start;
    try p.node_spans.put(p.arena, node, .{ .start = start, .end = end });
    return node;
}

// Value of a "key:" line with nothing after the colon: a deeper-indented nested block,
// or a block sequence whose dashes line up at the key's own indent (a Unity convention,
// where `m_Component:` is immediately followed by `- component: {...}` at the same column).
// If neither, an empty map.
fn parseNestedValue(p: *Parser, key_indent: usize, depth: usize) Error!*Node {
    if (p.peek()) |next| {
        const is_dash = std.mem.startsWith(u8, next.text, "- ") or std.mem.eql(u8, next.text, "-");
        if (next.indent > key_indent or (is_dash and next.indent == key_indent)) {
            return parseBlock(p, next.indent, depth + 1);
        }
    }
    return emptyMap(p.arena);
}

fn parseSeq(p: *Parser, indent: usize, depth: usize) Error!*Node {
    var items: std.ArrayList(*Node) = .empty;
    const start = if (p.peek()) |first| first.whole.start else 0;
    while (p.peek()) |line| {
        if (line.indent != indent) break;
        if (!(std.mem.startsWith(u8, line.text, "- ") or std.mem.eql(u8, line.text, "-"))) break;
        _ = p.advance();
        const rest = if (line.text.len >= 2) std.mem.trimStart(u8, line.text[1..], " ") else "";
        if (rest.len == 0) {
            // Lone "-": this item's nested block continues at a deeper indent.
            const ci = indentOfNext(p, indent + 2);
            const item = try parseBlock(p, ci, depth + 1);
            const end = if (p.pos > 0) p.lines[p.pos - 1].whole.end else line.whole.end;
            try p.sequence_item_spans.put(p.arena, item, .{ .start = line.whole.start, .end = end });
            try items.append(p.arena, item);
        } else if (looksLikeMapEntry(rest)) {
            // Compact map item: the first entry is on the dash line, the rest at indent+2.
            const item = try parseSeqMapItem(p, indent, rest, depth, line.whole.start);
            const end = if (p.pos > 0) p.lines[p.pos - 1].whole.end else line.whole.end;
            try p.sequence_item_spans.put(p.arena, item, .{ .start = line.whole.start, .end = end });
            try items.append(p.arena, item);
        } else {
            const item = try parseValue(p, rest, depth);
            try p.sequence_item_spans.put(p.arena, item, line.whole);
            try items.append(p.arena, item);
        }
    }
    const node = try makeNode(p.arena, .{ .seq = try items.toOwnedSlice(p.arena) });
    const end = if (p.pos > 0) p.lines[p.pos - 1].whole.end else start;
    try p.node_spans.put(p.arena, node, .{ .start = start, .end = end });
    return node;
}

// A sequence item that is a mapping. Example:
//   - target: {fileID: 0}
//     propertyPath: m_Name
//     value: Foo
fn parseSeqMapItem(p: *Parser, dash_indent: usize, first_line: []const u8, depth: usize, item_start: usize) Error!*Node {
    var entries: std.ArrayList(Entry) = .empty;
    // All of the item's keys line up at the column right after "- ".
    const key_indent = dash_indent + 2;
    const kv = splitKeyValue(first_line);
    if (!kv.has_colon) try p.diagnostics.append(p.arena, .invalid_map_entry);
    if (kv.value.len == 0) {
        const value = try parseNestedValue(p, key_indent, depth);
        try entries.append(p.arena, .{ .key = kv.key, .value = value });
        try putEntrySpan(p, value, kv, spanForSlice(p.source_bytes, first_line), .invalid_map_entry);
    } else {
        const value = try parseValue(p, kv.value, depth);
        try entries.append(p.arena, .{ .key = kv.key, .value = value });
        try putEntrySpan(p, value, kv, spanForSlice(p.source_bytes, first_line), .invalid_map_entry);
    }
    // Continuation entries are 2 deeper than the dash (aligned right after "- ").
    while (p.peek()) |line| {
        if (line.indent != key_indent) break;
        if (std.mem.startsWith(u8, line.text, "- ") or std.mem.eql(u8, line.text, "-")) break;
        if (std.mem.startsWith(u8, line.text, "---")) break;
        _ = p.advance();
        const e = splitKeyValue(line.text);
        if (!e.has_colon) try p.diagnostics.append(p.arena, .invalid_map_entry);
        const value = if (e.value.len == 0)
            try parseNestedValue(p, key_indent, depth)
        else
            try parseValue(p, e.value, depth);
        try putEntrySpan(p, value, e, line.whole, .invalid_map_entry);
        try entries.append(p.arena, .{ .key = e.key, .value = value });
    }
    const node = try makeNode(p.arena, .{ .map = try entries.toOwnedSlice(p.arena) });
    const item_end = if (p.pos > 0) p.lines[p.pos - 1].whole.end else item_start;
    try p.node_spans.put(p.arena, node, .{ .start = item_start, .end = item_end });
    return node;
}

fn putEntrySpan(
    p: *Parser,
    value: *Node,
    kv: KV,
    whole: ?source_map.Span,
    diagnostic: source_map.Diagnostic,
) !void {
    const key = spanForSlice(p.source_bytes, kv.key) orelse {
        try p.diagnostics.append(p.arena, diagnostic);
        return;
    };
    const value_span = spanForSlice(p.source_bytes, kv.value) orelse {
        try p.diagnostics.append(p.arena, diagnostic);
        return;
    };
    try p.entry_spans.put(p.arena, value, .{
        .whole = whole orelse {
            try p.diagnostics.append(p.arena, diagnostic);
            return;
        },
        .key = key,
        .value = value_span,
    });
}

// ---------- helpers ----------

fn makeNode(arena: std.mem.Allocator, value: Node) std.mem.Allocator.Error!*Node {
    const n = try arena.create(Node);
    n.* = value;
    return n;
}

fn emptyMap(arena: std.mem.Allocator) std.mem.Allocator.Error!*Node {
    return makeNode(arena, .{ .map = &[_]Entry{} });
}

fn stripTrailingColon(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " ");
    return if (t.len > 0 and t[t.len - 1] == ':') t[0 .. t.len - 1] else t;
}

const KV = struct { key: []const u8, value: []const u8, has_colon: bool };

// Split "key: value" / "key:" at the first ": " or a trailing ":".
// Don't split inside a flow value (the value starts after the first colon).
fn splitKeyValue(line: []const u8) KV {
    // Find the first ":" followed by a space or end of line.
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == ':' and (i + 1 == line.len or line[i + 1] == ' ')) {
            const key = std.mem.trim(u8, line[0..i], " ");
            const value = std.mem.trim(u8, line[i + 1 ..], " ");
            return .{ .key = key, .value = value, .has_colon = true };
        }
    }
    return .{ .key = std.mem.trim(u8, line, " "), .value = line[line.len..], .has_colon = false };
}

fn looksLikeMapEntry(s: []const u8) bool {
    if (s.len > 0 and s[0] == '{') return false; // a flow value, not a map entry
    const kv = splitKeyValue(s);
    return kv.has_colon and kv.key.len > 0;
}

fn parseValue(p: *Parser, raw: []const u8, depth: usize) Error!*Node {
    const arena = p.arena;
    if (depth > max_nesting_depth) return error.NestingTooDeep;
    const s = std.mem.trim(u8, raw, " ");
    if (s.len == 0) return makeNode(arena, .{ .scalar = "" });
    const span = spanForSlice(p.source_bytes, s);
    const n = if (s[0] == '{') blk: {
        if (s.len < 2 or s[s.len - 1] != '}') try p.diagnostics.append(arena, .invalid_flow_value);
        break :blk try parseFlow(p, s, depth);
    } else if (s[0] == '[') blk: {
        if (s.len < 2 or s[s.len - 1] != ']') try p.diagnostics.append(arena, .invalid_flow_value);
        break :blk try parseFlowSeq(p, s, depth);
    } else blk: {
        if (!quotedScalarIsValid(s)) try p.diagnostics.append(arena, .invalid_flow_value);
        break :blk try makeNode(arena, .{ .scalar = try unquote(arena, s) });
    };
    if (span) |owned_span| {
        try p.node_spans.put(arena, n, owned_span);
    } else {
        try p.diagnostics.append(arena, .invalid_flow_value);
    }
    return n;
}

// Parse a flow mapping `{a: b, c: d}`. Returns a Ref node if it has a `fileID` key.
fn parseFlow(p: *Parser, s: []const u8, depth: usize) Error!*Node {
    const arena = p.arena;
    const inner = stripBrackets(s, '{', '}');
    var entries: std.ArrayList(Entry) = .empty;
    var it = splitTopLevel(inner);
    var iterator_error_reported = false;
    while (it.next()) |part| {
        if (it.invalid and !iterator_error_reported) {
            try p.diagnostics.append(arena, .invalid_flow_value);
            iterator_error_reported = true;
        }
        const kv = splitKeyValue(part);
        if (!kv.has_colon or kv.key.len == 0) {
            try p.diagnostics.append(arena, .invalid_flow_value);
            continue;
        }
        const value = try parseValue(p, kv.value, depth + 1);
        try putEntrySpan(p, value, kv, spanForSlice(p.source_bytes, part), .invalid_flow_value);
        try entries.append(arena, .{ .key = kv.key, .value = value });
    }
    if (it.invalid and !iterator_error_reported) try p.diagnostics.append(arena, .invalid_flow_value);
    const es = try entries.toOwnedSlice(arena);
    if (model.findValue(es, "fileID")) |fid_node| {
        var valid_reference = scalarToI64(fid_node) != null;
        for (es) |entry| {
            if (entry.value.* != .scalar) valid_reference = false;
        }
        if (!valid_reference) try p.diagnostics.append(arena, .invalid_flow_value);
        return makeNode(arena, .{ .ref = .{
            .file_id = scalarToI64(fid_node) orelse 0,
            .guid = if (model.findValue(es, "guid")) |g| scalarString(g) else null,
            .type_id = if (model.findValue(es, "type")) |t| scalarToI64(t) else null,
        } });
    }
    return makeNode(arena, .{ .map = es });
}

fn scalarString(n: *const Node) ?[]const u8 {
    return switch (n.*) {
        .scalar => |s| s,
        else => null,
    };
}

fn parseFlowSeq(p: *Parser, s: []const u8, depth: usize) Error!*Node {
    const arena = p.arena;
    const inner = std.mem.trim(u8, stripBrackets(s, '[', ']'), " ");
    var items: std.ArrayList(*Node) = .empty;
    if (inner.len != 0) {
        var it = splitTopLevel(inner);
        var iterator_error_reported = false;
        while (it.next()) |part| {
            if (it.invalid and !iterator_error_reported) {
                try p.diagnostics.append(arena, .invalid_flow_value);
                iterator_error_reported = true;
            }
            const t = std.mem.trim(u8, part, " ");
            if (t.len == 0) {
                try p.diagnostics.append(arena, .invalid_flow_value);
            } else {
                try items.append(arena, try parseValue(p, t, depth + 1));
            }
        }
        if (it.invalid and !iterator_error_reported) try p.diagnostics.append(arena, .invalid_flow_value);
    }
    return makeNode(arena, .{ .seq = try items.toOwnedSlice(arena) });
}

fn scalarToI64(n: *const Node) ?i64 {
    const s = scalarString(n) orelse return null;
    return std.fmt.parseInt(i64, std.mem.trim(u8, s, " "), 10) catch null;
}

fn stripBrackets(s: []const u8, open: u8, close: u8) []const u8 {
    var t = std.mem.trim(u8, s, " ");
    if (t.len >= 1 and t[0] == open) t = t[1..];
    if (t.len >= 1 and t[t.len - 1] == close) t = t[0 .. t.len - 1];
    return t;
}

fn quotedScalarIsValid(s: []const u8) bool {
    if (s[0] != '\'' and s[0] != '"') return true;
    const quote = s[0];
    var index: usize = 1;
    while (index < s.len) {
        if (quote == '"' and s[index] == '\\') {
            if (index + 1 >= s.len) return false;
            if (!supportedDoubleQuoteEscape(s[index + 1])) return false;
            index += 2;
            continue;
        }
        if (s[index] == quote) {
            if (quote == '\'' and index + 1 < s.len and s[index + 1] == '\'') {
                index += 2;
                continue;
            }
            return index + 1 == s.len;
        }
        index += 1;
    }
    return false;
}

fn supportedDoubleQuoteEscape(byte: u8) bool {
    return byte == '"' or byte == '\\';
}

// Strip enclosing quotes. Double-quoted scalars also resolve YAML backslash
// escapes `\"` and `\\` (the only escapes Unity emits), so that scalar
// holds the literal value rather than the source form.
fn unquote(arena: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]const u8 {
    if (s.len >= 2 and s[0] == '\'' and s[s.len - 1] == '\'') {
        const inner = s[1 .. s.len - 1];
        if (std.mem.indexOf(u8, inner, "''") == null) return inner;
        var out: std.ArrayList(u8) = .empty;
        var index: usize = 0;
        while (index < inner.len) : (index += 1) {
            try out.append(arena, inner[index]);
            if (inner[index] == '\'' and index + 1 < inner.len and inner[index + 1] == '\'')
                index += 1;
        }
        return out.toOwnedSlice(arena);
    }
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        const inner = s[1 .. s.len - 1];
        if (std.mem.indexOfScalar(u8, inner, '\\') == null) return inner;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < inner.len) : (i += 1) {
            const c = inner[i];
            if (c == '\\' and i + 1 < inner.len and (inner[i + 1] == '"' or inner[i + 1] == '\\')) {
                try out.append(arena, inner[i + 1]);
                i += 1;
            } else {
                try out.append(arena, c);
            }
        }
        return out.toOwnedSlice(arena);
    }
    return s;
}

// Iterator over comma-separated parts at brace/bracket depth 0.
const TopLevelIter = struct {
    s: []const u8,
    i: usize = 0,
    invalid: bool = false,

    fn next(self: *TopLevelIter) ?[]const u8 {
        if (self.i >= self.s.len) return null;
        var bracket_stack: [max_nesting_depth + 1]u8 = undefined;
        var depth: usize = 0;
        var quote: ?u8 = null;
        var scalar_start = true;
        const start = self.i;
        while (self.i < self.s.len) {
            const c = self.s[self.i];
            if (quote) |delimiter| {
                if (delimiter == '"' and c == '\\') {
                    if (self.i + 1 >= self.s.len) {
                        self.invalid = true;
                        self.i += 1;
                    } else {
                        if (!supportedDoubleQuoteEscape(self.s[self.i + 1])) self.invalid = true;
                        self.i += 2;
                    }
                    continue;
                }
                if (c == delimiter) {
                    if (delimiter == '\'' and self.i + 1 < self.s.len and self.s[self.i + 1] == '\'') {
                        self.i += 2;
                        continue;
                    }
                    quote = null;
                    scalar_start = false;
                }
                self.i += 1;
                continue;
            }
            switch (c) {
                '\'', '"' => if (scalar_start) {
                    quote = c;
                } else {
                    scalar_start = false;
                },
                ':' => scalar_start = true,
                '{' => {
                    if (depth == bracket_stack.len) {
                        self.invalid = true;
                    } else {
                        bracket_stack[depth] = '}';
                        depth += 1;
                    }
                    scalar_start = true;
                },
                '[' => {
                    if (depth == bracket_stack.len) {
                        self.invalid = true;
                    } else {
                        bracket_stack[depth] = ']';
                        depth += 1;
                    }
                    scalar_start = true;
                },
                '}', ']' => {
                    if (depth == 0 or bracket_stack[depth - 1] != c) {
                        self.invalid = true;
                    } else {
                        depth -= 1;
                    }
                    scalar_start = false;
                },
                ',' => if (depth == 0) {
                    const part = self.s[start..self.i];
                    self.i += 1;
                    if (self.i == self.s.len) self.invalid = true;
                    return part;
                } else {
                    scalar_start = true;
                },
                ' ', '\t' => {},
                else => scalar_start = false,
            }
            self.i += 1;
        }
        if (quote != null or depth != 0) self.invalid = true;
        return self.s[start..self.i];
    }
};

fn splitTopLevel(s: []const u8) TopLevelIter {
    return .{ .s = s };
}

/// Content sniff for UnityYAML. The extension allowlists in the products are
/// prefilters only; some .asset files are binary regardless of Force Text
/// (LightingDataAsset etc.), so the leading bytes are the ground truth.
/// Directives (%...) may precede the first document; anything else decides.
pub fn isUnityYaml(src: []const u8) bool {
    var head = src[0..@min(src.len, 512)];
    // Unity writes no BOM, but external tools may prepend one; parse() still
    // finds the documents, so the sniff must not disagree with it.
    if (std.mem.startsWith(u8, head, "\xEF\xBB\xBF")) head = head[3..];
    var lines = std.mem.splitScalar(u8, head, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "%TAG !u!")) return true;
        if (std.mem.startsWith(u8, line, "--- !u!")) return true;
        if (line.len == 0 or line[0] == '%') continue;
        return false;
    }
    return false;
}

test "isUnityYaml: accepts UnityYAML heads, rejects other content" {
    // Full Unity-written header: %YAML directive first, %TAG !u! second.
    try testing.expect(isUnityYaml("%YAML 1.1\n%TAG !u! tag:unity3d.com,2011:\n--- !u!1 &1\nGameObject:\n"));
    // Fixture-style head without directives: the document marker alone decides.
    try testing.expect(isUnityYaml("--- !u!114 &1\nMonoBehaviour:\n  hp: 1\n"));
    // CRLF must not defeat the prefix checks.
    try testing.expect(isUnityYaml("%YAML 1.1\r\n%TAG !u! tag:unity3d.com,2011:\r\n--- !u!1 &1\r\n"));
    // A UTF-8 BOM prepended by an external tool must not defeat the sniff:
    // parse() finds the documents regardless, so the sniff must agree.
    try testing.expect(isUnityYaml("\xEF\xBB\xBF%YAML 1.1\n%TAG !u! tag:unity3d.com,2011:\n--- !u!1 &1\n"));
    // A blank CRLF line before the first document is as skippable as its LF twin.
    try testing.expect(isUnityYaml("%YAML 1.1\r\n\r\n--- !u!1 &1\r\n"));

    // .meta files are YAML but not !u! documents.
    try testing.expect(!isUnityYaml("fileFormatVersion: 2\nguid: 0123456789abcdef0123456789abcdef\n"));
    // Plain YAML with a bare document marker is not UnityYAML.
    try testing.expect(!isUnityYaml("---\nfoo: 1\n"));
    // Binary content (e.g. a binary-serialized .asset) has no UnityYAML head.
    try testing.expect(!isUnityYaml("\x00\x01\x02binary"));
    // Empty input: an absent side is "missing", never "UnityYAML".
    try testing.expect(!isUnityYaml(""));
}
