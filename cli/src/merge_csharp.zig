const std = @import("std");
const testing = std.testing;

pub const Kind = enum { ordered_array, int32_array, dictionary };
pub const Field = struct { name: []const u8, kind: Kind };

// A revision reader must inspect all available source declarations before read().
// Unknown syntax removes name evidence instead of inventing a type.
pub const Names = struct {
    serialize_field: bool = true,
    mono_behaviour: bool = true,

    pub const unknown: Names = .{ .serialize_field = false, .mono_behaviour = false };
};

pub fn find(fields: []const Field, name: []const u8) ?Kind {
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.kind;
    return null;
}

const Token = struct {
    text: []const u8,
    kind: enum { identifier, literal, punctuation },

    fn is(self: Token, value: []const u8) bool {
        return self.kind != .literal and std.mem.eql(u8, self.text, value);
    }
};
const LexError = std.mem.Allocator.Error || error{UnsupportedSource};

fn tokenize(arena: std.mem.Allocator, source: []const u8) LexError![]const Token {
    var result: std.ArrayList(Token) = .empty;
    var i: usize = 0;
    while (i < source.len) {
        if (std.ascii.isWhitespace(source[i])) {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, source[i..], "//")) {
            i += std.mem.indexOfScalar(u8, source[i..], '\n') orelse source.len - i;
            continue;
        }
        if (std.mem.startsWith(u8, source[i..], "/*")) {
            const close = std.mem.indexOf(u8, source[i + 2 ..], "*/") orelse return error.UnsupportedSource;
            i += close + 4;
            continue;
        }
        const start = i;
        const verbatim = std.mem.startsWith(u8, source[i..], "@\"");
        if (verbatim or source[i] == '"' or source[i] == '\'') {
            if (std.mem.startsWith(u8, source[i..], "\"\"\"")) return error.UnsupportedSource;
            if (verbatim) i += 1;
            const quote = source[i];
            i += 1;
            var closed = false;
            while (i < source.len) {
                if (!verbatim and source[i] == '\\') {
                    if (i + 1 >= source.len) return error.UnsupportedSource;
                    i += 2;
                } else if (source[i] == quote) {
                    i += 1;
                    if (verbatim and i < source.len and source[i] == quote) {
                        i += 1;
                    } else {
                        closed = true;
                        break;
                    }
                } else i += 1;
            }
            if (!closed) return error.UnsupportedSource;
            try result.append(arena, .{ .text = source[start..i], .kind = .literal });
            continue;
        }
        // Escaped identifiers and interpolation need the C# compiler's full lexer.
        if (source[i] >= 128 or source[i] == '@' or source[i] == '$' or source[i] == '\\') return error.UnsupportedSource;
        if (std.ascii.isAlphabetic(source[i]) or source[i] == '_') {
            i += 1;
            while (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '_')) : (i += 1) {}
            try result.append(arena, .{ .text = source[start..i], .kind = .identifier });
        } else {
            i += 1;
            try result.append(arena, .{ .text = source[start..i], .kind = .punctuation });
        }
    }
    return result.items;
}

pub fn inspectNames(arena: std.mem.Allocator, source: []const u8, names: *Names) std.mem.Allocator.Error!void {
    const tokens = tokenize(arena, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedSource => {
            names.* = .unknown;
            return;
        },
    };
    for (tokens, 0..) |token, i| {
        if (token.is("delegate") or token.is("#")) {
            names.* = .unknown;
            return;
        }
        if (token.is("namespace")) {
            var j = i + 1;
            while (j < tokens.len and !tokens[j].is("{") and !tokens[j].is(";")) : (j += 1) {
                if (tokens[j].is("SerializeField") or tokens[j].is("SerializeFieldAttribute")) names.serialize_field = false;
                if (tokens[j].is("MonoBehaviour")) names.mono_behaviour = false;
            }
        }
        const declaration = token.is("class") or token.is("struct") or token.is("interface") or
            token.is("record") or token.is("enum") or token.is("delegate");
        const alias = token.is("using") and i + 2 < tokens.len and tokens[i + 2].is("=");
        if ((!declaration and !alias) or i + 1 >= tokens.len) continue;
        const name = tokens[i + 1];
        if (name.is("SerializeField") or name.is("SerializeFieldAttribute") or name.is("UnityEngine")) names.serialize_field = false;
        if (name.is("MonoBehaviour") or name.is("UnityEngine")) names.mono_behaviour = false;
    }
}

