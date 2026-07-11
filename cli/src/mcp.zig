const std = @import("std");
const testing = std.testing;
const core = @import("core");
const main = @import("main.zig");

pub const default_protocol_version = "2025-06-18";
// 2025-03-26 makes batch requests a MUST, but major clients don't send them, so we accept it while leaving batching unsupported.
const supported_versions = [_][]const u8{ "2025-06-18", "2025-03-26", "2024-11-05" };

/// result payload for tools/list. description and inputSchema are a faithful port of the old TS host
/// (the zod definitions in mcp/src/index.ts). build.zig's smoke golden @embedFiles the same
/// tools_list.json, so edits are confined to that one file.
pub const tools_list_result: []const u8 = std.mem.trimEnd(u8, @embedFile("tools_list.json"), "\r\n");

/// MCP stdio transport: newline-delimited JSON-RPC 2.0. Exits cleanly on stdin EOF.
/// stdout is protocol-only (diagnostics go to stderr). A fresh arena per request.
pub fn serve(io: std.Io, gpa: std.mem.Allocator, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
    while (true) {
        // takeDelimiterInclusive consumes the newline and returns it (Exclusive leaves the delimiter
        // unconsumed and keeps returning an empty slice, so it can't be used here).
        const raw = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return,
            // One line exceeded the read buffer. We can't discard the rest of the line and resync
            // (the buffer is stuck mid-line), so write an error response and then close.
            error.StreamTooLong => {
                try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Request too large\"}}\n");
                try writer.flush();
                return;
            },
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

    // Notifications (no id) get no response at all, unknown ones included (JSON-RPC 2.0).
    if (!has_id) return;

    if (std.mem.eql(u8, method, "initialize")) {
        try writeInitialize(w, id, obj.get("params"));
    } else if (std.mem.eql(u8, method, "ping")) {
        try writeEnvelopePrefix(w, id);
        try w.writeAll("\"result\":{}}\n");
    } else if (std.mem.eql(u8, method, "tools/list")) {
        try writeEnvelopePrefix(w, id);
        try w.print("\"result\":{s}}}\n", .{tools_list_result});
    } else if (std.mem.eql(u8, method, "tools/call")) {
        try handleToolsCall(io, arena, w, id, obj.get("params"));
    } else {
        try writeError(w, id, -32601, "Method not found");
    }
}

pub const tree_char_limit: usize = 50_000;

/// LLM context protection (equivalent to the old diff.ts truncateTree; units are bytes).
/// Cutting mid-multibyte-character would make the response invalid UTF-8 and crash strict clients
/// for the whole session, so back up to a code-point boundary before cutting.
pub fn truncateTree(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (text.len <= tree_char_limit) return text;
    var end = tree_char_limit;
    while (end > 0 and text[end] & 0xC0 == 0x80) end -= 1;
    return std.fmt.allocPrint(arena, "{s}\n[truncated: {d} chars total]\n", .{ text[0..end], text.len });
}

