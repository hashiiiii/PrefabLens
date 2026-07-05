# MCP Zig ネイティブ化 (`prefablens mcp`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** TS 製 MCP ホスト(`mcp/`)を `prefablens mcp` サブコマンド(Zig、インプロセス diff)で置換し、最終的に `mcp/` を削除する。

**Architecture:** MCP stdio transport(改行区切り JSON-RPC 2.0)のループを `cli/src/mcp.zig` に実装する。tools/call は旧 TS ホストと同じ argv を組んで既存の `main.run()`(writer 注入可能な CLI エントリ)をインプロセスで呼ぶ — これによりエラー文言・出力が構築的にパリティになる。前提として `--project` を git repo dir としても使う小さな統一を入れる(旧 TS ホストの「cwd=projectRoot で `--project .`」と等価にするため)。

**Tech Stack:** Zig 0.16(std.Io 新 API: `std.Io.Writer.Allocating`、`std.process.run`)、std.json(受信パース)、git(実サブプロセス、テストも実物)。

**Spec:** `docs/superpowers/specs/2026-07-05-mcp-zig-native-design.md`

## Global Constraints

- モック・スタブ禁止(テストは実 git・実ファイル・実サーバーループ)
- テストのログ・名前は英語、テスト内コメントは日本語可(既存流儀)
- コミットは 1 行・英語・50 字以内(git-conventions)
- パリティのソース・オブ・トゥルース: 旧 `mcp/src/index.ts`(スキーマ・文言)と `mcp/src/server.test.ts`(golden)。PR 1 の間、`mcp/` には一切触れない
- プロトコル版: `2025-06-18`(既定)、`2025-03-26`、`2024-11-05` をエコー可
- tree 出力は 50,000 文字で truncate し `\n[truncated: {N} chars total]\n` を付加(N は全体長)
- 検証エラーは throw せず `isError:true` + `Input validation error: ...` テキスト
- Zig 0.16 の std API 名が計画と違う場合(例: `std.Io.Reader.fixed` / `takeDelimiterExclusive` / `parseFromSliceLeaky`)はコンパイルエラーに従って同等 API に置換してよい。**挙動仕様と golden は変えない**

---

## PR 1: `feat/mcp-subcommand`(mcp/ 無変更で併存)

ブランチ: `git switch -c feat/mcp-subcommand`(main から)

### Task 1: `--project` を git repo dir に統一 + CLI バージョン定数

**Files:**
- Modify: `cli/src/main.zig`(`run()` の git 取得 3 箇所、version 定数追加)
- Test: `cli/src/main.zig`(テスト追記)

**Interfaces:**
- Produces: `pub const version = "0.2.0";`(main.zig トップレベル。Task 2 の serverInfo と PR 2 の check-versions.sh が参照)
- Produces: `run()` は git mode で `opt.project_root orelse "."` を repo dir に使う(Task 4 が `--project <projectRoot>` を渡して依存)

- [ ] **Step 1: 失敗するテストを書く**(main.zig のテスト群の末尾に追加)

