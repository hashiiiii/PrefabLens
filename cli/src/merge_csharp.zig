const std = @import("std");
const testing = std.testing;

pub const Kind = enum { ordered_array, int32_array, string_dictionary, int32_dictionary };
pub const ValueType = enum { int32, string };
pub const DictionaryEquality = enum { unknown, default };
pub const Field = struct {
    name: []const u8,
    kind: Kind,
    dictionary_value: ?ValueType = null,
    dictionary_equality: DictionaryEquality = .unknown,
};

// A revision reader must inspect all available source declarations before read().
// Unknown assemblies or syntax remove name evidence instead of inventing a type.
pub const Names = struct {
    dictionary: bool = true,
    serialize_field: bool = true,
    mono_behaviour: bool = true,
    // Immutable tokens from all available revision sources, for replacement
    // evidence that can originate in another script.
    sources: std.ArrayList([]const Token) = .empty,

    pub const unknown: Names = .{ .dictionary = false, .serialize_field = false, .mono_behaviour = false };
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
    try names.sources.append(arena, tokens);
    for (tokens, 0..) |token, i| {
        if (token.is("delegate") or token.is("#")) {
            names.* = .unknown;
            return;
        }
        if (token.is("namespace")) {
            var j = i + 1;
            while (j < tokens.len and !tokens[j].is("{") and !tokens[j].is(";")) : (j += 1) {
                if (tokens[j].is("Dictionary")) names.dictionary = false;
                if (tokens[j].is("SerializeField") or tokens[j].is("SerializeFieldAttribute")) names.serialize_field = false;
                if (tokens[j].is("MonoBehaviour")) names.mono_behaviour = false;
            }
        }
        const declaration = token.is("class") or token.is("struct") or token.is("interface") or
            token.is("record") or token.is("enum") or token.is("delegate");
        const alias = token.is("using") and i + 2 < tokens.len and tokens[i + 2].is("=");
        if ((!declaration and !alias) or i + 1 >= tokens.len) continue;
        const name = tokens[i + 1];
        if (name.is("Dictionary") or name.is("System")) names.dictionary = false;
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

const Imports = struct { unity: bool = false, generic: bool = false };

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
            // Only file-scope imports are evidence. Namespace-local imports require
            // a richer scope resolver; never leak one namespace into another.
            if (scopes.items.len == 0) {
                if (pathIs(path, "UnityEngine")) imports.unity = true;
                if (pathIs(path, "System.Collections.Generic")) imports.generic = true;
            }
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
    for (fields.items) |*field| {
        if (field.dictionary_value == null) continue;
        if (mayReplaceDictionary(tokens, field.*)) field.dictionary_equality = .unknown;
        for (names.sources.items) |project_tokens| {
            if (mayReplaceDictionary(project_tokens, field.*)) field.dictionary_equality = .unknown;
        }
    }
    return fields.items;
}

// Comparer is immutable: reads, entry mutation, and by-value aliases cannot
// replace the field's dictionary. We only decline replacement/alias hazards.
fn mayReplaceDictionary(tokens: []const Token, field: Field) bool {
    for (tokens, 0..) |token, i| {
        if (token.is("unsafe") or token.is("dynamic") or token.is("__makeref") or
            token.is("Unsafe") or token.is("MemoryMarshal") or token.is("GetField") or
            token.is("GetFields") or token.is("FieldInfo") or token.is("SetValue")) return true;
        if (!token.is(field.name)) continue;
        if (byReference(tokens, i) or tupleTarget(tokens, i)) return true;
        if (assignmentRhs(tokens, i)) |rhs| {
            if (!defaultReplacement(tokens, rhs, field)) return true;
        }
    }
    return false;
}

fn openingBefore(tokens: []const Token, at: usize, open: []const u8, close: []const u8) ?usize {
    var depth: usize = 0;
    var i = at + 1;
    while (i > 0) {
        i -= 1;
        if (tokens[i].is(close)) depth += 1;
        if (tokens[i].is(open)) {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn byReference(tokens: []const Token, at: usize) bool {
    // Walk only this receiver expression; ref/out in a preceding call does not
    // expose the dictionary field. Calls/indexers/generics can form a receiver.
    var start = at;
    while (start > 0 and tokens[start - 1].is(".")) {
        start -= 1;
        if (start == 0) return true;
        while (start > 0 and (tokens[start - 1].is(")") or tokens[start - 1].is("]") or tokens[start - 1].is(">"))) {
            const close = tokens[start - 1].text;
            const open = if (tokens[start - 1].is(")")) "(" else if (tokens[start - 1].is("]")) "[" else "<";
            start = openingBefore(tokens, start - 1, open, close) orelse return true;
        }
        // After a grouped receiver, ref/out/in is an argument modifier,
        // not a callable identifier belonging to the receiver.
        if (start > 0 and tokens[start - 1].kind == .identifier and
            !tokens[start - 1].is("ref") and !tokens[start - 1].is("out") and !tokens[start - 1].is("in")) start -= 1;
    }
    while (start > 0 and tokens[start - 1].is("(")) start -= 1;
    if (start == 0) return false;
    const prefix = tokens[start - 1];
    if (prefix.is("ref") or prefix.is("out")) return true;
    // 'in' in a foreach statement reads the dictionary by value.
    return prefix.is("in") and (start < 2 or tokens[start - 2].is("(") or tokens[start - 2].is(","));
}

fn tupleTarget(tokens: []const Token, at: usize) bool {
    // A tuple can assign dictionary entries without replacing dictionary storage.
    if (at + 1 < tokens.len and (tokens[at + 1].is("[") or tokens[at + 1].is("."))) return false;
    var i = at;
    while (i > 0) {
        i -= 1;
        if (tokens[i].is(";") or tokens[i].is("{") or tokens[i].is("}")) return false;
        if (!tokens[i].is("(")) continue;
        const end = match(tokens, i, "(", ")") orelse return true;
        if (end > at and end + 1 < tokens.len and tokens[end + 1].is("=") and
            (end + 2 == tokens.len or (!tokens[end + 2].is("=") and !tokens[end + 2].is(">")))) return true;
        // An inner tuple can end at a comma. Its enclosing tuple may still
        // be an assignment target, so inspect all enclosing parentheses.
    }
    return false;
}

fn assignmentRhs(tokens: []const Token, at: usize) ?usize {
    var next = at + 1;
    while (next < tokens.len and tokens[next].is(")")) : (next += 1) {}
    if (next >= tokens.len) return null;
    if (tokens[next].is("=")) {
        if (next + 1 < tokens.len and (tokens[next + 1].is("=") or tokens[next + 1].is(">"))) return null;
        return next + 1;
    }
    if (next + 2 < tokens.len and tokens[next].is("?") and tokens[next + 1].is("?") and tokens[next + 2].is("=")) return next + 3;
    // Unsupported assignment operators must not look like harmless reads.
    if (next + 1 < tokens.len and tokens[next + 1].is("=") and
        (tokens[next].is("+") or tokens[next].is("-") or tokens[next].is("*") or tokens[next].is("/"))) return tokens.len;
    return null;
}

fn expressionBoundary(tokens: []const Token, at: usize) bool {
    return at == tokens.len or tokens[at].is(";") or tokens[at].is(",") or tokens[at].is(")") or tokens[at].is("}");
}

fn hasGenericImport(tokens: []const Token) bool {
    var depth: usize = 0;
    for (tokens, 0..) |token, i| {
        if (token.is("{")) depth += 1;
        if (token.is("}") and depth > 0) depth -= 1;
        if (depth != 0 or !token.is("using")) continue;
        var end = i + 1;
        while (end < tokens.len and !tokens[end].is(";")) : (end += 1) {}
        if (pathIs(tokens[i + 1 .. end], "System.Collections.Generic")) return true;
    }
    return false;
}

fn dictionaryType(tokens: []const Token, field: Field, short: bool) bool {
    var angle: usize = 0;
    while (angle < tokens.len and !tokens[angle].is("<")) : (angle += 1) {}
    if (angle + 5 != tokens.len or !tokens[angle + 2].is(",") or !tokens[angle + 4].is(">")) return false;
    if (!(pathIs(tokens[0..angle], "System.Collections.Generic.Dictionary") or
        pathIs(tokens[0..angle], "global::System.Collections.Generic.Dictionary") or
        (short and pathIs(tokens[0..angle], "Dictionary")))) return false;
    return switch (field.kind) {
        .string_dictionary => tokens[angle + 1].is("string") and tokens[angle + 3].is("int"),
        .int32_dictionary => tokens[angle + 1].is("int") and tokens[angle + 3].is("string"),
        else => false,
    };
}

fn defaultConstructionEnd(tokens: []const Token, at: usize, field: Field) ?usize {
    if (at >= tokens.len or !tokens[at].is("new")) return null;
    var next = at + 1;
    const target_typed = next < tokens.len and tokens[next].is("(");
    if (!target_typed) {
        while (next < tokens.len and !tokens[next].is("(") and !tokens[next].is("{")) : (next += 1) {}
        if (!dictionaryType(tokens[at + 1 .. next], field, hasGenericImport(tokens))) return null;
    }
    var called = false;
    if (next < tokens.len and tokens[next].is("(")) {
        if (next + 1 >= tokens.len or !tokens[next + 1].is(")")) return null;
        next += 2;
        called = true;
    }
    if (next < tokens.len and tokens[next].is("{")) {
        next = (match(tokens, next, "{", "}") orelse return null) + 1;
    } else if (!called) return null;
    return next;
}

fn defaultReplacement(tokens: []const Token, rhs: usize, field: Field) bool {
    if (defaultConstructionEnd(tokens, rhs, field)) |end| return expressionBoundary(tokens, end);
    // A local by-value alias rooted in proven default construction is also safe.
    // Do not infer arbitrary factory returns or aliases from other scopes.
    if (rhs >= tokens.len or tokens[rhs].kind != .identifier or !expressionBoundary(tokens, rhs + 1)) return false;
    const alias = tokens[rhs].text;
    var start = rhs;
    var depth: usize = 0;
    while (start > 0) {
        start -= 1;
        if (tokens[start].is("}")) depth += 1;
        if (tokens[start].is("{")) {
            if (depth == 0) break;
            depth -= 1;
        }
    }
    var declaration: ?usize = null;
    var lexical_depth: usize = 0;
    for (tokens[start..rhs], start..) |token, i| {
        if (token.is("{")) lexical_depth += 1;
        if (token.is("}")) {
            if (lexical_depth == 0) return false;
            lexical_depth -= 1;
        }
        // Only a complete local declaration in this exact block is evidence.
        // Closed child scopes and for/using statement variables cannot supply
        // an alias visible here. Outer-scope aliases remain unsupported.
        if (lexical_depth != 1 or !token.is(alias) or i < 2 or !tokens[i - 1].is("var") or
            i + 1 >= rhs or !tokens[i + 1].is("=")) continue;
        if (!tokens[i - 2].is("{") and !tokens[i - 2].is("}") and !tokens[i - 2].is(";")) continue;
        if (declaration != null) return false;
        declaration = i;
    }
    const declared = declaration orelse return false;
    const init_end = defaultConstructionEnd(tokens, declared + 2, field) orelse return false;
    if (init_end >= rhs or !expressionBoundary(tokens, init_end)) return false;
    for (tokens[declared + 1 .. rhs], declared + 1..) |token, i| {
        if (!token.is(alias)) continue;
        if (byReference(tokens, i) or tupleTarget(tokens, i)) return false;
        if (assignmentRhs(tokens, i)) |replacement| {
            const end = defaultConstructionEnd(tokens, replacement, field) orelse return false;
            if (!expressionBoundary(tokens, end)) return false;
        }
    }
    return true;
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
        if (token.kind == .literal or !std.mem.startsWith(u8, expected[offset..], token.text)) return false;
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
                    // Unknown attributes may change serialization. This intentionally
                    // declines presentation attributes until their identity is proven.
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
    if (type_tokens.len >= 3 and type_tokens[type_tokens.len - 2].is("[") and type_tokens[type_tokens.len - 1].is("]")) {
        const element = type_tokens[0 .. type_tokens.len - 2];
        for (element) |token| if (token.kind != .identifier and !token.is(".") and !token.is(":")) return null;
        return .{ .name = field_name, .kind = if (pathIs(element, "int")) .int32_array else .ordered_array };
    }
    if (!serialized or !names.dictionary) return null;
    var angle: usize = 0;
    while (angle < type_tokens.len and !type_tokens[angle].is("<")) : (angle += 1) {}
    if (angle == type_tokens.len) return null;
    if (!(pathIs(type_tokens[0..angle], "System.Collections.Generic.Dictionary") or
        pathIs(type_tokens[0..angle], "global::System.Collections.Generic.Dictionary") or
        (imports.generic and pathIs(type_tokens[0..angle], "Dictionary")))) return null;
    const angle_end = match(type_tokens, angle, "<", ">") orelse return null;
    if (angle_end + 1 != type_tokens.len or angle_end != angle + 4 or !type_tokens[angle + 2].is(",")) return null;
    const key = type_tokens[angle + 1];
    const value = type_tokens[angle + 3];
    const kind: Kind = if (key.is("string") and value.is("int")) .string_dictionary else if (key.is("int") and value.is("string")) .int32_dictionary else return null;
    const value_type: ValueType = if (value.is("int")) .int32 else .string;
    if (end < declaration.len) {
        const init = declaration[end + 1 ..];
        if (init.len < 3 or !init[0].is("new") or !init[init.len - 2].is("(") or !init[init.len - 1].is(")")) return null;
        const init_type = init[1 .. init.len - 2];
        if (init_type.len != 0) {
            if (init_type.len != type_tokens.len) return null;
            for (init_type, type_tokens) |actual, expected| if (!actual.is(expected.text)) return null;
        }
    }
    return .{ .name = field_name, .kind = kind, .dictionary_value = value_type, .dictionary_equality = .default };
}

test "C# collection schema recognizes direct serialized fields" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const source =
        \\using System;
        \\using System.Collections.Generic;
        \\using UnityEngine;
        \\namespace Game {
        \\public class Inventory : MonoBehaviour {
        \\  public int[] numbers = new[] { 1, 2 };
        \\  public string[] names;
        \\  [SerializeField] private Dictionary<string, int> counts = new Dictionary<string, int>();
        \\  [UnityEngine.SerializeField] public System.Collections.Generic.Dictionary<int, string> byNumber;
        \\  public Dictionary<string, int> notSerialized;
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
    try testing.expectEqual(@as(usize, 4), fields.len);
    try testing.expectEqual(Kind.int32_array, find(fields, "numbers").?);
    try testing.expectEqual(Kind.ordered_array, find(fields, "names").?);
    try testing.expectEqual(Kind.string_dictionary, find(fields, "counts").?);
    try testing.expectEqual(Kind.int32_dictionary, find(fields, "byNumber").?);
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
    // Unsupported syntax cannot authorize a type interpretation of historical YAML.
    for ([_][]const u8{
        "using UnityEngine; public partial class Example : MonoBehaviour { public int[] values; }",
        "using UnityEngine; public class Example : OtherBase { public int[] values; }",
        "using UnityEngine; public class Example<T> : MonoBehaviour { public int[] values; }",
        "using UnityEngine; public class Example : MonoBehaviour { #if A\npublic int[] values;\n#endif\n }",
        "using UnityEngine; using X = System.Int32; public class Example : MonoBehaviour { public X[] values; }",
        "using UnityEngine; public class Example : MonoBehaviour { public int[] values; } public class Example {}",
        "using UnityEngine; public class Example : MonoBehaviour { [SerializeReference] public int[] values; }",
    }) |source| {
        try testing.expectEqual(@as(usize, 0), (try read(arena, source, "Example", .{})).len);
    }
}

test "C# schema requires unambiguous framework names" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const source = "using UnityEngine; using System.Collections.Generic; public class Example : MonoBehaviour { [SerializeField] public Dictionary<string, int> values; public int[] numbers; }";
    const fields = try read(arena, source, "Example", .{ .dictionary = false });
    try testing.expectEqual(@as(usize, 1), fields.len);
    try testing.expectEqualStrings("numbers", fields[0].name);
    try testing.expectEqual(@as(usize, 0), (try read(arena, source, "Example", .{ .mono_behaviour = false })).len);
    const serialized = try read(arena, source, "Example", .{ .serialize_field = false });
    try testing.expectEqual(@as(usize, 1), serialized.len);
    // A type with key/value fields is still an ordered array.
    const array = try read(arena, "using UnityEngine; public class Example : MonoBehaviour { public Entry[] values; }", "Example", .{});
    try testing.expectEqual(Kind.ordered_array, find(array, "values").?);
}

test "C# project evidence detects shadowed framework types and aliases" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    var evidence: Names = .{};
    try inspectNames(memory.allocator(), "namespace Game { public class Dictionary<T, U> {} public class SerializeFieldAttribute {} }", &evidence);
    try testing.expect(!evidence.dictionary);
    try testing.expect(!evidence.serialize_field);
    try testing.expect(evidence.mono_behaviour);
    try inspectNames(memory.allocator(), "global using MonoBehaviour = Other.Base;", &evidence);
    try testing.expect(!evidence.mono_behaviour);
}

test "C# schema rejects nested targets and unrelated namespace imports" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    for ([_][]const u8{
        "using UnityEngine; class Outer { public class Example : MonoBehaviour { public int[] values; } }",
        "namespace Other { using UnityEngine; } namespace Game { public class Example : MonoBehaviour { public int[] values; } }",
        "using UnityEngine; class Example : MonoBehaviour { [global::System.NonSerializedAttribute] public int[] values; }",
        "using UnityEngine; class Example : MonoBehaviour { [UnityEngine.SerializeReferenceAttribute] public int[] values; }",
        "using UnityEngine; class Example : MonoBehaviour { [Unknown] public int[] values; }",
        "using UnityEngine; class Example : MonoBehaviour { public int[][] values; }",
    }) |source| try testing.expectEqual(@as(usize, 0), (try read(memory.allocator(), source, "Example", .{})).len);
}

test "C# schema declines custom dictionary comparers and custom keys" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    for ([_][]const u8{
        "using UnityEngine; using System.Collections.Generic; class Example : MonoBehaviour { [SerializeField] Dictionary<string, int> values = new Dictionary<string, int>(System.StringComparer.OrdinalIgnoreCase); }",
        "using UnityEngine; using System.Collections.Generic; class Example : MonoBehaviour { [SerializeField] Dictionary<string, int> values = Factory(); }",
        "using UnityEngine; using System.Collections.Generic; class Example : MonoBehaviour { [SerializeField] Dictionary<MyKey, int> values; }",
    }) |source| try testing.expectEqual(@as(usize, 0), (try read(memory.allocator(), source, "Example", .{})).len);
}

test "C# name inspection declines delegate and namespace shadowing" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    for ([_][]const u8{ "delegate void SerializeField();", "namespace Dictionary { class Something {} }" }) |source| {
        var names: Names = .{};
        try inspectNames(memory.allocator(), source, &names);
        try testing.expect(!names.serialize_field or !names.dictionary);
    }
}