fn validationError(w: *std.Io.Writer, id: std.json.Value, msg: []const u8) !void {
    try writeEnvelopePrefix(w, id);
    try w.writeAll("\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"Input validation error: ");
    try w.writeAll(msg); // msg is static strings only (any needed escaping is handled in the caller's literal)
    try w.writeAll("\"}],\"isError\":true}}\n");
}

/// Extract a string from arguments. A missing key is null; a type mismatch is error.Invalid.
fn getString(args: ?std.json.Value, key: []const u8) error{Invalid}!?[]const u8 {
    const a = args orelse return null;
    if (a != .object) return error.Invalid;
    const v = a.object.get(key) orelse return null;
    if (v != .string) return error.Invalid;
    return v.string;
}

fn writeToolText(w: *std.Io.Writer, id: std.json.Value, text: []const u8, is_error: bool) !void {
    try writeEnvelopePrefix(w, id);
    try w.writeAll("\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
    try core.json.writeJsonString(w, text);
    if (is_error) {
        try w.writeAll("}],\"isError\":true}}\n");
    } else {
        try w.writeAll("}]}}\n");
    }
}

fn handleToolsCall(io: std.Io, arena: std.mem.Allocator, w: *std.Io.Writer, id: std.json.Value, params: ?std.json.Value) !void {
    const p: std.json.Value = params orelse .null;
    const name = (getString(p, "name") catch null) orelse "";
    if (!std.mem.eql(u8, name, "prefab_diff")) {
        try writeError(w, id, -32602, "Unknown tool");
        return;
    }
    const args: ?std.json.Value = if (p == .object) p.object.get("arguments") else null;
    const path = getString(args, "path") catch return validationError(w, id, "path must be a non-empty string");
    if (path == null or path.?.len == 0) return validationError(w, id, "path must be a non-empty string");
    const before = (getString(args, "before") catch return validationError(w, id, "before must be a string")) orelse "HEAD";
    const after = getString(args, "after") catch return validationError(w, id, "after must be a string");
    const project_root = getString(args, "projectRoot") catch return validationError(w, id, "projectRoot must be a non-empty string");
    if (project_root != null and project_root.?.len == 0) return validationError(w, id, "projectRoot must be a non-empty string");
    const format = (getString(args, "format") catch return validationError(w, id, "format must be \\\"tree\\\" or \\\"json\\\"")) orelse "tree";
    const is_json = std.mem.eql(u8, format, "json");
    if (!is_json and !std.mem.eql(u8, format, "tree"))
        return validationError(w, id, "format must be \\\"tree\\\" or \\\"json\\\"");

    // Same argv as the old TS host's buildArgs + cwd=projectRoot (--project doubles as the git repo dir).
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, if (is_json) "--json" else "--no-color");
    try argv.appendSlice(arena, &.{ "--project", project_root orelse "." });
    try argv.appendSlice(arena, &.{ "--git", before });
    if (after) |a| try argv.append(arena, a);
    try argv.append(arena, path.?);

    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var errbuf: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf);
    const code = main.run(io, arena, argv.items, &aw.writer, &aw_err.writer, false) catch |err| {
        const msg = try std.fmt.allocPrint(arena, "prefablens failed: {s}", .{@errorName(err)});
        try writeToolText(w, id, msg, true);
        return;
    };
    if (code != 0) {
        const stderr_text = std.mem.trim(u8, aw_err.toArrayList().items, " \t\r\n");
        const text = if (stderr_text.len > 0) stderr_text else try std.fmt.allocPrint(arena, "prefablens exited with code {d}", .{code});
        try writeToolText(w, id, text, true);
        return;
    }
    const stdout_text = aw.toArrayList().items;
    const text = if (is_json) stdout_text else try truncateTree(arena, stdout_text);
    try writeToolText(w, id, text, false);
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

/// Writes up to `{"jsonrpc":"2.0","id":<id>,`. The caller continues with result/error onward.
fn writeEnvelopePrefix(w: *std.Io.Writer, id: std.json.Value) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    switch (id) {
        .integer => |n| try w.print("{d}", .{n}),
        // Floats and integers past i64 are also valid JSON-RPC ids. Pass through verbatim to preserve correlation.
        .float => |f| try w.print("{d}", .{f}),
        .number_string => |s| try w.writeAll(s),
        .string => |s| try core.json.writeJsonString(w, s),
        else => try w.writeAll("null"),
    }
    try w.writeAll(",");
}

fn writeError(w: *std.Io.Writer, id: std.json.Value, code: i32, msg: []const u8) !void {
    try writeEnvelopePrefix(w, id);
    try w.print("\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}\n", .{ code, msg });
}

/// Test helper: invokes real git (no-mocks policy).
fn gitc(io: std.Io, a: std.mem.Allocator, d: []const u8, argv: []const []const u8) !void {
    var full: std.ArrayList([]const u8) = .empty;
    try full.append(a, "git");
    try full.appendSlice(a, argv);
    const r = try std.process.run(a, io, .{ .argv = full.items, .cwd = .{ .path = d } });
    if (r.term != .exited or r.term.exited != 0) return error.GitFailed;
}

/// Test helper: builds the git repository for the plane fixture and returns its absolute path.
/// Same shape as server.test.ts's beforeAll (commit before, put after in the working tree).
fn setupPlaneRepo(io: std.Io, arena: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]const u8 {
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena);
    try tmp.dir.writeFile(io, .{ .sub_path = "Plane.prefab", .data = @embedFile("testdata_plane_before") });
    try gitc(io, arena, dir, &.{ "init", "-q" });
    try gitc(io, arena, dir, &.{ "config", "user.email", "t@t.t" });
    try gitc(io, arena, dir, &.{ "config", "user.name", "t" });
    try gitc(io, arena, dir, &.{ "add", "." });
    try gitc(io, arena, dir, &.{ "commit", "-q", "-m", "init" });
    try tmp.dir.writeFile(io, .{ .sub_path = "Plane.prefab", .data = @embedFile("testdata_plane_after") });
    return dir;
}