```zig
test "run: --project points git mode at a repo outside the cwd" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // cwd の外に実 git リポジトリを作る。--project がその repo を指せば
    // git show は成功する(現状は cwd 固定 "." なので失敗する = RED)。
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const gitc = struct {
        fn call(io: std.Io, a: std.mem.Allocator, d: []const u8, argv: []const []const u8) !void {
            var full: std.ArrayList([]const u8) = .empty;
            try full.append(a, "git");
            try full.appendSlice(a, argv);
            const r = try std.process.run(a, io, .{ .argv = full.items, .cwd = .{ .path = d } });
            if (r.term != .exited or r.term.exited != 0) return error.GitFailed;
        }
    }.call;
    try gitc(testing.io, arena, dir, &.{ "init", "-q" });
    try gitc(testing.io, arena, dir, &.{ "config", "user.email", "t@t.t" });
    try gitc(testing.io, arena, dir, &.{ "config", "user.name", "t" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Foo.asset", .data =
        \\--- !u!114 &1
        \\MonoBehaviour:
        \\  hp: 1
    });
    try gitc(testing.io, arena, dir, &.{ "add", "Foo.asset" });
    try gitc(testing.io, arena, dir, &.{ "commit", "-q", "-m", "first" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Foo.asset", .data =
        \\--- !u!114 &1
        \\MonoBehaviour:
        \\  hp: 2
    });

    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    var errbuf: std.ArrayList(u8) = .empty;
    var aw_err = std.Io.Writer.Allocating.fromArrayList(arena, &errbuf);
    const code = try run(testing.io, arena, &.{ "--json", "--project", dir, "--git", "HEAD", "Foo.asset" }, &aw.writer, &aw_err.writer, false);
    const output = aw.toArrayList();
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, output.items, "\"after\":\"2\"") != null);
}

test "version constant exists for serverInfo and release lockstep" {
    try testing.expectEqualStrings("0.2.0", version);
}
```

- [ ] **Step 2: RED を確認**

Run: `zig build test 2>&1 | tail -20`
Expected: 新テスト 2 本が失敗(1 本目は `git show failed`、2 本目は `version` 未定義のコンパイルエラー)。コンパイルエラーが先に出る場合は version 定数を先に入れてから git テストの RED を確認する。

- [ ] **Step 3: 最小実装**

main.zig トップレベル(`pub const Format` の手前)に:

```zig
/// リリースタグ v<version> と lockstep(cut-release の 5 ソースの一員)。
pub const version = "0.2.0";
```

`run()` の git 取得 3 箇所を `"."` → `opt.project_root orelse "."` に変更:

```zig
    const repo_dir = opt.project_root orelse ".";
    const before = if (opt.git_mode)
        input.showAtRef(io, arena, repo_dir, opt.git_ref_before, opt.git_path) catch {
```

(同様に `readWorktree(io, arena, repo_dir, opt.git_path)`、after 側 `showAtRef(io, arena, repo_dir, ...)`)

- [ ] **Step 4: GREEN を確認**

Run: `zig build test 2>&1 | tail -5`
Expected: 全テスト pass(既存テストは `--project` なし git mode → `"."` で挙動不変)

- [ ] **Step 5: Commit**

```bash
git add cli/src/main.zig
git commit -m "feat: project flag doubles as git repo dir"
```

### Task 2: mcp.zig — JSON-RPC framing とライフサイクル

**Files:**
- Create: `cli/src/mcp.zig`
- Modify: `cli/src/main.zig`(test ブロックに `_ = @import("mcp.zig");` を追加してテストを回す)
- Modify: `core/src/json.zig`(`fn writeJsonString` → `pub fn writeJsonString`)

**Interfaces:**
- Consumes: `core.json.writeJsonString(w, s)`(pub 化)、`main.version`
- Produces: `pub fn serve(io: std.Io, gpa: std.mem.Allocator, reader: *std.Io.Reader, writer: *std.Io.Writer) !void`(Task 5 の main() が呼ぶ)
- Produces: `pub const default_protocol_version = "2025-06-18";`

- [ ] **Step 1: 失敗するテストを書く**(mcp.zig を新規作成し、テストから書く)

```zig
const std = @import("std");
const testing = std.testing;

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
```

main.zig の `test { ... }` ブロックに `_ = @import("mcp.zig");` を追加。core/src/json.zig の `fn writeJsonString` を `pub fn writeJsonString` に変更。

- [ ] **Step 2: RED を確認**

Run: `zig build test 2>&1 | tail -20`
Expected: `serve` 未定義のコンパイルエラー(= 機能不在の失敗)

- [ ] **Step 3: 最小実装**(mcp.zig の実装部)

