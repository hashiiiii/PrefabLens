const std = @import("std");
const model = @import("model.zig");
const parser = @import("parser.zig");
const source = @import("source.zig");
const testing = std.testing;

pub const Error = parser.Error || error{InvalidValue};
pub const Replacement = struct { span: source.Span, bytes: []const u8 };

pub fn parseValue(arena: std.mem.Allocator, input: []const u8) Error!*const model.Node {
    if (std.mem.indexOfAny(u8, input, "\r\n\x00") != null) return error.InvalidValue;
    try validateRawText(input);
    if (!std.mem.eql(u8, input, std.mem.trim(u8, input, " \t"))) return error.InvalidValue;
    const bytes = try std.fmt.allocPrint(arena, "--- !u!114 &1\nMonoBehaviour:\n  value: {s}\n", .{input});
    const parsed = try parser.parseSpanned(arena, bytes);
    if (parsed.diagnostics.len != 0 or parsed.documents.len != 1) return error.InvalidValue;
    const body = parsed.documents[0].body;
    if (body.* != .map or body.map.len != 1) return error.InvalidValue;
    const value = model.findValue(body.map, "value") orelse return error.InvalidValue;
    const raw = parsed.nodeBytes(value) orelse return error.InvalidValue;
    if (!std.mem.eql(u8, raw, input)) return error.InvalidValue;
    try validateFlowNode(arena, parsed, value);
    return value;
}

fn validateRawText(text: []const u8) Error!void {
    var iterator = (std.unicode.Utf8View.init(text) catch return error.InvalidValue).iterator();
    while (iterator.nextCodepoint()) |point| {
        if (point < 0x20 or (point >= 0x7f and point <= 0x9f) or point == 0xfffe or point == 0xffff)
            return error.InvalidValue;
    }
}

fn validatePlain(text: []const u8, key: bool) Error!void {
    if (text.len == 0) return error.InvalidValue;
    if (text[0] == '"' or text[0] == '\'') return;
    if (std.mem.indexOfScalar(u8, ",[]{}#&*!|>'\"%@`", text[0]) != null) return error.InvalidValue;
    if ((text[0] == '-' or text[0] == '?' or text[0] == ':') and
        (text.len == 1 or std.ascii.isWhitespace(text[1]))) return error.InvalidValue;
    for (text, 0..) |byte, i| {
        if (std.mem.indexOfScalar(u8, "[]{},", byte) != null) return error.InvalidValue;
        if (byte == ':' and (key or i + 1 == text.len or std.ascii.isWhitespace(text[i + 1]))) return error.InvalidValue;
        if (byte == '#' and (i == 0 or std.ascii.isWhitespace(text[i - 1]))) return error.InvalidValue;
    }
}

fn validateFlowNode(arena: std.mem.Allocator, parsed: source.ParsedFile, node: *const model.Node) Error!void {
    switch (node.*) {
        .scalar => try validatePlain(parsed.nodeBytes(node) orelse return error.InvalidValue, false),
        .ref => {},
        .seq => |items| for (items) |item| try validateFlowNode(arena, parsed, item),
        .map => |entries| for (entries) |entry| {
            try validatePlain(entry.key, true);
            if (entry.key[0] == '"' or entry.key[0] == '\'') _ = try decodeScalar(arena, entry.key);
            try validateFlowNode(arena, parsed, entry.value);
        },
    }
}

pub fn flow(arena: std.mem.Allocator, node: *const model.Node) Error![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    try appendFlow(arena, &output, node, 0);
    return output.toOwnedSlice(arena);
}