/// Test helper: feeds the input lines all at once and returns the full response.
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
    const res = try roundtrip(arena, "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"0\"}}}\n");
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"prefablens\",\"version\":\"" ++ main.version ++ "\"}}}\n", res);
}

test "mcp: initialize falls back to the default version for unknown ones" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try roundtrip(arena, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"1999-01-01\"}}\n");
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
    const res = try roundtrip(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n" ++
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/whatever\"}\n");
    try testing.expectEqualStrings("", res);
}

test "mcp: unknown request method is -32601" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try roundtrip(arena, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"nope\"}\n");
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":4,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}\n", res);
}

test "mcp: malformed json is -32700 with null id" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try roundtrip(arena, "this is not json\n");
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}\n", res);
}

test "mcp: non-object or method-less request is -32600" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try roundtrip(arena, "[1,2]\n{\"jsonrpc\":\"2.0\",\"id\":9}\n");
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Invalid Request\"}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"error\":{\"code\":-32600,\"message\":\"Invalid Request\"}}\n", res);
}

test "mcp: tools/list returns the single prefab_diff tool" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try roundtrip(arena, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}\n");
    // golden: exactly the implementation's tools_list_result joined with the envelope
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":" ++ tools_list_result ++ "}\n", res);
    // The schema's key points must be present (not just self-consistency with the golden)
    try testing.expect(std.mem.indexOf(u8, res, "\"name\":\"prefab_diff\"") != null);
    try testing.expect(std.mem.indexOf(u8, res, "\"required\":[\"path\"]") != null);
    try testing.expect(std.mem.indexOf(u8, res, "\"enum\":[\"tree\",\"json\"]") != null);
}

test "mcp: tools/call validation errors match the ts host contract" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // empty path / empty projectRoot / invalid format / missing arguments / unknown tool
    const res = try roundtrip(arena, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"prefab_diff\",\"arguments\":{\"path\":\"\"}}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"prefab_diff\",\"arguments\":{\"path\":\"a.prefab\",\"projectRoot\":\"\"}}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"prefab_diff\",\"arguments\":{\"path\":\"a.prefab\",\"format\":\"xml\"}}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"prefab_diff\"}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"nope\",\"arguments\":{}}}\n");
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, res, "\n"), '\n');
    const l1 = lines.next().?;
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"Input validation error: path must be a non-empty string\"}],\"isError\":true}}", l1);
    try testing.expect(std.mem.indexOf(u8, lines.next().?, "projectRoot must be a non-empty string") != null);
    try testing.expect(std.mem.indexOf(u8, lines.next().?, "format must be \\\"tree\\\" or \\\"json\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, lines.next().?, "path must be a non-empty string") != null);
    try testing.expect(std.mem.indexOf(u8, lines.next().?, "-32602") != null);
}

test "mcp: tools/call diffs a real git fixture with the ts host golden" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try setupPlaneRepo(testing.io, arena, &tmp);

    // projectRoot may contain a Windows path, so embed it JSON-escaped.
    var req: std.ArrayList(u8) = .empty;
    var req_w = std.Io.Writer.Allocating.fromArrayList(arena, &req);
    try req_w.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"prefab_diff\",\"arguments\":{\"path\":\"Plane.prefab\",\"projectRoot\":");
    try core.json.writeJsonString(&req_w.writer, dir);
    try req_w.writer.writeAll("}}}\n");
    const res = try roundtrip(arena, req_w.toArrayList().items);

    // Parse the response and compare text against the box-drawing spine layout
    // (render_tree.zig; formerly matched server.test.ts's now-removed TS host golden).
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, std.mem.trimEnd(u8, res, "\n"), .{});
    const result = parsed.object.get("result").?.object;
    try testing.expect(result.get("isError") == null);
    const text = result.get("content").?.array.items[0].object.get("text").?.string;
    try testing.expectEqualStrings("◆ Plane\n" ++
        "├─ ◆ ~ Cylinder ‹Prefab›\n" ++
        "│  └─ components (1)\n" ++
        "│     └─ ~ Transform\n" ++
        "│          Position.x: 0.41646004 → 1\n" ++
        "└─ ◆ + Cylinder Variant ‹Prefab›\n" ++
        "   └─ components (1)\n" ++
        "      └─ + Transform\n" ++
        "           Position: (2.03, 3.63, 1.11797)\n" ++
        "           Rotation: (0, 0, 0, 1)\n", text);
}