```zig
const core = @import("core");
const main = @import("main.zig");

pub const default_protocol_version = "2025-06-18";
const supported_versions = [_][]const u8{ "2025-06-18", "2025-03-26", "2024-11-05" };

/// MCP stdio transport: 改行区切り JSON-RPC 2.0。stdin EOF で正常終了。
/// stdout はプロトコル専用(診断は stderr へ)。リクエストごとに arena を張る。
pub fn serve(io: std.Io, gpa: std.mem.Allocator, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
    while (true) {
        const raw = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return,
            // 1 行が読み取りバッファを超えた(仕様外の巨大リクエスト)。応答不能として終了する。
            else => return err,
        };
        const line = std.mem.trimRight(u8, raw, "\r");
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
```

- [ ] **Step 4: GREEN を確認**

Run: `zig build test 2>&1 | tail -5`
Expected: 全テスト pass

- [ ] **Step 5: Commit**

```bash
git add cli/src/mcp.zig cli/src/main.zig core/src/json.zig
git commit -m "feat: mcp json-rpc framing and lifecycle"
```

### Task 3: tools/list

**Files:**
- Modify: `cli/src/mcp.zig`

**Interfaces:**
- Produces: `pub const tools_list_result: []const u8`(result ペイロード。Task 5 の build.zig smoke golden と一字一句一致させる)

- [ ] **Step 1: 失敗するテストを書く**

```zig
test "mcp: tools/list returns the single prefab_diff tool" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try roundtrip(arena, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}\n");
    // golden: 実装の tools_list_result と envelope の結合そのもの
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":" ++ tools_list_result ++ "}\n", res);
    // スキーマの要点が入っていること(golden の自己一致だけにしない)
    try testing.expect(std.mem.indexOf(u8, res, "\"name\":\"prefab_diff\"") != null);
    try testing.expect(std.mem.indexOf(u8, res, "\"required\":[\"path\"]") != null);
    try testing.expect(std.mem.indexOf(u8, res, "\"enum\":[\"tree\",\"json\"]") != null);
}
```

- [ ] **Step 2: RED を確認**

Run: `zig build test 2>&1 | tail -10`
Expected: `tools_list_result` 未定義のコンパイルエラー

- [ ] **Step 3: 最小実装**(旧 index.ts の DESCRIPTION と zod 定義の忠実変換。1 行の文字列定数)

```zig
pub const tools_list_result: []const u8 =
    "{\"tools\":[{\"name\":\"prefab_diff\",\"description\":\"Semantic diff for Unity YAML assets (.prefab/.unity/.asset) between two git versions. Use this instead of reading raw YAML diffs: it matches objects by fileID and reports added/removed/modified GameObjects, components, fields, and prefab overrides with resolved names.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"minLength\":1,\"description\":\"Asset path (.prefab/.unity/.asset), relative to projectRoot\"},\"before\":{\"type\":\"string\",\"default\":\"HEAD\",\"description\":\"Base git ref\"},\"after\":{\"type\":\"string\",\"description\":\"Target git ref; omit to compare against the working tree\"},\"projectRoot\":{\"type\":\"string\",\"minLength\":1,\"description\":\"Repository root; defaults to the server cwd\"},\"format\":{\"type\":\"string\",\"enum\":[\"tree\",\"json\"],\"default\":\"tree\",\"description\":\"tree = readable text, json = prefablens.diff.v2\"}},\"required\":[\"path\"]}}]}";
```

handleLine のルーティングに追加(ping の分岐の後):

```zig
    } else if (std.mem.eql(u8, method, "tools/list")) {
        try writeEnvelopePrefix(w, id);
        try w.print("\"result\":{s}}}\n", .{tools_list_result});
```

- [ ] **Step 4: GREEN を確認**

Run: `zig build test 2>&1 | tail -5`
Expected: 全テスト pass

- [ ] **Step 5: Commit**

```bash
git add cli/src/mcp.zig
git commit -m "feat: mcp tools/list with prefab_diff schema"
```

### Task 4: tools/call — 検証・インプロセス diff・truncate・エラー写像

**Files:**
- Modify: `cli/src/mcp.zig`