test "C# dictionary descriptors reject unproven value types" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    for ([_][]const u8{ "System.Action", "System.IDisposable", "Unknown", "int[]", "Dictionary<string,int>", "long", "string", "int, int" }) |value| {
        const source = try std.fmt.allocPrint(arena, "using UnityEngine; using System.Collections.Generic; class Example : MonoBehaviour {{ [SerializeField] Dictionary<string,{s}> values; }}", .{value});
        var names: Names = .{};
        try inspectNames(arena, source, &names);
        try testing.expectEqual(@as(usize, 0), (try read(arena, source, "Example", names)).len);
    }
}

test "C# supported dictionaries retain their complete primitive value evidence" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const source = "using UnityEngine; using System.Collections.Generic; class Example : MonoBehaviour { [SerializeField] Dictionary<string,int> counts; [SerializeField] Dictionary<int,string> labels; }";
    var names: Names = .{};
    try inspectNames(arena, source, &names);
    const fields = try read(arena, source, "Example", names);
    try testing.expectEqual(@as(usize, 2), fields.len);
    try testing.expectEqualStrings("counts", fields[0].name);
    try testing.expectEqual(ValueType.int32, fields[0].dictionary_value.?);
    try testing.expectEqual(DictionaryEquality.default, fields[0].dictionary_equality);
    try testing.expectEqualStrings("labels", fields[1].name);
    try testing.expectEqual(ValueType.string, fields[1].dictionary_value.?);
    try testing.expectEqual(DictionaryEquality.default, fields[1].dictionary_equality);
}