fn appendFlow(arena: std.mem.Allocator, output: *std.ArrayList(u8), node: *const model.Node, depth: usize) Error!void {
    if (depth > 128) return error.InvalidValue;
    switch (node.*) {
        .scalar => |scalar| try appendScalar(arena, output, scalar),
        .ref => |ref| {
            try output.appendSlice(arena, try std.fmt.allocPrint(arena, "{{fileID: {d}", .{ref.file_id}));
            if (ref.guid) |guid| {
                try output.appendSlice(arena, ", guid: ");
                try appendScalar(arena, output, guid);
            }
            if (ref.type_id) |type_id| try output.appendSlice(arena, try std.fmt.allocPrint(arena, ", type: {d}", .{type_id}));
            try output.append(arena, '}');
        },
        .seq => |items| {
            try output.append(arena, '[');
            for (items, 0..) |item, i| {
                if (i != 0) try output.appendSlice(arena, ", ");
                try appendFlow(arena, output, item, depth + 1);
            }
            try output.append(arena, ']');
        },
        .map => |entries| {
            try output.append(arena, '{');
            for (entries, 0..) |entry, i| {
                if (i != 0) try output.appendSlice(arena, ", ");
                // Entry keys retain their encoded source token, unlike scalar values.
                try validatePlain(entry.key, true);
                if (entry.key[0] == '"' or entry.key[0] == '\'') _ = try decodeScalar(arena, entry.key);
                try output.appendSlice(arena, entry.key);
                try output.appendSlice(arena, ": ");
                try appendFlow(arena, output, entry.value, depth + 1);
            }
            try output.append(arena, '}');
        },
    }
}

fn appendScalar(arena: std.mem.Allocator, output: *std.ArrayList(u8), scalar: []const u8) Error!void {
    // Node scalars contain decoded text. A quote in that text is a literal quote.
    var iterator = (std.unicode.Utf8View.init(scalar) catch return error.InvalidValue).iterator();
    var control = false;
    while (iterator.nextCodepoint()) |point| {
        if (point < 0x20 or (point >= 0x7f and point <= 0x9f) or point == 0x2028 or point == 0x2029 or
            point == 0xfeff or point == 0xfffe or point == 0xffff) control = true;
    }
    if (scalar.len == 0 or control or std.mem.indexOfAny(u8, scalar, "[]{},:#\"\\") != null or
        std.mem.indexOfScalar(u8, "'&*!|>%@`?", scalar[0]) != null or
        (scalar[0] == '-' and (scalar.len == 1 or std.ascii.isWhitespace(scalar[1]))) or
        std.ascii.isWhitespace(scalar[0]) or std.ascii.isWhitespace(scalar[scalar.len - 1]))
    {
        return output.appendSlice(arena, try @import("yaml_scalar.zig").quote(arena, scalar));
    }
    try output.appendSlice(arena, scalar);
}

pub fn completeEntrySpan(file: source.ParsedFile, node: *const model.Node) ?source.Span {
    const entry = file.entry_spans.get(node) orelse return null;
    const span = file.node_spans.get(node) orelse return entry.whole;
    return .{ .start = @min(entry.whole.start, span.start), .end = @max(entry.whole.end, span.end) };
}