**Interfaces:**
- Consumes: `main.run(io, arena, argv, stdout, stderr, color) !u8`(Task 1 の `--project` = repo dir 統一に依存)
- Produces: `pub const tree_char_limit: usize = 50_000;` と `pub fn truncateTree(arena, text) ![]const u8`

- [ ] **Step 1: 失敗するテストを書く**

```zig
test "mcp: tools/call validation errors match the ts host contract" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // 空 path / 空 projectRoot / 不正 format / arguments 欠落 / 未知ツール
    const res = try roundtrip(arena,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"prefab_diff\",\"arguments\":{\"path\":\"\"}}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"prefab_diff\",\"arguments\":{\"path\":\"a.prefab\",\"projectRoot\":\"\"}}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"prefab_diff\",\"arguments\":{\"path\":\"a.prefab\",\"format\":\"xml\"}}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"prefab_diff\"}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"nope\",\"arguments\":{}}}\n");
    var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, res, "\n"), '\n');
    const l1 = lines.next().?;
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"Input validation error: path must be a non-empty string\"}],\"isError\":true}}", l1);
    try testing.expect(std.mem.indexOf(u8, lines.next().?, "projectRoot must be a non-empty string") != null);
    try testing.expect(std.mem.indexOf(u8, lines.next().?, "format must be \\\"tree\\\" or \\\"json\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, lines.next().?, "path must be a non-empty string") != null);
    try testing.expect(std.mem.indexOf(u8, lines.next().?, "-32602") != null);
}

test "mcp: tools/call diffs a real git fixture with the ts host golden" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // server.test.ts の beforeAll と同じ fixture repo を実 git で組む。
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const before_bytes = @embedFile("testdata_plane_before");
    const after_bytes = @embedFile("testdata_plane_after");
    const gitc = struct {
        fn call(io: std.Io, a: std.mem.Allocator, d: []const u8, argv: []const []const u8) !void {
            var full: std.ArrayList([]const u8) = .empty;
            try full.append(a, "git");
            try full.appendSlice(a, argv);
            const r = try std.process.run(a, io, .{ .argv = full.items, .cwd = .{ .path = d } });
            if (r.term != .exited or r.term.exited != 0) return error.GitFailed;
        }
    }.call;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Plane.prefab", .data = before_bytes });
    try gitc(testing.io, arena, dir, &.{ "init", "-q" });
    try gitc(testing.io, arena, dir, &.{ "config", "user.email", "t@t.t" });
    try gitc(testing.io, arena, dir, &.{ "config", "user.name", "t" });
    try gitc(testing.io, arena, dir, &.{ "add", "." });
    try gitc(testing.io, arena, dir, &.{ "commit", "-q", "-m", "init" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Plane.prefab", .data = after_bytes });

    // projectRoot は Windows パスを含み得るので JSON エスケープして埋め込む。
    var req: std.ArrayList(u8) = .empty;
    var req_w = std.Io.Writer.Allocating.fromArrayList(arena, &req);
    try req_w.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"prefab_diff\",\"arguments\":{\"path\":\"Plane.prefab\",\"projectRoot\":");
    try core.json.writeJsonString(&req_w.writer, dir);
    try req_w.writer.writeAll("}}}\n");
    const res = try roundtrip(arena, req_w.toArrayList().items);

    // 応答をパースして text を server.test.ts の golden と一致比較する。
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, std.mem.trimRight(u8, res, "\n"), .{});
    const result = parsed.object.get("result").?.object;
    try testing.expect(result.get("isError") == null);
    const text = result.get("content").?.array.items[0].object.get("text").?.string;
    try testing.expectEqualStrings(
        "  Plane\n" ++
        "  ~ Cylinder  \u{2039}Prefab\u{203A}\n" ++
        "      components\n" ++
        "        ~ Transform\n" ++
        "          ~ Position.x: 0.41646004 -> 1\n" ++
        "  + Cylinder Variant  \u{2039}Prefab\u{203A}\n" ++
        "      components\n" ++
        "        + Transform\n" ++
        "          + Position: (2.03, 3.63, 1.11797)\n", text);
}

test "mcp: tools/call format json returns diff v2 and bad refs surface as isError" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const gitc = struct {
        fn call(io: std.Io, a: std.mem.Allocator, d: []const u8, argv: []const []const u8) !void {
            var full: std.ArrayList([]const u8) = .empty;
            try full.append(a, "git");
            try full.appendSlice(a, argv);
            const r = try std.process.run(a, io, .{ .argv = full.items, .cwd = .{ .path = d } });
            if (r.term != .exited or r.term.exited != 0) return error.GitFailed;
        }
    }.call;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Plane.prefab", .data = @embedFile("testdata_plane_before") });
    try gitc(testing.io, arena, dir, &.{ "init", "-q" });
    try gitc(testing.io, arena, dir, &.{ "config", "user.email", "t@t.t" });
    try gitc(testing.io, arena, dir, &.{ "config", "user.name", "t" });
    try gitc(testing.io, arena, dir, &.{ "add", "." });
    try gitc(testing.io, arena, dir, &.{ "commit", "-q", "-m", "init" });

    var req: std.ArrayList(u8) = .empty;
    var req_w = std.Io.Writer.Allocating.fromArrayList(arena, &req);
    try req_w.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"prefab_diff\",\"arguments\":{\"path\":\"Plane.prefab\",\"format\":\"json\",\"projectRoot\":");
    try core.json.writeJsonString(&req_w.writer, dir);
    try req_w.writer.writeAll("}}}\n{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"prefab_diff\",\"arguments\":{\"path\":\"Plane.prefab\",\"before\":\"nosuchref\",\"after\":\"HEAD\",\"projectRoot\":");
    try core.json.writeJsonString(&req_w.writer, dir);
    try req_w.writer.writeAll("}}}\n");
    const res = try roundtrip(arena, req_w.toArrayList().items);
    var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, res, "\n"), '\n');
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
```