test "C# dictionary comparer evidence is unknown after constructor and body references" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    for ([_][]const u8{
        "public Example() { values = new Dictionary<string,int>(System.StringComparer.OrdinalIgnoreCase); }",
        "public void Replace() { this.values = new Dictionary<string,int>(System.StringComparer.OrdinalIgnoreCase); }",
        "public void Replace() { values ??= Factory(); }",
        "public void Replace() { ReplaceByReference(ref values); }",
        "public void Replace() { ReplaceByReference(out values); }",
        "public void Replace() { ref Dictionary<string,int> alias = ref values; alias = Factory(); }",
        "public Dictionary<string,int> Property { set { values = value; } }",
    }) |body| {
        const source = try std.fmt.allocPrint(arena, "using UnityEngine; using System.Collections.Generic; public class Example : MonoBehaviour {{ [SerializeField] Dictionary<string,int> values; {s} }}", .{body});
        var names: Names = .{};
        try inspectNames(arena, source, &names);
        const fields = try read(arena, source, "Example", names);
        try testing.expectEqual(@as(usize, 1), fields.len);
        try testing.expectEqual(ValueType.int32, fields[0].dictionary_value.?);
        try testing.expectEqual(DictionaryEquality.unknown, fields[0].dictionary_equality);
    }
}