pub fn replaceEntry(
    arena: std.mem.Allocator,
    ours: source.ParsedFile,
    original: *const model.Node,
    result: *const model.Node,
    inputs: []const source.ParsedFile,
) Error!Replacement {
    const entry = ours.entry_spans.get(original) orelse return error.InvalidValue;
    const span = completeEntrySpan(ours, original) orelse return error.InvalidValue;
    // Selecting a complete side must also select its formatting and comments.
    for (inputs) |input| {
        if (completeEntrySpan(input, result)) |selected| {
            const selected_entry = input.entry_spans.get(result).?;
            if (entry.key.start - entry.whole.start != selected_entry.key.start - selected_entry.whole.start) continue;
            const bytes = selected.bytes(input.bytes);
            const needs_separator = span.end < ours.bytes.len and span.end > 0 and ours.bytes[span.end - 1] == '\n' and
                !std.mem.endsWith(u8, bytes, "\n");
            return .{ .span = span, .bytes = if (needs_separator)
                try std.mem.concat(arena, u8, &.{ bytes, ours.lineEndingAt(span.end - 1) })
            else
                bytes };
        }
    }
    const original_bytes = ours.nodeBytes(original) orelse entry.value.bytes(ours.bytes);
    const block_sequence = original.* == .seq and !std.mem.startsWith(u8, std.mem.trimStart(u8, original_bytes, " \r\n"), "[");
    var output: std.ArrayList(u8) = .empty;
    if (result.* == .seq and result.seq.len > 0 and block_sequence) {
        const header_end = lineEnd(ours.bytes, entry.key.start);
        const header = ours.bytes[span.start..header_end];
        try output.appendSlice(arena, header);
        const ending = ours.lineEndingAt(entry.whole.start);
        if (!std.mem.endsWith(u8, header, "\n")) try output.appendSlice(arena, ending);
        const first_item = ours.sequence_item_spans.get(original.seq[0]) orelse return error.InvalidValue;
        const first_bytes = first_item.bytes(ours.bytes);
        const indent = leadingSpaces(first_bytes);
        for (result.seq) |item| {
            var preserved = false;
            for (inputs) |input| {
                const raw = input.sequenceItemBytes(item) orelse continue;
                const content = std.mem.trimStart(u8, raw, " ");
                if (!std.mem.startsWith(u8, content, "- ") and !std.mem.startsWith(u8, content, "-\n") and
                    !std.mem.startsWith(u8, content, "-\r\n")) continue;
                try appendIndented(arena, &output, raw, indent);
                if (!std.mem.endsWith(u8, raw, "\n")) try output.appendSlice(arena, ending);
                preserved = true;
                break;
            }
            if (!preserved) {
                try output.appendNTimes(arena, ' ', indent);
                try output.appendSlice(arena, "- ");
                try appendFlow(arena, &output, item, 0);
                try output.appendSlice(arena, ending);
            }
        }
    } else {
        const value = try flow(arena, result);
        const value_span = entry.value;
        if (value_span.start < span.start or value_span.end > span.end) return error.InvalidValue;
        try output.appendSlice(arena, ours.bytes[span.start..value_span.start]);
        if (value_span.start > span.start and ours.bytes[value_span.start - 1] == ':') try output.append(arena, ' ');
        try output.appendSlice(arena, value);
        if (block_sequence) {
            // The value span is empty on the header of an indentation-based sequence.
            try output.appendSlice(arena, ours.bytes[value_span.end..lineEnd(ours.bytes, entry.key.start)]);
        } else try output.appendSlice(arena, ours.bytes[value_span.end..span.end]);
    }
    return .{ .span = span, .bytes = try output.toOwnedSlice(arena) };
}

fn lineEnd(bytes: []const u8, offset: usize) usize {
    return if (std.mem.indexOfScalarPos(u8, bytes, offset, '\n')) |end| end + 1 else bytes.len;
}

fn leadingSpaces(bytes: []const u8) usize {
    var count: usize = 0;
    while (count < bytes.len and bytes[count] == ' ') : (count += 1) {}
    return count;
}

fn appendIndented(arena: std.mem.Allocator, output: *std.ArrayList(u8), raw: []const u8, indent: usize) Error!void {
    const old_indent = leadingSpaces(raw);
    if (old_indent == indent) return output.appendSlice(arena, raw);
    var at: usize = 0;
    while (at < raw.len) {
        const end = lineEnd(raw, at);
        const line = raw[at..end];
        if (std.mem.trim(u8, line, " \r\n").len == 0) {
            try output.appendSlice(arena, line);
        } else {
            if (leadingSpaces(line) < old_indent) return error.InvalidValue;
            try output.appendNTimes(arena, ' ', indent);
            try output.appendSlice(arena, line[old_indent..]);
        }
        at = end;
    }
}

const decodeScalar = @import("yaml_scalar.zig").decode;

test "collection YAML flow keeps quoted punctuation and object references" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const input = "[{name: \"A,B\", value: 10}, {fileID: 42, guid: 0123456789abcdef0123456789abcdef, type: 3}, 'it''s safe']";
    const node = try parseValue(arena, input);
    const result = try flow(arena, node);
    try testing.expect(model.Node.eql(node, try parseValue(arena, result)));
    try testing.expectError(error.InvalidValue, parseValue(arena, "[A]\n  other: injected"));
    try testing.expectError(error.InvalidValue, parseValue(arena, "[A, {broken]"));
}