@embedFile 用に build.zig の cli モジュール(exe と cli_tests の 2 箇所)へ匿名 import を追加する必要がある。Step 3 で行う。

- [ ] **Step 2: RED を確認**

Run: `zig build test 2>&1 | tail -10`
Expected: `truncateTree` / `testdata_plane_before` 未定義のコンパイルエラー

- [ ] **Step 3: 最小実装**

build.zig — cli 用モジュール定義(exe と cli_tests の `imports`)に testdata を追加(2 箇所とも):

```zig
            .imports = &.{
                .{ .name = "core", .module = core_mod },
                .{ .name = "testdata_plane_before", .module = b.createModule(.{ .root_source_file = b.path("core/src/testdata/plane_before.prefab") }) },
                .{ .name = "testdata_plane_after", .module = b.createModule(.{ .root_source_file = b.path("core/src/testdata/plane_after.prefab") }) },
            },
```

注: Zig で非 .zig ファイルをモジュールにできない場合は、`@embedFile` をやめて `b.addOptions()` の `addOptionPath` で testdata の絶対パスを渡し、テスト内で `std.Io.Dir.cwd().readFileAlloc` に置き換える(挙動は同じ)。

mcp.zig:

```zig
pub const tree_char_limit: usize = 50_000;

/// LLM コンテキスト保護(旧 diff.ts の truncateTree と同一挙動、単位はバイト)。
pub fn truncateTree(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (text.len <= tree_char_limit) return text;
    return std.fmt.allocPrint(arena, "{s}\n[truncated: {d} chars total]\n", .{ text[0..tree_char_limit], text.len });
}

fn validationError(w: *std.Io.Writer, id: std.json.Value, msg: []const u8) !void {
    try writeEnvelopePrefix(w, id);
    try w.writeAll("\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"Input validation error: ");
    try w.writeAll(msg); // msg は静的文字列のみ(エスケープ不要な範囲で書く)
    try w.writeAll("\"}],\"isError\":true}}\n");
}

/// arguments から文字列を取り出す。キー欠落は null、型違いは error.Invalid。
fn getString(args: ?std.json.Value, key: []const u8) error{Invalid}!?[]const u8 {
    const a = args orelse return null;
    if (a != .object) return error.Invalid;
    const v = a.object.get(key) orelse return null;
    if (v != .string) return error.Invalid;
    return v.string;
}

fn handleToolsCall(io: std.Io, arena: std.mem.Allocator, w: *std.Io.Writer, id: std.json.Value, params: ?std.json.Value) !void {
    const p = params orelse .null;
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

    // 旧 TS ホストの buildArgs + cwd=projectRoot と同じ argv(--project が git repo dir を兼ねる)。
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
        try writeEnvelopePrefix(w, id);
        try w.writeAll("\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
        const msg = try std.fmt.allocPrint(arena, "prefablens failed: {s}", .{@errorName(err)});
        try core.json.writeJsonString(w, msg);
        try w.writeAll("}],\"isError\":true}}\n");
        return;
    };
    if (code != 0) {
        const stderr_text = std.mem.trim(u8, aw_err.toArrayList().items, " \t\r\n");
        const text = if (stderr_text.len > 0) stderr_text else try std.fmt.allocPrint(arena, "prefablens exited with code {d}", .{code});
        try writeEnvelopePrefix(w, id);
        try w.writeAll("\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
        try core.json.writeJsonString(w, text);
        try w.writeAll("}],\"isError\":true}}\n");
        return;
    }
    const stdout_text = aw.toArrayList().items;
    const text = if (is_json) stdout_text else try truncateTree(arena, stdout_text);
    try writeEnvelopePrefix(w, id);
    try w.writeAll("\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
    try core.json.writeJsonString(w, text);
    try w.writeAll("}]}}\n");
}
```