test "C# dictionary reads and entry mutations preserve default comparer evidence" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    for ([_][]const u8{
        "public void Use() { var n = values.Count; values.TryGetValue(\"A\", out var old); }",
        "public void Use() { values.Add(\"A\",1); values.Remove(\"B\"); values.Clear(); values[\"A\"] = 2; values[\"B\"]++; }",
        "public void Use() { var alias = values; alias.Add(\"A\",1); alias = Factory(); }",
        "public void Use() { Consume(values); foreach (var pair in values) Consume(pair); }",
        "public void Use() { if (Try(out var unrelated) && values.Count > 0) Consume(values); }",
        "public Example() { values = new Dictionary<string,int>(); }",
        "public void Use() { this.values ??= new(); }",
        "public void Use() { values = new Dictionary<string,int> { { \"A\", 1 } }; }",
        "public void Use() { var replacement = new Dictionary<string,int> { { \"A\", 1 } }; foreach (var pair in values) replacement.Add(pair.Key,pair.Value); values = replacement; }",
    }) |body| {
        const source = try std.fmt.allocPrint(arena, "using UnityEngine; using System.Collections.Generic; public class Example : MonoBehaviour {{ [SerializeField] Dictionary<string,int> values; {s} }}", .{body});
        var names: Names = .{};
        try inspectNames(arena, source, &names);
        const fields = try read(arena, source, "Example", names);
        try testing.expectEqual(@as(usize, 1), fields.len);
        try testing.expectEqual(DictionaryEquality.default, fields[0].dictionary_equality);
    }
}