test "collection YAML preserves unchanged block items and surrounding CRLF bytes" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const bytes = "--- !u!114 &1\r\nMonoBehaviour:\r\n  names: # names\r\n  - A # first\r\n  - 'B'\r\n  other: 1 # untouched\r\n";
    const parsed = try parser.parseSpanned(arena, bytes);
    const names = model.findValue(parsed.documents[0].body.map, "names").?;
    const added = try parseValue(arena, "\"C,D\"");
    var items = [_]*model.Node{ names.seq[0], names.seq[1], @constCast(added) };
    const result = model.Node{ .seq = &items };
    const patch = try replaceEntry(arena, parsed, names, &result, &.{parsed});
    try testing.expectEqualStrings("  names: # names\r\n  - A # first\r\n  - 'B'\r\n  - \"C,D\"\r\n", patch.bytes);
    try testing.expectEqualStrings("  names: # names\r\n  - A # first\r\n  - 'B'\r\n", patch.span.bytes(bytes));
}

test "collection YAML switches an empty block to a sequence without touching its comment" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const parsed = try parser.parseSpanned(arena, "--- !u!114 &1\nMonoBehaviour:\n  names: [] # keep\n");
    const names = model.findValue(parsed.documents[0].body.map, "names").?;
    const result = try parseValue(arena, "[A, B]");
    const patch = try replaceEntry(arena, parsed, names, result, &.{parsed});
    try testing.expectEqualStrings("  names: [A, B] # keep\n", patch.bytes);
}

test "collection YAML decodes scalar quotes and Unicode" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    try testing.expectEqualStrings("plain", try decodeScalar(arena, "plain"));
    try testing.expectEqualStrings("it's", try decodeScalar(arena, "'it''s'"));
    try testing.expectEqualStrings("A\nB", try decodeScalar(arena, "\"A\\nB\""));
    try testing.expectEqualStrings("日本語", try decodeScalar(arena, "\"\\u65e5\\u672c\\u8a9e\""));
    try testing.expectEqualStrings("\xf0\x9d\x84\x9e", try decodeScalar(arena, "\"\\U0001d11e\""));
    try testing.expectError(error.InvalidValue, decodeScalar(arena, "\"\\x0g\""));
    try testing.expectError(error.InvalidValue, decodeScalar(arena, "\"\\u0_41\""));
    try testing.expectError(error.InvalidValue, decodeScalar(arena, "\"unterminated"));
}

test "collection YAML keeps empty sequences and literal scalar text distinct" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const parsed = try parser.parseSpanned(arena, "--- !u!114 &1\nMonoBehaviour:\n  names: # keep\n  - A\n  other: 1\n");
    const names = model.findValue(parsed.documents[0].body.map, "names").?;
    const empty = model.Node{ .seq = &.{} };
    const patch = try replaceEntry(arena, parsed, names, &empty, &.{parsed});
    try testing.expectEqualStrings("  names: [] # keep\n", patch.bytes);
    for ([_][]const u8{ "\"quoted\"", "A\nB", "\x07", "-1", "\\u0041", "'literal'" }) |literal| {
        const node = model.Node{ .scalar = literal };
        try testing.expectEqualStrings(literal, (try parseValue(arena, try flow(arena, &node))).scalar);
    }
}

test "collection YAML does not read a hash inside scalar text as a comment" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const parsed = try parser.parseSpanned(arena, "--- !u!114 &1\nMonoBehaviour:\n  names: [\"A # B\", 'C # D', it's] # comment\n  description: it's text # comment\n  hash: A#B\n");
    try testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);
    const body = parsed.documents[0].body.map;
    const names = model.findValue(body, "names").?;
    try testing.expectEqualStrings("A # B", names.seq[0].scalar);
    try testing.expectEqualStrings("C # D", names.seq[1].scalar);
    try testing.expectEqualStrings("it's", names.seq[2].scalar);
    try testing.expectEqualStrings("it's text", model.findValue(body, "description").?.scalar);
    try testing.expectEqualStrings("A#B", model.findValue(body, "hash").?.scalar);
}