handleLine のルーティングに追加(tools/list の後)し、`_ = io;` を削除:

```zig
    } else if (std.mem.eql(u8, method, "tools/call")) {
        try handleToolsCall(io, arena, w, id, obj.get("params"));
```

注: 旧 TS ホストのエラー text は stderr を trim したもの。CLI の stderr は `error: git show failed ...` 形式なので、パリティ golden(server.test.ts)は `toContain` 相当の部分一致で照合している — Zig 側テストも `indexOf` で同じ照合をする。`error: ` プレフィックスの有無は旧ホストも保持していた(stderr そのまま)ため一致する。

- [ ] **Step 4: GREEN を確認**

Run: `zig build test 2>&1 | tail -5`
Expected: 全テスト pass(tree golden が一致しない場合は実際の CLI 出力を目視して golden 側の転記ミスを疑う — server.test.ts の期待値が正)

- [ ] **Step 5: Commit**

```bash
git add cli/src/mcp.zig build.zig
git commit -m "feat: mcp tools/call runs diff in process"
```

### Task 5: main() ディスパッチ + 実バイナリ smoke(build graph)

**Files:**
- Modify: `cli/src/main.zig`(main() 冒頭のサブコマンド分岐)
- Modify: `build.zig`(smoke ステップを test に接続)

**Interfaces:**
- Consumes: `mcp.serve(...)`、`mcp.tools_list_result`(golden 側と一致必須)

- [ ] **Step 1: main() に分岐を実装**(先にディスパッチを書く。RED は Step 2 の smoke が担う)

main.zig の import 部に `pub const mcp = @import("mcp.zig");` を追加(既存の `pub const resolve = ...` 群の並び)。main() の `user_args` 決定直後に:

```zig
    if (user_args.len >= 1 and std.mem.eql(u8, user_args[0], "mcp")) {
        var stdin_buffer: [64 * 1024]u8 = undefined;
        var stdin_reader: std.Io.File.Reader = .init(.stdin(), init.io, &stdin_buffer);
        try mcp.serve(init.io, std.heap.page_allocator, &stdin_reader.interface, stdout);
        try stdout.flush();
        return 0;
    }
```

- [ ] **Step 2: build.zig に smoke を追加し、失敗(未ビルド)から通す**

`test_step` 定義の後に:

```zig
    // 実バイナリでの MCP プロトコル smoke。git 不要な静的応答のみを exact match する。
    // 期待値の tools/list 行は cli/src/mcp.zig の tools_list_result と一字一句一致させること。
    const mcp_smoke = b.addRunArtifact(exe);
    mcp_smoke.addArg("mcp");
    mcp_smoke.setStdIn(.{ .bytes = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"prefab_diff\",\"arguments\":{\"path\":\"\"}}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"nope\"}\n" });
    mcp_smoke.expectStdOutEqual("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":" ++ tools_list_json ++ "}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"Input validation error: path must be a non-empty string\"}],\"isError\":true}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}\n");
    test_step.dependOn(&mcp_smoke.step);
```

`tools_list_json` は build.zig 冒頭に `const tools_list_json = "...";`(Task 3 の `tools_list_result` の完全コピー)として置く。コメントで相互参照を明記する。

- [ ] **Step 3: GREEN を確認**

Run: `zig build test 2>&1 | tail -5`
Expected: 全テスト + smoke pass

- [ ] **Step 4: 手動 smoke(実配線の最終確認)**

```bash
zig build
printf '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}\n{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n' | ./zig-out/bin/prefablens mcp
```
Expected: initialize 応答(serverInfo.version=0.2.0)と tools/list 応答の 2 行

- [ ] **Step 5: Commit**

```bash
git add cli/src/main.zig build.zig
git commit -m "feat: mcp subcommand entry and smoke test"
```

### Task 6: PR 1 仕上げ

- [ ] **Step 1: フル検証**

```bash
zig build test && zig build && echo OK
```
Expected: OK(警告・エラーなし)

- [ ] **Step 2: spec と plan をコミットに含めて push、PR 作成**

```bash
git add docs/superpowers/specs/2026-07-05-mcp-zig-native-design.md docs/superpowers/plans/2026-07-05-mcp-zig-native.md
git commit -m "docs: mcp zig native spec and plan"
git push -u origin feat/mcp-subcommand
gh pr create --title "feat: add mcp subcommand serving stdio json-rpc" --body "(spec/plan 参照。TS ホストとの挙動パリティは server.test.ts golden の移植テストで担保)"
```

- [ ] **Step 3: CI green を確認して squash マージ**

```bash
gh pr checks <N> --watch --interval 20
gh pr merge <N> --squash --delete-branch
```

- [ ] **Step 4: マージ後、実クライアントで手動確認**(切り替え前の受け入れ)

```bash
git switch main && git pull --ff-only && zig build
claude mcp add --scope user prefablens-zig -- "$(pwd)/zig-out/bin/prefablens" mcp
# 別プロジェクトの Claude Code から prefab_diff を 1 回叩いて出力を目視
claude mcp remove --scope user prefablens-zig
```

---

## PR 2: `chore/remove-ts-mcp`(切り替え)

ブランチ: `git switch -c chore/remove-ts-mcp`(PR 1 マージ後の main から)

### Task 7: TS ホスト削除と CI/リリースの追随

**Files:**
- Delete: `mcp/`(ディレクトリごと)
- Modify: `.github/workflows/ci.yml`(mcp ジョブ → windows zig ジョブ)
- Modify: `.github/workflows/release.yml`(npm publish ステップ削除)

- [ ] **Step 1: mcp/ を削除**

```bash
git rm -r mcp
```

- [ ] **Step 2: ci.yml の mcp ジョブを差し替え**(mcp ジョブのブロック全体を削除し、以下に置換)

```yaml
  windows:
    # mcp(旧 TS ホスト)ジョブの後継。プロセス spawn・パス・改行のプラットフォーム差を
    # zig 側テスト(mcp サブコマンド含む)で押さえる。
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v7
      - name: Install tools
        uses: jdx/mise-action@v4
      - name: Test
        run: zig build test
      - name: Build
        run: zig build
```

- [ ] **Step 3: release.yml から「Publish MCP server to npm」ステップを削除**(if:false のブロックと直前のコメント行ごと)