test "C# replacement aliases and unsafe mutation keep equality unknown" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    for ([_][]const u8{
        "public void Replace() { Consume(in this.values); }",
        "public ref Dictionary<string,int> Ref() { return ref values; }",
        "public void Replace() { (values, other) = Factory(); }",
        "public void Replace() { var replacement = new Dictionary<string,int>(); replacement = Factory(); values = replacement; }",
        "public void Replace() { var replacement = new Dictionary<string,int>(); Consume(ref replacement); values = replacement; }",
        "public void Replace() { values = new Dictionary<string,int>().WithComparer(); }",
        "public void Replace() { typeof(Example).GetField(\"values\").SetValue(this, Factory()); }",
        "public unsafe void Replace() { ModifyMemory(); }",
    }) |body| {
        const source = try std.fmt.allocPrint(arena, "using UnityEngine; using System.Collections.Generic; public class Example : MonoBehaviour {{ [SerializeField] Dictionary<string,int> values; {s} }}", .{body});
        var names: Names = .{};
        try inspectNames(arena, source, &names);
        const fields = try read(arena, source, "Example", names);
        try testing.expectEqual(@as(usize, 1), fields.len);
        try testing.expectEqual(DictionaryEquality.unknown, fields[0].dictionary_equality);
    }
}

test "fix review closed nested scope alias" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const source = "using UnityEngine; using System.Collections.Generic; public class Example : MonoBehaviour { [SerializeField] Dictionary<string,int> values; Dictionary<string,int> replacement = new Dictionary<string,int>(System.StringComparer.OrdinalIgnoreCase); public Example() { { var replacement = new Dictionary<string,int>(); } values = replacement; } }";
    var names: Names = .{};
    try inspectNames(arena, source, &names);
    const fields = try read(arena, source, "Example", names);
    try testing.expectEqual(@as(usize, 1), fields.len);
    try testing.expectEqual(DictionaryEquality.unknown, fields[0].dictionary_equality);
}