test "regression indented unchanged item" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const al = a.allocator();
    const f = try parser.parseSpanned(al, "--- !u!114 &1\nMonoBehaviour:\n  names:\n    - 'A' # keep item\n  other: 1\n");
    const old = model.findValue(f.documents[0].body.map, "names").?;
    const b = try parseValue(al, "B");
    var items = [_]*model.Node{ old.seq[0], @constCast(b) };
    const n = model.Node{ .seq = &items };
    const patch = try replaceEntry(al, f, old, &n, &.{f});
    try std.testing.expect(std.mem.indexOf(u8, patch.bytes, "    - 'A' # keep item\n") != null);
}
test "regression compact nested collection" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const al = a.allocator();
    const f = try parser.parseSpanned(al, "--- !u!114 &1\nMonoBehaviour:\n  items:\n  - names: # keep header\n    - A # keep item\n    other: 1\n");
    const old = model.findValue(model.findValue(f.documents[0].body.map, "items").?.seq[0].map, "names").?;
    const b = try parseValue(al, "B");
    var items = [_]*model.Node{ old.seq[0], @constCast(b) };
    const n = model.Node{ .seq = &items };
    const patch = try replaceEntry(al, f, old, &n, &.{f});
    const merged = try std.fmt.allocPrint(al, "{s}{s}{s}", .{ f.bytes[0..patch.span.start], patch.bytes, f.bytes[patch.span.end..] });
    const parsed = try parser.parseSpanned(al, merged);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);
}
test "regression map key roundtrip" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const al = a.allocator();
    const n = try parseValue(al, "{\"key\": value}");
    const out = try flow(al, n);
    try std.testing.expect(model.Node.eql(n, try parseValue(al, out)));
}
test "regression invalid YAML" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const al = a.allocator();
    // Invalid edits must fail, not become a different quoted string.
    for ([_][]const u8{ "[@bad]", "[a: b: c]", "[a\x01b]", "[|]", "{\"\\x0g\": A}", "{\"key\"suffix: A}", "{\"\\uD800\": A}", "# comment" }) |input| {
        try std.testing.expectError(error.InvalidValue, parseValue(al, input));
    }
}
test "regression plain apostrophe after comma before hash" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const al = a.allocator();
    const f = try parser.parseSpanned(al, "--- !u!114 &1\nMonoBehaviour:\n  text: comma,'quote # actual comment\n");
    const n = model.findValue(f.documents[0].body.map, "text").?;
    try std.testing.expectEqualStrings("comma,'quote", n.scalar);
}
test "regression selected side missing final newline" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const al = a.allocator();
    const ours = try parser.parseSpanned(al, "--- !u!114 &1\nMonoBehaviour:\n  names: [A]\n  other: 1\n");
    const theirs = try parser.parseSpanned(al, "--- !u!114 &1\nMonoBehaviour:\n  names: [B]");
    const old = model.findValue(ours.documents[0].body.map, "names").?;
    const n = model.findValue(theirs.documents[0].body.map, "names").?;
    const patch = try replaceEntry(al, ours, old, n, &.{ ours, theirs });
    const merged = try std.fmt.allocPrint(al, "{s}{s}{s}", .{ ours.bytes[0..patch.span.start], patch.bytes, ours.bytes[patch.span.end..] });
    const parsed = try parser.parseSpanned(al, merged);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);
}
test "regression escaped C1 must stay escaped" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const al = a.allocator();
    const node = try parseValue(al, "\"\\x80\"");
    const out = try flow(al, node);
    try std.testing.expect(std.mem.indexOf(u8, out, "\xc2\x80") == null);
}
test "regression scalar truncated escapes and nesting bounds" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const al = a.allocator();
    for ([_][]const u8{ "\"\\x\"", "\"\\x0\"", "\"\\u\"", "\"\\u123\"", "\"\\U0000000\"", "\"\\uD800\"", "\"\\uD800\\uDC0\"", "\"\\U00110000\"", "\"\\uDC00\"" }) |input| {
        try std.testing.expectError(error.InvalidValue, decodeScalar(al, input));
    }
    var node = model.Node{ .scalar = "leaf" };
    var ptr: *model.Node = &node;
    for (0..130) |_| {
        const items = try al.alloc(*model.Node, 1);
        items[0] = ptr;
        ptr = try al.create(model.Node);
        ptr.* = .{ .seq = items };
    }
    try std.testing.expectError(error.InvalidValue, flow(al, ptr));
    var input: std.ArrayList(u8) = .empty;
    try input.appendNTimes(al, '[', 130);
    try input.appendSlice(al, "A");
    try input.appendNTimes(al, ']', 130);
    const parsed = parseValue(al, input.items);
    if (parsed) |_| return error.ExpectedDepthRejection else |err| try std.testing.expect(err == error.NestingTooDeep or err == error.InvalidValue);
}