// Used to reject script identities that appear in multiple source files.
// Counting simple names across namespaces is deliberately conservative.
pub fn declaredNames(arena: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error![]const []const u8 {
    const tokens = tokenize(arena, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedSource => return &.{},
    };
    var result: std.ArrayList([]const u8) = .empty;
    for (tokens, 0..) |token, i| {
        if ((token.is("class") or token.is("struct") or token.is("interface") or token.is("enum") or token.is("record")) and i + 1 < tokens.len) {
            try result.append(arena, tokens[i + 1].text);
        }
    }
    return result.items;
}

const Imports = struct { unity: bool = false };

pub fn read(arena: std.mem.Allocator, source: []const u8, class_name: []const u8, names: Names) std.mem.Allocator.Error![]const Field {
    const tokens = tokenize(arena, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedSource => return &.{},
    };
    var imports: Imports = .{};
    var target: ?usize = null;
    var scopes: std.ArrayList(bool) = .empty;
    var namespace_pending = false;
    for (tokens, 0..) |token, i| {
        if (token.is("namespace")) namespace_pending = true;
        if (token.is("{")) {
            try scopes.append(arena, namespace_pending);
            namespace_pending = false;
        }
        if (token.is(";")) namespace_pending = false;
        if (token.is("}")) _ = scopes.pop();
        if (token.is("#")) return &.{};
        if (token.is("using")) {
            var end = i + 1;
            while (end < tokens.len and !tokens[end].is(";")) : (end += 1) {
                if (tokens[end].is("=")) return &.{};
            }
            const path = tokens[i + 1 .. end];
            // Only file-scope imports are evidence. Namespace-local imports need
            // a richer scope resolver; never leak one namespace into another.
            if (scopes.items.len == 0 and pathIs(path, "UnityEngine")) imports.unity = true;
        }
        if (token.is("class") and i + 1 < tokens.len and tokens[i + 1].is(class_name)) {
            if (target != null) return &.{};
            for (scopes.items) |is_namespace| if (!is_namespace) return &.{};
            target = i;
        }
    }
    const class_at = target orelse return &.{};
    var prefix = class_at;
    while (prefix > 0 and !tokens[prefix - 1].is(";") and !tokens[prefix - 1].is("{") and !tokens[prefix - 1].is("}")) {
        prefix -= 1;
        if (tokens[prefix].is("partial")) return &.{};
    }
    if (!names.mono_behaviour or class_at + 3 >= tokens.len or !tokens[class_at + 2].is(":")) return &.{};
    var open = class_at + 3;
    while (open < tokens.len and !tokens[open].is("{")) : (open += 1) {}
    if (open == tokens.len) return &.{};
    const base = tokens[class_at + 3 .. open];
    if (!(pathIs(base, "UnityEngine.MonoBehaviour") or pathIs(base, "global::UnityEngine.MonoBehaviour") or
        (imports.unity and pathIs(base, "MonoBehaviour")))) return &.{};
    const close = match(tokens, open, "{", "}") orelse return &.{};

    var fields: std.ArrayList(Field) = .empty;
    var start = open + 1;
    var i = start;
    var initializer = false;
    while (i < close) : (i += 1) {
        if (tokens[i].is("=")) initializer = true;
        if (tokens[i].is("{")) {
            const end = match(tokens, i, "{", "}") orelse return &.{};
            if (!initializer) start = end + 1;
            i = end;
        } else if (tokens[i].is(";")) {
            if (fieldDeclaration(tokens[start..i], imports, names)) |field| {
                if (find(fields.items, field.name) != null) return &.{};
                try fields.append(arena, field);
            }
            start = i + 1;
            initializer = false;
        }
    }
    return fields.items;
}

fn match(tokens: []const Token, start: usize, open: []const u8, close: []const u8) ?usize {
    var depth: usize = 0;
    for (tokens[start..], start..) |token, i| {
        if (token.is(open)) depth += 1;
        if (token.is(close)) {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn pathIs(tokens: []const Token, expected: []const u8) bool {
    var offset: usize = 0;
    for (tokens) |token| {
        if (token.kind == .literal or offset > expected.len or !std.mem.startsWith(u8, expected[offset..], token.text)) return false;
        offset += token.text.len;
    }
    return offset == expected.len;
}

fn fieldDeclaration(declaration: []const Token, imports: Imports, names: Names) ?Field {
    var at: usize = 0;
    var serialized = false;
    var public = false;
    while (at < declaration.len and declaration[at].is("[")) {
        const end = match(declaration, at, "[", "]") orelse return null;
        var part = at + 1;
        var j = part;
        while (j <= end) : (j += 1) {
            if (j < end and declaration[j].is("(")) {
                j = match(declaration, j, "(", ")") orelse return null;
                continue;
            }
            if (j == end or declaration[j].is(",")) {
                var name_end = part;
                while (name_end < j and !declaration[name_end].is("(")) : (name_end += 1) {}
                const attr = declaration[part..name_end];
                const serialize = names.serialize_field and (pathIs(attr, "UnityEngine.SerializeField") or
                    pathIs(attr, "UnityEngine.SerializeFieldAttribute") or pathIs(attr, "global::UnityEngine.SerializeField") or
                    pathIs(attr, "global::UnityEngine.SerializeFieldAttribute") or
                    (imports.unity and (pathIs(attr, "SerializeField") or pathIs(attr, "SerializeFieldAttribute"))));
                if (serialize) {
                    serialized = true;
                } else {
                    // Unknown attributes may change serialization. Decline the
                    // field until its attribute identity is proven.
                    return null;
                }
                part = j + 1;
            }
        }
        at = end + 1;
    }
    while (at < declaration.len) : (at += 1) {
        const token = declaration[at];
        if (token.is("public")) {
            public = true;
        } else if (token.is("private") or token.is("protected") or token.is("internal")) {
            continue;
        } else if (token.is("static") or token.is("readonly") or token.is("const") or token.is("new") or token.is("event")) {
            return null;
        } else break;
    }
    if (!public and !serialized) return null;
    var end = at;
    while (end < declaration.len and !declaration[end].is("=")) : (end += 1) {}
    if (end < at + 2 or declaration[end - 1].kind != .identifier) return null;
    const field_name = declaration[end - 1].text;
    const type_tokens = declaration[at .. end - 1];
    if (dictionaryType(type_tokens)) return .{ .name = field_name, .kind = .dictionary };
    if (type_tokens.len < 3 or !type_tokens[type_tokens.len - 2].is("[") or !type_tokens[type_tokens.len - 1].is("]")) return null;
    const element = type_tokens[0 .. type_tokens.len - 2];
    for (element) |token| if (token.kind != .identifier and !token.is(".") and !token.is(":")) return null;
    return .{ .name = field_name, .kind = if (pathIs(element, "int")) .int32_array else .ordered_array };
}

fn dictionaryType(type_tokens: []const Token) bool {
    var lt: ?usize = null;
    for (type_tokens, 0..) |token, i| {
        if (token.is("<")) {
            lt = i;
            break;
        }
    }
    const open = lt orelse return false;
    if (open == 0) return false;
    const name = type_tokens[0..open];
    for (name) |token| if (token.kind != .identifier and !token.is(".") and !token.is(":")) return false;
    return pathIs(name, "Dictionary") or
        pathIs(name, "SerializedDictionary") or
        pathIs(name, "System.Collections.Generic.Dictionary") or
        pathIs(name, "UnityEngine.SerializedDictionary") or
        pathIs(name, "UnityEngine.UIElements.Experimental.SerializedDictionary");
}

test "C# collection schema recognizes serialized dictionaries" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const source =
        \\using System.Collections.Generic;
        \\using UnityEngine;
        \\public class Inventory : MonoBehaviour {
        \\  public Dictionary<string, int> stats;
        \\  public SerializedDictionary<string, float> named;
        \\  public int[] numbers;
        \\}
    ;
    const fields = try read(arena, source, "Inventory", .{});
    try testing.expectEqual(@as(usize, 3), fields.len);
    try testing.expectEqual(Kind.dictionary, find(fields, "stats").?);
    try testing.expectEqual(Kind.dictionary, find(fields, "named").?);
    try testing.expectEqual(Kind.int32_array, find(fields, "numbers").?);
}

test "C# collection schema recognizes direct serialized arrays" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const source =
        \\using System;
        \\using UnityEngine;
        \\namespace Game {
        \\public class Inventory : MonoBehaviour {
        \\  public int[] numbers = new[] { 1, 2 };
        \\  public string[] names;
        \\  [SerializeField] private Entry[] serialized;
        \\  public string[,] grid;
        \\  private int[] privateNumbers;
        \\  [NonSerialized] public int[] temporary;
        \\  public static int[] shared;
        \\  public readonly int[] fixedValues;
        \\  public int[] Property { get; set; }
        \\  public void Change() { int[] local = new[] { 3 }; }
        \\  [Serializable] public class Item { public int[] nested; }
        \\}
        \\}
    ;
    const fields = try read(arena, source, "Inventory", .{});
    try testing.expectEqual(@as(usize, 3), fields.len);
    try testing.expectEqual(Kind.int32_array, find(fields, "numbers").?);
    try testing.expectEqual(Kind.ordered_array, find(fields, "names").?);
    try testing.expectEqual(Kind.ordered_array, find(fields, "serialized").?);
}

test "C# schema ignores text inside comments and strings" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const source =
        \\using UnityEngine;
        \\// public class Example : MonoBehaviour { public int[] fake; }
        \\public class Example : MonoBehaviour {
        \\  /* [SerializeField] public int[] comment; */
        \\  public string text = "public int[] fake; } #if X";
        \\  public string more = @"quotes "" and } ;";
        \\  public int[] actual;
        \\}
    ;
    const fields = try read(memory.allocator(), source, "Example", .{});
    try testing.expectEqual(@as(usize, 1), fields.len);
    try testing.expectEqualStrings("actual", fields[0].name);
}

test "C# schema declines ambiguous declarations and serialization rules" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    for ([_][]const u8{
        "using UnityEngine; public partial class Example : MonoBehaviour { public int[] values; }",
        "using UnityEngine; public class Example : OtherBase { public int[] values; }",
        "using UnityEngine; public class Example<T> : MonoBehaviour { public int[] values; }",
        "using UnityEngine; public class Example : MonoBehaviour { #if A\npublic int[] values;\n#endif\n }",
        "using UnityEngine; using X = System.Int32; public class Example : MonoBehaviour { public X[] values; }",
        "using UnityEngine; public class Example : MonoBehaviour { public int[] values; } public class Example {}",
        "using UnityEngine; public class Example : MonoBehaviour { [SerializeReference] public int[] values; }",
        "using UnityEngine; class Outer { public class Example : MonoBehaviour { public int[] values; } }",
        "namespace Other { using UnityEngine; } namespace Game { public class Example : MonoBehaviour { public int[] values; } }",
        "using UnityEngine; class Example : MonoBehaviour { [Unknown] public int[] values; }",
        "using UnityEngine; class Example : MonoBehaviour { public int[][] values; }",
    }) |source| {
        try testing.expectEqual(@as(usize, 0), (try read(arena, source, "Example", .{})).len);
    }
}

test "C# schema requires unambiguous framework names" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const source = "using UnityEngine; public class Example : MonoBehaviour { [SerializeField] public Entry[] values; public int[] numbers; }";
    const fields = try read(arena, source, "Example", .{ .serialize_field = true });
    try testing.expectEqual(@as(usize, 2), fields.len);
    try testing.expectEqualStrings("values", fields[0].name);
    try testing.expectEqualStrings("numbers", fields[1].name);
    try testing.expectEqual(@as(usize, 0), (try read(arena, source, "Example", .{ .mono_behaviour = false })).len);
    const serialized = try read(arena, source, "Example", .{ .serialize_field = false });
    try testing.expectEqual(@as(usize, 1), serialized.len);
    try testing.expectEqualStrings("numbers", serialized[0].name);
}

test "C# project evidence detects shadowed framework types and aliases" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    var evidence: Names = .{};
    try inspectNames(memory.allocator(), "namespace Game { public class SerializeFieldAttribute {} }", &evidence);
    try testing.expect(!evidence.serialize_field);
    try testing.expect(evidence.mono_behaviour);
    try inspectNames(memory.allocator(), "global using MonoBehaviour = Other.Base;", &evidence);
    try testing.expect(!evidence.mono_behaviour);
}