test "fix review nested tuple replacement" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const source = "using UnityEngine; using System.Collections.Generic; public class Example : MonoBehaviour { [SerializeField] Dictionary<string,int> values; int other; int third; public Example() { ((values, other), third) = ((new Dictionary<string,int>(System.StringComparer.OrdinalIgnoreCase), 1), 2); } }";
    var names: Names = .{};
    try inspectNames(arena, source, &names);
    const fields = try read(arena, source, "Example", names);
    try testing.expectEqual(@as(usize, 1), fields.len);
    try testing.expectEqual(DictionaryEquality.unknown, fields[0].dictionary_equality);
}

test "fix review parenthesized receiver reference" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const source = "using UnityEngine; using System.Collections.Generic; public class Example : MonoBehaviour { [SerializeField] Dictionary<string,int> values; public Example() { Replace(ref (this).values); } static void Replace(ref Dictionary<string,int> target) { target = new Dictionary<string,int>(System.StringComparer.OrdinalIgnoreCase); } }";
    var names: Names = .{};
    try inspectNames(arena, source, &names);
    const fields = try read(arena, source, "Example", names);
    try testing.expectEqual(@as(usize, 1), fields.len);
    try testing.expectEqual(DictionaryEquality.unknown, fields[0].dictionary_equality);
}

