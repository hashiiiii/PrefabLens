const std = @import("std");
const testing = std.testing;
const core = @import("core");
const main = @import("main.zig");

pub const default_protocol_version = "2025-06-18";
const supported_versions = [_][]const u8{ "2025-06-18", "2025-03-26", "2024-11-05" };

/// MCP stdio transport: 改行区切り JSON-RPC 2.0。stdin EOF で正常終了。
/// stdout はプロトコル専用(診断は stderr へ)。リクエストごとに arena を張る。
pub fn serve(io: std.Io, gpa: std.mem.Allocator, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
    while (true) {
        // takeDelimiterInclusive は改行を消費して返す(Exclusive はデリミタを消費せず
        // 空スライスを返し続けるため、ここでは使えない)。
        const raw = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return,
            // 1 行が読み取りバッファを超えた(仕様外の巨大リクエスト)。応答不能として終了する。
            else => return err,
        };
        const line = std.mem.trimEnd(u8, raw, "\r\n");
        if (line.len == 0) continue;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        try handleLine(io, arena_state.allocator(), line, writer);
        try writer.flush();
    }
}

fn handleLine(io: std.Io, arena: std.mem.Allocator, line: []const u8, w: *std.Io.Writer) !void {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch {
        try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}\n");
        return;
    };
    if (parsed != .object) {
        try writeError(w, .null, -32600, "Invalid Request");
        return;
    }
    const obj = parsed.object;
    const id: std.json.Value = obj.get("id") orelse .null;
    const has_id = obj.get("id") != null;
    const method_v = obj.get("method") orelse {
        if (has_id) try writeError(w, id, -32600, "Invalid Request");
        return;
    };
    if (method_v != .string) {
        if (has_id) try writeError(w, id, -32600, "Invalid Request");
        return;
    }
    const method = method_v.string;

    // 通知(id なし)には未知のものも含め一切応答しない(JSON-RPC 2.0)。
    if (!has_id) return;

    if (std.mem.eql(u8, method, "initialize")) {
        try writeInitialize(w, id, obj.get("params"));
    } else if (std.mem.eql(u8, method, "ping")) {
        try writeEnvelopePrefix(w, id);
        try w.writeAll("\"result\":{}}\n");
    } else {
        try writeError(w, id, -32601, "Method not found");
    }
    _ = io;
}

fn writeInitialize(w: *std.Io.Writer, id: std.json.Value, params: ?std.json.Value) !void {
    var negotiated: []const u8 = default_protocol_version;
    if (params) |p| if (p == .object) if (p.object.get("protocolVersion")) |v| if (v == .string) {
        for (supported_versions) |s| {
            if (std.mem.eql(u8, s, v.string)) negotiated = s;
        }
    };
    try writeEnvelopePrefix(w, id);
    try w.print("\"result\":{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"prefablens\",\"version\":\"{s}\"}}}}}}\n", .{ negotiated, main.version });
}

/// `{"jsonrpc":"2.0","id":<id>,` まで書く。呼び出し側が result/error 以降を続ける。
fn writeEnvelopePrefix(w: *std.Io.Writer, id: std.json.Value) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    switch (id) {
        .integer => |n| try w.print("{d}", .{n}),
        .string => |s| try core.json.writeJsonString(w, s),
        else => try w.writeAll("null"),
    }
    try w.writeAll(",");
}

fn writeError(w: *std.Io.Writer, id: std.json.Value, code: i32, msg: []const u8) !void {
    try writeEnvelopePrefix(w, id);
    try w.print("\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}\n", .{ code, msg });
}

/// テストヘルパー: 入力行をまとめて食わせ、応答全文を返す。
fn roundtrip(arena: std.mem.Allocator, input_lines: []const u8) ![]const u8 {
    var reader = std.Io.Reader.fixed(input_lines);
    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    try serve(testing.io, arena, &reader, &aw.writer);
    return aw.toArrayList().items;
}

test "mcp: initialize echoes a supported protocol version" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try roundtrip(arena,
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"0\"}}}\n");
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"prefablens\",\"version\":\"" ++ main.version ++ "\"}}}\n",
        res);
}

test "mcp: initialize falls back to the default version for unknown ones" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try roundtrip(arena,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"1999-01-01\"}}\n");
    try testing.expect(std.mem.indexOf(u8, res, "\"protocolVersion\":\"2025-06-18\"") != null);
}

test "mcp: ping returns an empty result" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try roundtrip(arena, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"ping\"}\n");
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}\n", res);
}

test "mcp: notifications get no response, even unknown ones" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try roundtrip(arena,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n" ++
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/whatever\"}\n");
    try testing.expectEqualStrings("", res);
}

test "mcp: unknown request method is -32601" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try roundtrip(arena, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"nope\"}\n");
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}\n", res);
}

test "mcp: malformed json is -32700 with null id" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try roundtrip(arena, "this is not json\n");
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}\n", res);
}

test "mcp: non-object or method-less request is -32600" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try roundtrip(arena, "[1,2]\n{\"jsonrpc\":\"2.0\",\"id\":9}\n");
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Invalid Request\"}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"error\":{\"code\":-32600,\"message\":\"Invalid Request\"}}\n", res);
}

test "mcp: blank lines and trailing CR are tolerated" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try roundtrip(arena, "\n{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"ping\"}\r\n");
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}\n", res);
}