test "mcp: tools/call format json returns diff v2 and bad refs surface as isError" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try setupPlaneRepo(testing.io, arena, &tmp);

    var req: std.ArrayList(u8) = .empty;
    var req_w = std.Io.Writer.Allocating.fromArrayList(arena, &req);
    try req_w.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"prefab_diff\",\"arguments\":{\"path\":\"Plane.prefab\",\"format\":\"json\",\"projectRoot\":");
    try core.json.writeJsonString(&req_w.writer, dir);
    try req_w.writer.writeAll("}}}\n{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"prefab_diff\",\"arguments\":{\"path\":\"Plane.prefab\",\"before\":\"nosuchref\",\"after\":\"HEAD\",\"projectRoot\":");
    try core.json.writeJsonString(&req_w.writer, dir);
    try req_w.writer.writeAll("}}}\n");
    const res = try roundtrip(arena, req_w.toArrayList().items);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, res, "\n"), '\n');
    const l1 = lines.next().?;
    try testing.expect(std.mem.indexOf(u8, l1, "prefablens.diff.v2") != null);
    const l2 = lines.next().?;
    // server.test.ts: "git show failed for 'nosuchref:Plane.prefab'" + isError
    try testing.expect(std.mem.indexOf(u8, l2, "git show failed for 'nosuchref:Plane.prefab'") != null);
    try testing.expect(std.mem.indexOf(u8, l2, "\"isError\":true") != null);
}

test "mcp: truncateTree caps tree output like the ts host" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const short = try truncateTree(arena, "abc");
    try testing.expectEqualStrings("abc", short);
    const big = try arena.alloc(u8, tree_char_limit + 1);
    @memset(big, 'x');
    const cut = try truncateTree(arena, big);
    try testing.expect(std.mem.endsWith(u8, cut, "\n[truncated: 50001 chars total]\n"));
    try testing.expectEqual(tree_char_limit, std.mem.indexOf(u8, cut, "\n[truncated").?);
}

test "mcp: float and oversized integer ids are echoed verbatim" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // JSON-RPC 2.0 requires the response id to equal the request id (floats and integers past i64 are both valid).
    const res = try roundtrip(arena, "{\"jsonrpc\":\"2.0\",\"id\":1.5,\"method\":\"ping\"}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":92233720368547758080,\"method\":\"ping\"}\n");
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1.5,\"result\":{}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":92233720368547758080,\"result\":{}}\n", res);
}

test "mcp: truncateTree never splits a multibyte utf-8 character" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Build input where byte 50,000 lands in the middle of a 3-byte '€'.
    var big: std.ArrayList(u8) = .empty;
    try big.appendNTimes(arena, 'x', tree_char_limit - 1);
    try big.appendSlice(arena, "€€€");
    const cut = try truncateTree(arena, big.items);
    // No split lead byte creeps in; the whole thing is valid UTF-8.
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
    try testing.expect(std.mem.endsWith(u8, cut, "\n[truncated: 50008 chars total]\n"));
    // The cut stops just before the '€' (byte 49,999).
    try testing.expectEqual(@as(usize, tree_char_limit - 1), std.mem.indexOf(u8, cut, "\n[truncated").?);
}

test "mcp: oversized request line responds with an error before closing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // One line exceeding the read buffer (32 bytes in the test) -> without killing the process,
    // write an error response and then close.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const big_line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"padding\":\"" ++ ("x" ** 100) ++ "\"}\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "input.jsonl", .data = big_line });
    var file = try tmp.dir.openFile(testing.io, "input.jsonl", .{});
    defer file.close(testing.io);
    var buf: [32]u8 = undefined;
    var fr: std.Io.File.Reader = .init(file, testing.io, &buf);
    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    try serve(testing.io, arena, &fr.interface, &aw.writer);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Request too large\"}}\n", aw.toArrayList().items);
}

test "mcp: blank lines and trailing CR are tolerated" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try roundtrip(arena, "\n{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"ping\"}\r\n");
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}\n", res);
}