test "C# scoped aliases and grouped receivers retain conservative replacement evidence" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    for ([_][]const u8{
        "Dictionary<string,int> replacement = Factory(); public void Use() { for (var replacement = new Dictionary<string,int>(); Flag();) { } values = replacement; }",
        "public void Use() { Take(out ((this)).values); }",
        "public void Use() { Take(in (this).values); }",
        "public void Use() { ((other, (values, third)), fourth) = Factory(); }",
    }) |body| {
        const source = try std.fmt.allocPrint(arena, "using UnityEngine; using System.Collections.Generic; public class Example : MonoBehaviour {{ [SerializeField] Dictionary<string,int> values; {s} }}", .{body});
        var names: Names = .{};
        try inspectNames(arena, source, &names);
        const fields = try read(arena, source, "Example", names);
        try testing.expectEqual(@as(usize, 1), fields.len);
        try testing.expectEqual(DictionaryEquality.unknown, fields[0].dictionary_equality);
    }
}

test "C# tuple reads and nested tuple entry edits do not replace the dictionary" {
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const source = "using UnityEngine; using System.Collections.Generic; public class Example : MonoBehaviour { [SerializeField] Dictionary<string,int> values; public void Use() { var view = ((values,1),2); ((values[\"A\"],other),third) = ((1,2),3); var n = (this).values.Count; } }";
    var names: Names = .{};
    try inspectNames(arena, source, &names);
    const fields = try read(arena, source, "Example", names);
    try testing.expectEqual(DictionaryEquality.default, fields[0].dictionary_equality);
}