- [ ] **Step 4: 検証**

```bash
ruby -ryaml -e "YAML.load_file('.github/workflows/ci.yml'); YAML.load_file('.github/workflows/release.yml'); puts 'yaml ok'"
zig build test && echo OK
```
Expected: yaml ok / OK

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: remove ts mcp host"
```

### Task 8: リリース系ツールとドキュメントの追随

**Files:**
- Modify: `.claude/skills/cut-release/SKILL.md`
- Modify: `.claude/skills/cut-release/scripts/check-versions.sh`
- Create: `docs/mcp.md`(セットアップ手順の移設先)

- [ ] **Step 1: check-versions.sh の 5 ソース構成員を交代**

```bash
# 変更前: mpkg=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' mcp/package.json | head -1)
# 変更後:
zver=$(sed -n 's/.*pub const version = "\([^"]*\)".*/\1/p' cli/src/main.zig | head -1)
# check 行も対応:
check "cli/src/main.zig"          "$zver"
```

(`check "mcp/package.json" "$mpkg"` 行を削除して上記に置換。「all five version sources」の文言は維持)

- [ ] **Step 2: SKILL.md を更新**

- 5 ソースの箇条書き: `mcp/package.json` 行を `cli/src/main.zig` → `pub const version = "X.Y.Z";` に置換
- npm 関連の記述(description の npm 言及、done 定義の `npm view`、Trusted Publisher 注記、publish 再開手順)を削除
- MCP の配布は「リリース zip のバイナリそのもの」である旨を 1 行追記

- [ ] **Step 3: docs/mcp.md を作成**(旧 mcp/README.md の後継。内容は以下)

```markdown
# PrefabLens MCP server

`prefablens mcp` は MCP stdio サーバーを起動する(ツールは `prefab_diff` 1 つ)。
ランタイム依存はない — CLI バイナリがそのままサーバーになる。

## Setup (Claude Code)

    claude mcp add --scope user prefablens -- /path/to/prefablens mcp

バイナリは GitHub Releases の zip(SHA256SUMS 付き)か `zig build` で入手する。

## Tool: prefab_diff

パラメータと挙動は旧 npm 版と同一(path / before=HEAD / after / projectRoot / format=tree|json、
tree は 50k 文字で truncate)。git ロジックは CLI と共通。
```

- [ ] **Step 4: 検証**

```bash
bash .claude/skills/cut-release/scripts/check-versions.sh 0.2.0
```
Expected: `all five version sources at 0.2.0`(cli/src/main.zig を含む 5 行が ok)

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: update release tooling for zig mcp"
```

### Task 9: PR 2 仕上げと切り替え

- [ ] **Step 1: フル検証**

```bash
zig build test && zig build && ruby -ryaml -e "YAML.load_file('.github/workflows/ci.yml'); puts 'ok'"
grep -rn "prefablens-mcp\|PREFABLENS_CLI\|mcp/package.json" --include="*.md" --include="*.yml" --include="*.sh" . | grep -v docs/superpowers | grep -v node_modules
```
Expected: テスト green、grep は削除漏れゼロ(spec/plan 内の歴史記述は除外してよい)

- [ ] **Step 2: PR 作成 → CI green → squash マージ**

```bash
git push -u origin chore/remove-ts-mcp
gh pr create --title "chore: remove ts mcp host" --body "(PR 1 の Zig 実装への切り替え。revert で TS ホスト完全復活可)"
gh pr checks <N> --watch --interval 20
gh pr merge <N> --squash --delete-branch
```

- [ ] **Step 3: ローカル MCP 登録を切り替え**

```bash
claude mcp remove --scope user prefablens
git switch main && git pull --ff-only && zig build
claude mcp add --scope user prefablens -- "$(git rev-parse --show-toplevel)/zig-out/bin/prefablens" mcp
```

- [ ] **Step 4: 台帳とメモリを更新**(progress.md にセッション節を追記、prefablens-mcp-zig-native メモリを「完了」に更新)
