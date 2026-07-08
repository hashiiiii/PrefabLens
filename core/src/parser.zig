const std = @import("std");
const model = @import("model.zig");
const Node = model.Node;
const Entry = model.Entry;
const Document = model.Document;

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

const Line = struct { indent: usize, text: []const u8 };

const Parser = struct {
    arena: std.mem.Allocator,
    lines: []const Line,
    pos: usize = 0,

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
fn tokenize(arena: std.mem.Allocator, source: []const u8) ![]Line {
    var lines: std.ArrayList(Line) = .empty;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw0| {
        var raw = raw0;
        if (raw.len > 0 and raw[raw.len - 1] == '\r') raw = raw[0 .. raw.len - 1];
        var indent: usize = 0;
        while (indent < raw.len and raw[indent] == ' ') indent += 1;
        const content = raw[indent..];
        if (content.len == 0) continue;
        if (content[0] == '%') continue;
        if (content[0] == '#') continue;
        try lines.append(arena, .{ .indent = indent, .text = content });
    }
    return lines.toOwnedSlice(arena);
}

pub fn parse(arena: std.mem.Allocator, source: []const u8) ![]Document {
    var p = Parser{ .arena = arena, .lines = try tokenize(arena, source) };
    var docs: std.ArrayList(Document) = .empty;
    while (p.peek()) |line| {
        if (!std.mem.startsWith(u8, line.text, "---")) {
            _ = p.advance();
            continue;
        }
        try docs.append(arena, try parseDocument(&p));
    }
    return docs.toOwnedSlice(arena);
}

fn parseDocument(p: *Parser) !Document {
    const header = p.advance().?; // "--- !u!1 &123 [stripped]"
    var class_id: u32 = 0;
    var file_id: i64 = 0;
    var stripped = false;
    var toks = std.mem.tokenizeScalar(u8, header.text, ' ');
    while (toks.next()) |t| {
        if (std.mem.startsWith(u8, t, "!u!")) {
            class_id = std.fmt.parseInt(u32, t[3..], 10) catch 0;
        } else if (std.mem.startsWith(u8, t, "&")) {
            file_id = std.fmt.parseInt(i64, t[1..], 10) catch 0;
        } else if (std.mem.eql(u8, t, "stripped")) {
            stripped = true;
        }
    }

    var type_name: []const u8 = "";
    var body: *Node = undefined;
    if (p.peek()) |first| {
        if (!std.mem.startsWith(u8, first.text, "---")) {
            _ = p.advance(); // the "TypeName:" line at indent 0
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
fn parseBlock(p: *Parser, indent: usize, depth: usize) anyerror!*Node {
    if (depth > max_nesting_depth) return error.NestingTooDeep;
    const first = p.peek() orelse return emptyMap(p.arena);
    if (first.indent < indent or std.mem.startsWith(u8, first.text, "---")) return emptyMap(p.arena);
    if (std.mem.startsWith(u8, first.text, "- ") or std.mem.eql(u8, first.text, "-")) {
        return parseSeq(p, indent, depth);
    }
    return parseMap(p, indent, depth);
}

fn parseMap(p: *Parser, indent: usize, depth: usize) anyerror!*Node {
    var entries: std.ArrayList(Entry) = .empty;
    while (p.peek()) |line| {
        if (line.indent != indent) break;
        if (std.mem.startsWith(u8, line.text, "---")) break;
        if (std.mem.startsWith(u8, line.text, "- ") or std.mem.eql(u8, line.text, "-")) break;
        _ = p.advance();
        const kv = splitKeyValue(line.text);
        const value = if (kv.value.len == 0)
            try parseNestedValue(p, indent, depth)
        else
            try parseValue(p.arena, kv.value, depth);
        try entries.append(p.arena, .{ .key = kv.key, .value = value });
    }
    return makeNode(p.arena, .{ .map = try entries.toOwnedSlice(p.arena) });
}

// Value of a "key:" line with nothing after the colon: a deeper-indented nested block,
// or a block sequence whose dashes line up at the key's own indent (a Unity convention,
// where `m_Component:` is immediately followed by `- component: {...}` at the same column).
// If neither, an empty map.
fn parseNestedValue(p: *Parser, key_indent: usize, depth: usize) anyerror!*Node {
    if (p.peek()) |next| {
        const is_dash = std.mem.startsWith(u8, next.text, "- ") or std.mem.eql(u8, next.text, "-");
        if (next.indent > key_indent or (is_dash and next.indent == key_indent)) {
            return parseBlock(p, next.indent, depth + 1);
        }
    }
    return emptyMap(p.arena);
}

fn parseSeq(p: *Parser, indent: usize, depth: usize) anyerror!*Node {
    var items: std.ArrayList(*Node) = .empty;
    while (p.peek()) |line| {
        if (line.indent != indent) break;
        if (!(std.mem.startsWith(u8, line.text, "- ") or std.mem.eql(u8, line.text, "-"))) break;
        _ = p.advance();
        const rest = if (line.text.len >= 2) std.mem.trimStart(u8, line.text[1..], " ") else "";
        if (rest.len == 0) {
            // Lone "-": this item's nested block continues at a deeper indent.
            const ci = indentOfNext(p, indent + 2);
            try items.append(p.arena, try parseBlock(p, ci, depth + 1));
        } else if (looksLikeMapEntry(rest)) {
            // Compact map item: the first entry is on the dash line, the rest at indent+2.
            try items.append(p.arena, try parseSeqMapItem(p, indent, rest, depth));
        } else {
            try items.append(p.arena, try parseValue(p.arena, rest, depth));
        }
    }
    return makeNode(p.arena, .{ .seq = try items.toOwnedSlice(p.arena) });
}

// A sequence item that is a mapping. Example:
//   - target: {fileID: 0}
//     propertyPath: m_Name
//     value: Foo
fn parseSeqMapItem(p: *Parser, dash_indent: usize, first_line: []const u8, depth: usize) anyerror!*Node {
    var entries: std.ArrayList(Entry) = .empty;
    // All of the item's keys line up at the column right after "- ".
    const key_indent = dash_indent + 2;
    const kv = splitKeyValue(first_line);
    if (kv.value.len == 0) {
        try entries.append(p.arena, .{ .key = kv.key, .value = try parseNestedValue(p, key_indent, depth) });
    } else {
        try entries.append(p.arena, .{ .key = kv.key, .value = try parseValue(p.arena, kv.value, depth) });
    }
    // Continuation entries are 2 deeper than the dash (aligned right after "- ").
    while (p.peek()) |line| {
        if (line.indent != key_indent) break;
        if (std.mem.startsWith(u8, line.text, "- ") or std.mem.eql(u8, line.text, "-")) break;
        if (std.mem.startsWith(u8, line.text, "---")) break;
        _ = p.advance();
        const e = splitKeyValue(line.text);
        const value = if (e.value.len == 0)
            try parseNestedValue(p, key_indent, depth)
        else
            try parseValue(p.arena, e.value, depth);
        try entries.append(p.arena, .{ .key = e.key, .value = value });
    }
    return makeNode(p.arena, .{ .map = try entries.toOwnedSlice(p.arena) });
}

// ---------- helpers ----------

fn makeNode(arena: std.mem.Allocator, value: Node) !*Node {
    const n = try arena.create(Node);
    n.* = value;
    return n;
}

fn emptyMap(arena: std.mem.Allocator) !*Node {
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
    return .{ .key = std.mem.trim(u8, line, " "), .value = "", .has_colon = false };
}

fn looksLikeMapEntry(s: []const u8) bool {
    if (s.len > 0 and s[0] == '{') return false; // a flow value, not a map entry
    const kv = splitKeyValue(s);
    return kv.has_colon and kv.key.len > 0;
}

fn parseValue(arena: std.mem.Allocator, raw: []const u8, depth: usize) anyerror!*Node {
    if (depth > max_nesting_depth) return error.NestingTooDeep;
    const s = std.mem.trim(u8, raw, " ");
    if (s.len == 0) return makeNode(arena, .{ .scalar = "" });
    if (s[0] == '{') return parseFlow(arena, s, depth);
    if (s[0] == '[') return parseFlowSeq(arena, s, depth);
    return makeNode(arena, .{ .scalar = try unquote(arena, s) });
}

// Parse a flow mapping `{a: b, c: d}`. Returns a Ref node if it has a `fileID` key.
fn parseFlow(arena: std.mem.Allocator, s: []const u8, depth: usize) anyerror!*Node {
    const inner = stripBrackets(s, '{', '}');
    var entries: std.ArrayList(Entry) = .empty;
    var it = splitTopLevel(inner);
    while (it.next()) |part| {
        const kv = splitKeyValue(part);
        if (kv.key.len == 0) continue;
        const value = try parseValue(arena, kv.value, depth + 1);
        try entries.append(arena, .{ .key = kv.key, .value = value });
    }
    const es = try entries.toOwnedSlice(arena);
    if (model.findValue(es, "fileID")) |fid_node| {
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

fn parseFlowSeq(arena: std.mem.Allocator, s: []const u8, depth: usize) anyerror!*Node {
    const inner = std.mem.trim(u8, stripBrackets(s, '[', ']'), " ");
    var items: std.ArrayList(*Node) = .empty;
    if (inner.len != 0) {
        var it = splitTopLevel(inner);
        while (it.next()) |part| {
            const t = std.mem.trim(u8, part, " ");
            if (t.len != 0) try items.append(arena, try parseValue(arena, t, depth + 1));
        }
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

// Strip enclosing quotes. Double-quoted scalars also resolve YAML backslash
// escapes `\"` and `\\` (the only escapes Unity emits), so that scalar
// holds the literal value rather than the source form.
fn unquote(arena: std.mem.Allocator, s: []const u8) anyerror![]const u8 {
    if (s.len >= 2 and s[0] == '\'' and s[s.len - 1] == '\'') {
        return s[1 .. s.len - 1];
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
    fn next(self: *TopLevelIter) ?[]const u8 {
        if (self.i >= self.s.len) return null;
        var depth: usize = 0;
        const start = self.i;
        while (self.i < self.s.len) : (self.i += 1) {
            const c = self.s[self.i];
            if (c == '{' or c == '[') depth += 1;
            if (c == '}' or c == ']') {
                if (depth > 0) depth -= 1;
            }
            if (c == ',' and depth == 0) {
                const part = self.s[start..self.i];
                self.i += 1;
                return part;
            }
        }
        return self.s[start..self.i];
    }
};

fn splitTopLevel(s: []const u8) TopLevelIter {
    return .{ .s = s };
}
