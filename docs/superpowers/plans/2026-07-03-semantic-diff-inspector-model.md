# Semantic Diff Inspector メンタルモデル準拠 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** semantic diff の出力を UnityEditor の Hierarchy / Inspector で得られる情報に置き換える(spec: `docs/superpowers/specs/2026-07-03-semantic-diff-inspector-model-design.md`)。

**Architecture:** 変換ロジックはすべて Zig core に集約(inspector.zig 新設 + diff/tree/json 拡張)。JSON スキーマを `prefablens.diff.v2` に上げ、CLI / Chrome 拡張のレンダラーは v2 追従のみ(マッピングテーブルを持たない)。

**Tech Stack:** Zig 0.16(core/CLI)、TypeScript + vitest(extension)、WASM(zig build wasm → `zig-out/bin/prefablens.wasm`)。

## Global Constraints

- スキーマ文字列は正確に `prefablens.diff.v2`(旧 `prefablens.diff.v1` の互換レイヤーは持たない)
- parser.zig の stripped 検出は**実装済み**(`parser.zig:323-325`、`model.Document.stripped`)— 触らない
- コミットは 1 行メッセージ `<type>: <英語 subject ≤50 文字>`(git-conventions)
- テスト実行: core/CLI は `zig build test`、extension は `cd extension && npm test`、型は `npm run typecheck`
- WASM サイズ予算: gzip ≤ 80 KB 目標、150 KB 超で CI 失敗(`npm run size`)
- 表示次元の規則(spec §表示イメージ): オブジェクト行直下は `components` セクションと子オブジェクトのみ。コンポーネント/override グループは必ず components 配下、プロパティは必ずコンポーネント配下
- ブランチは `feat/inspector-model-diff`(作成済み、spec コミット済み)

---

### Task 1: inspector.zig — 非表示テーブル・表示名変換・グループ推測

**Files:**
- Create: `core/src/inspector.zig`
- Modify: `core/src/root.zig`(export 追加)

**Interfaces:**
- Consumes: なし(純関数のみ)
- Produces:
  - `pub fn isHidden(path: []const u8) bool` — パス先頭セグメントが Inspector 非表示テーブルにあるか
  - `pub fn displayPath(arena: std.mem.Allocator, path: []const u8) ![]const u8` — `"m_LocalPosition.x"` → `"Position.x"`、`"maxHp"` → `"Max Hp"`
  - `pub fn groupOf(property_path: []const u8) []const u8` — `"Transform"` / `"GameObject"` / `"Overrides"`

- [ ] **Step 1: 失敗するテストを書く**

`core/src/inspector.zig` を作成し、テストを先頭に置く(このリポジトリの慣習):

```zig
const std = @import("std");
const testing = std.testing;

test "inspector: hidden fields are hidden by first path segment" {
    try testing.expect(isHidden("m_ObjectHideFlags"));
    try testing.expect(isHidden("m_GameObject"));
    try testing.expect(isHidden("m_Children[3]"));
    try testing.expect(isHidden("m_LocalEulerAnglesHint.x"));
    try testing.expect(isHidden("m_EditorClassIdentifier"));
    try testing.expect(isHidden("serializedVersion"));
    try testing.expect(!isHidden("m_LocalPosition.x"));
    try testing.expect(!isHidden("maxHp"));
}

test "inspector: displayPath maps table entries and nicifies the rest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("Position.x", try displayPath(arena, "m_LocalPosition.x"));
    try testing.expectEqualStrings("Rotation", try displayPath(arena, "m_LocalRotation"));
    try testing.expectEqualStrings("Scale.y", try displayPath(arena, "m_LocalScale.y"));
    try testing.expectEqualStrings("Name", try displayPath(arena, "m_Name"));
    try testing.expectEqualStrings("Max Hp", try displayPath(arena, "maxHp"));
    try testing.expectEqualStrings("Constrain Proportions Scale", try displayPath(arena, "m_ConstrainProportionsScale"));
    try testing.expectEqualStrings("Materials[0]", try displayPath(arena, "m_Materials[0]"));
}

test "inspector: groupOf infers pseudo component from propertyPath" {
    try testing.expectEqualStrings("Transform", groupOf("m_LocalPosition.x"));
    try testing.expectEqualStrings("Transform", groupOf("m_LocalScale.y"));
    try testing.expectEqualStrings("GameObject", groupOf("m_Name"));
    try testing.expectEqualStrings("GameObject", groupOf("m_IsActive"));
    try testing.expectEqualStrings("Overrides", groupOf("maxHp"));
}
```

- [ ] **Step 2: テストが失敗する(コンパイルエラー)ことを確認**

Run: `zig build test 2>&1 | head -20`
Expected: `isHidden` 未定義でコンパイル失敗

- [ ] **Step 3: 実装を書く**

テストの下に実装を追加:

```zig
/// Inspector に表示されないフィールド(パス先頭セグメントで判定)。
const hidden = [_][]const u8{
    "m_ObjectHideFlags",
    "m_CorrespondingSourceObject",
    "m_PrefabInstance",
    "m_PrefabAsset",
    "m_GameObject",
    "m_Father",
    "m_Children",
    "m_Component",
    "m_LocalEulerAnglesHint",
    "m_EditorHideFlags",
    "m_EditorClassIdentifier",
    "serializedVersion",
    "m_RootOrder",
};

/// 主要ビルトインの Inspector 表示名(先頭セグメント単位)。
const display = [_]struct { raw: []const u8, shown: []const u8 }{
    .{ .raw = "m_LocalPosition", .shown = "Position" },
    .{ .raw = "m_LocalRotation", .shown = "Rotation" },
    .{ .raw = "m_LocalScale", .shown = "Scale" },
    .{ .raw = "m_Name", .shown = "Name" },
    .{ .raw = "m_IsActive", .shown = "Active" },
    .{ .raw = "m_Enabled", .shown = "Enabled" },
    .{ .raw = "m_TagString", .shown = "Tag" },
    .{ .raw = "m_Layer", .shown = "Layer" },
    .{ .raw = "m_Script", .shown = "Script" },
};

fn firstSegment(path: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, path, '.') orelse path.len;
    const seg = path[0..dot];
    const br = std.mem.indexOfScalar(u8, seg, '[') orelse seg.len;
    return seg[0..br];
}

pub fn isHidden(path: []const u8) bool {
    const head = firstSegment(path);
    for (hidden) |h| if (std.mem.eql(u8, head, h)) return true;
    return false;
}

pub fn displayPath(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, path, '.');
    var first = true;
    while (it.next()) |seg| {
        if (!first) try out.append(arena, '.');
        first = false;
        try appendSegment(arena, &out, seg);
    }
    return out.toOwnedSlice(arena);
}

/// "[N]" 添字は名前部の後ろにそのまま残す。
fn appendSegment(arena: std.mem.Allocator, out: *std.ArrayList(u8), seg: []const u8) !void {
    const br = std.mem.indexOfScalar(u8, seg, '[') orelse seg.len;
    try appendNicified(arena, out, seg[0..br]);
    try out.appendSlice(arena, seg[br..]);
}

/// Unity の ObjectNames.NicifyVariableName 相当: 固定テーブル →
/// "m_" 除去 + 先頭大文字化 + 小文字/数字→大文字境界に空白挿入。
fn appendNicified(arena: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8) !void {
    for (display) |d| if (std.mem.eql(u8, name, d.raw)) {
        try out.appendSlice(arena, d.shown);
        return;
    };
    var s = name;
    if (std.mem.startsWith(u8, s, "m_")) s = s[2..];
    if (s.len == 0) {
        try out.appendSlice(arena, name);
        return;
    }
    // 単一小文字セグメント (x/y/z/w) は Inspector 同様そのまま。
    if (s.len == 1 and std.ascii.isLower(s[0])) {
        try out.appendSlice(arena, s);
        return;
    }
    try out.append(arena, std.ascii.toUpper(s[0]));
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (std.ascii.isUpper(c) and (std.ascii.isLower(s[i - 1]) or std.ascii.isDigit(s[i - 1]))) {
            try out.append(arena, ' ');
        }
        try out.append(arena, c);
    }
}

const transform_props = [_][]const u8{
    "m_LocalPosition", "m_LocalRotation", "m_LocalScale",
    "m_LocalEulerAnglesHint", "m_ConstrainProportionsScale",
};
const game_object_props = [_][]const u8{
    "m_Name", "m_IsActive", "m_TagString", "m_Layer", "m_StaticEditorFlags", "m_Icon",
};

pub fn groupOf(property_path: []const u8) []const u8 {
    const head = firstSegment(property_path);
    for (transform_props) |t| if (std.mem.eql(u8, head, t)) return "Transform";
    for (game_object_props) |g| if (std.mem.eql(u8, head, g)) return "GameObject";
    return "Overrides";
}
```

`core/src/root.zig` に export を追加(`pub const json = ...` の行の後):

```zig
pub const inspector = @import("inspector.zig");
```

- [ ] **Step 4: テストが通ることを確認**

Run: `zig build test`
Expected: PASS(全テスト)

- [ ] **Step 5: Commit**

```bash
git add core/src/inspector.zig core/src/root.zig
git commit -m "feat: add inspector hidden/display/group tables"
```

---

### Task 2: model.zig — ObjectKind / OverrideDiff / class_name の型拡張

**Files:**
- Modify: `core/src/model.zig`(`Status` の定義の後に追加、`ComponentDiff` / `ObjectDiff` にフィールド追加)

**Interfaces:**
- Consumes: なし
- Produces(後続タスク全部が使う):
  - `pub const ObjectKind = enum { game_object, prefab_instance };`
  - `pub const OverrideDiff = struct { group, label: []const u8, status: Status, before, after: ?*const Node };`
  - `ComponentDiff.class_name: ?[]const u8 = null`
  - `ObjectDiff.kind: ObjectKind = .game_object` / `ObjectDiff.source_guid: ?[]const u8 = null` / `ObjectDiff.overrides: []OverrideDiff = &.{}`

全フィールドにデフォルト値を付けるので既存コードはコンパイルが通り続ける(挙動変更なし)。

- [ ] **Step 1: 型を追加**

`core/src/model.zig` の `pub const Status = enum { ... };` の直後に:

```zig
pub const ObjectKind = enum { game_object, prefab_instance };

/// PrefabInstance の (target, propertyPath) 単位の override diff。
pub const OverrideDiff = struct {
    group: []const u8, // "Transform" | "GameObject" | "Overrides"
    label: []const u8, // humanize 済み ("Position.x")
    status: Status,
    before: ?*const Node = null,
    after: ?*const Node = null,
};
```

`ComponentDiff` に追加(`script_guid` の次):

```zig
    /// m_EditorClassIdentifier 末尾のクラス名 ("Cylinder1")。guid 解決の第 2 候補。
    class_name: ?[]const u8 = null,
```

`ObjectDiff` に追加(`file_id` の前に kind、`components` の前に source_guid/overrides):

```zig
pub const ObjectDiff = struct {
    kind: ObjectKind = .game_object,
    file_id: i64,
    name: []const u8,
    status: Status,
    /// prefab_instance のみ: m_SourcePrefab の guid。
    source_guid: ?[]const u8 = null,
    /// prefab_instance のみ: (target, propertyPath) キーの override diff。
    overrides: []OverrideDiff = &.{},
    components: []ComponentDiff,
    children: []ObjectDiff,
};
```

- [ ] **Step 2: コンパイルと既存テストが通ることを確認**

Run: `zig build test`
Expected: PASS(挙動変更なし)

- [ ] **Step 3: Commit**

```bash
git add core/src/model.zig
git commit -m "feat: add ObjectKind and OverrideDiff to model"
```

---

### Task 3: diff.zig — stripped 除外 + 非表示フィルタ + humanize + class_name

**Files:**
- Modify: `core/src/diff.zig`(compute とテスト)
- Modify: `cli/src/render_tree.zig:27`・`cli/src/render_html.zig`(humanize で壊れるテスト表明の追従)

**Interfaces:**
- Consumes: Task 1 `inspector.isHidden` / `inspector.displayPath`、Task 2 の型
- Produces:
  - `DocDiff.overrides: []model.OverrideDiff = &.{}`・`DocDiff.class_name: ?[]const u8 = null`(値は Task 5 で入る)
  - `compute()` は stripped ドキュメントを `docs` に出さない(`before`/`after` 配列には残す — tree の橋渡しに使う)
  - `DocDiff.fields[].path` は humanize 済み・非表示フィールド除去済み

- [ ] **Step 1: 失敗するテストを書く**

`core/src/diff.zig` のテスト群に追加:

```zig
test "diff: stripped documents are excluded from docs but kept in before/after" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: A
    ;
    const after =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: A
        \\--- !u!4 &42 stripped
        \\Transform:
        \\  m_PrefabInstance: {fileID: 99}
    ;
    const fd = try compute(arena, before, after);
    try testing.expect(findDoc(fd, 42) == null);
    // 構造解決用に after 配列には残る。
    var found = false;
    for (fd.after) |d| if (d.file_id == 42) {
        found = true;
        try testing.expect(d.stripped);
    };
    try testing.expect(found);
}

test "diff: hidden fields are dropped and paths humanized" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_LocalPosition: {x: 0, y: 0, z: 0}
    ;
    const after =
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 2}
        \\  m_LocalPosition: {x: 1, y: 0, z: 0}
    ;
    const fd = try compute(arena, before, after);
    const d = findDoc(fd, 4).?;
    // m_GameObject の変更は非表示。m_LocalPosition.x は "Position.x" に。
    try testing.expectEqual(@as(usize, 1), d.fields.len);
    try testing.expectEqualStrings("Position.x", d.fields[0].path);
}

test "diff: hidden-only changes leave the document unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!4 &4
        \\Transform:
        \\  m_LocalEulerAnglesHint: {x: 0, y: 0, z: 0}
    ;
    const after =
        \\--- !u!4 &4
        \\Transform:
        \\  m_LocalEulerAnglesHint: {x: 0, y: 90, z: 0}
    ;
    const fd = try compute(arena, before, after);
    try testing.expectEqual(model.Status.unchanged, findDoc(fd, 4).?.status);
}

test "diff: editor class identifier tail is extracted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_EditorClassIdentifier: Assembly-CSharp::Cylinder1
        \\  hp: 1
    ;
    const src2 =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_EditorClassIdentifier: Assembly-CSharp::Cylinder1
        \\  hp: 2
    ;
    const fd = try compute(arena, src, src2);
    try testing.expectEqualStrings("Cylinder1", findDoc(fd, 5).?.class_name.?);
}
```

既存テストの表明を humanize 後の値に更新:
- `diff.zig` の "diff: modified scalar field is detected old->new": `expectEqualStrings("maxHp", ...)` → `expectEqualStrings("Max Hp", ...)`
- `diff.zig` の "diff: nested field path and added field": `"m_LocalPosition.y"` → `"Position.y"`、`startsWith(u8, f.path, "m_LocalScale")` → `startsWith(u8, f.path, "Scale")`(このテストの added 側は Task 4 でさらに変わる — ここでは `saw_added_scale` 判定が通る形を保つ)

- [ ] **Step 2: テストが失敗することを確認**

Run: `zig build test 2>&1 | head -30`
Expected: 新テスト 4 本が FAIL(`class_name` 未定義のコンパイルエラーから始まる)

- [ ] **Step 3: 実装**

`core/src/diff.zig` 冒頭の import 群に追加:

```zig
const inspector = @import("inspector.zig");
```

`DocDiff` にフィールド追加:

```zig
pub const DocDiff = struct {
    file_id: i64,
    class_id: u32,
    type_name: []const u8,
    script_guid: ?[]const u8 = null,
    class_name: ?[]const u8 = null,
    status: Status,
    fields: []FieldDiff,
    overrides: []model.OverrideDiff = &.{},
};
```

ヘルパーを `scriptGuid` の近くに追加:

```zig
/// "Assembly-CSharp::Cylinder1" -> "Cylinder1"(最後の ':' より後)。
fn editorClassName(doc: *const model.Document) ?[]const u8 {
    const v = model.findValue(doc.body.map, "m_EditorClassIdentifier") orelse return null;
    const s = switch (v.*) {
        .scalar => |s| s,
        else => return null,
    };
    const idx = std.mem.lastIndexOfScalar(u8, s, ':') orelse (if (s.len != 0) return s else return null);
    const tail = s[idx + 1 ..];
    return if (tail.len != 0) tail else null;
}

/// 生の field diff から Inspector 非表示を落とし、path を表示名に置換する。
fn presentFields(arena: std.mem.Allocator, raw: []FieldDiff) ![]FieldDiff {
    var kept: std.ArrayList(FieldDiff) = .empty;
    for (raw) |f| {
        if (inspector.isHidden(f.path)) continue;
        var out = f;
        out.path = try inspector.displayPath(arena, f.path);
        try kept.append(arena, out);
    }
    return kept.toOwnedSlice(arena);
}
```

`compute()` を変更 — after ループ先頭に stripped スキップ、modified 分岐で presentFields、DocDiff 構築に class_name:

```zig
    for (after) |*ad| {
        if (ad.stripped) continue;
        try collectGuids(&guids, ad.body);
        const bd = before_idx.get(ad.file_id);
        if (bd) |b| {
            try collectGuids(&guids, b.body);
            var raw: std.ArrayList(FieldDiff) = .empty;
            try diffNode(arena, &raw, "", b.body, ad.body);
            const fields = try presentFields(arena, try raw.toOwnedSlice(arena));
            try docs.append(arena, .{
                .file_id = ad.file_id,
                .class_id = ad.class_id,
                .type_name = try resolvedTypeName(ad),
                .script_guid = scriptGuid(ad),
                .class_name = editorClassName(ad),
                .status = if (fields.len == 0) .unchanged else .modified,
                .fields = fields,
            });
        } else {
            try docs.append(arena, .{
                .file_id = ad.file_id,
                .class_id = ad.class_id,
                .type_name = try resolvedTypeName(ad),
                .script_guid = scriptGuid(ad),
                .class_name = editorClassName(ad),
                .status = .added,
                .fields = &[_]FieldDiff{},
            });
        }
    }
    for (before) |*bd| {
        if (bd.stripped) continue;
        if (after_idx.contains(bd.file_id)) continue;
        ...(既存のまま、.class_name = editorClassName(bd) を追加)...
    }
```

- [ ] **Step 4: CLI テストの表明を追従**

humanize により CLI 経由のテキストも変わる:
- `cli/src/render_tree.zig` の "render: modified field shown old -> new without color": `indexOf(u8, text, "volume")` → `indexOf(u8, text, "Volume")`
- `cli/src/render_html.zig` の "html: added and removed fields render only their one side": `"m_NewField"` → `"New Field"`、`"m_OldField"` → `"Old Field"`
- `cli/src/render_html.zig` の "html: self-contained document with escaped content": `indexOf(u8, html, "hp")` はそのまま通る(`hp` → `Hp` を含むため)が、明示的に `"Hp"` に更新する

- [ ] **Step 5: テストが通ることを確認**

Run: `zig build test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add core/src/diff.zig cli/src/render_tree.zig cli/src/render_html.zig
git commit -m "feat: hide non-inspector fields and humanize paths"
```

---

### Task 4: diff.zig — added サブツリーの平坦化とベクトル縮約

**Files:**
- Modify: `core/src/diff.zig`

**Interfaces:**
- Consumes: Task 3 の `presentFields`
- Produces:
  - `fn flattenSubtree(arena, out: *std.ArrayList(FieldDiff), prefix: []const u8, node: *const Node, status: Status) anyerror!void` — added/removed サブツリーを leaf 単位の FieldDiff に展開。ベクトル風 map(キーが全部 x/y/z/w/r/g/b/a の scalar)は `"(v1, v2, v3)"` の 1 行に縮約
  - added ドキュメント(classID 1001 以外)の `fields` に after body の全展開が入る

- [ ] **Step 1: 失敗するテストを書く**

```zig
test "diff: added document enumerates fields with vector collapse" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = "";
    const after =
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_LocalPosition: {x: 4, y: 0, z: 0}
        \\  maxHp: 100
    ;
    const fd = try compute(arena, before, after);
    const d = findDoc(fd, 4).?;
    try testing.expectEqual(model.Status.added, d.status);
    // m_GameObject は非表示。Position はベクトル 1 行、maxHp は Max Hp。
    try testing.expectEqual(@as(usize, 2), d.fields.len);
    try testing.expectEqualStrings("Position", d.fields[0].path);
    try testing.expectEqualStrings("(4, 0, 0)", d.fields[0].after.?.scalar);
    try testing.expectEqualStrings("Max Hp", d.fields[1].path);
}

test "diff: added map field inside a modified document is flattened" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!4 &4
        \\Transform:
        \\  m_LocalPosition: {x: 0, y: 0, z: 0}
    ;
    const after =
        \\--- !u!4 &4
        \\Transform:
        \\  m_LocalPosition: {x: 0, y: 5, z: 0}
        \\  m_LocalScale: {x: 1, y: 1, z: 1}
    ;
    const fd = try compute(arena, before, after);
    const d = findDoc(fd, 4).?;
    var saw_scale = false;
    for (d.fields) |f| {
        if (std.mem.eql(u8, f.path, "Scale")) {
            saw_scale = true;
            try testing.expectEqual(model.Status.added, f.status);
            try testing.expectEqualStrings("(1, 1, 1)", f.after.?.scalar);
        }
    }
    try testing.expect(saw_scale);
}
```

既存テスト "diff: nested field path and added field" の `saw_added_scale` 判定を更新: `startsWith(u8, f.path, "Scale")` のままで通る(path が `"Scale"` の 1 行になる)。

- [ ] **Step 2: テストが失敗することを確認**

Run: `zig build test 2>&1 | head -30`
Expected: 新テスト 2 本 FAIL(added doc は fields 空、added map は 1 行に潰れていない)

- [ ] **Step 3: 実装**

ヘルパー(`diffSeq` の後ろに追加):

```zig
fn isVectorMap(entries: []model.Entry) bool {
    if (entries.len < 2 or entries.len > 4) return false;
    for (entries) |e| {
        if (e.value.* != .scalar) return false;
        if (e.key.len != 1) return false;
        if (std.mem.indexOfScalar(u8, "xyzwrgba", e.key[0]) == null) return false;
    }
    return true;
}

fn vectorNode(arena: std.mem.Allocator, entries: []model.Entry) !*Node {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '(');
    for (entries, 0..) |e, i| {
        if (i != 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, e.value.scalar);
    }
    try out.append(arena, ')');
    const n = try arena.create(Node);
    n.* = .{ .scalar = try out.toOwnedSlice(arena) };
    return n;
}

fn appendLeaf(arena: std.mem.Allocator, out: *std.ArrayList(FieldDiff), path: []const u8, status: Status, node: *const Node) !void {
    try out.append(arena, switch (status) {
        .added => .{ .path = path, .status = .added, .before = null, .after = node },
        .removed => .{ .path = path, .status = .removed, .before = node, .after = null },
        else => unreachable,
    });
}

/// added/removed サブツリーを leaf 単位に展開する。ベクトル風 map は 1 行に縮約。
fn flattenSubtree(
    arena: std.mem.Allocator,
    out: *std.ArrayList(FieldDiff),
    prefix: []const u8,
    node: *const Node,
    status: Status,
) anyerror!void {
    switch (node.*) {
        .map => |entries| {
            if (isVectorMap(entries)) {
                try appendLeaf(arena, out, prefix, status, try vectorNode(arena, entries));
                return;
            }
            for (entries) |e| try flattenSubtree(arena, out, try joinKey(arena, prefix, e.key), e.value, status);
        },
        .seq => |items| for (items, 0..) |it, i| {
            const path = try std.fmt.allocPrint(arena, "{s}[{d}]", .{ prefix, i });
            try flattenSubtree(arena, out, path, it, status);
        },
        else => try appendLeaf(arena, out, prefix, status, node),
    }
}
```

`diffMap` の added/removed 分岐を差し替え:

```zig
        } else {
            try flattenSubtree(arena, out, path, ea.value, .removed);
        }
    }
    for (b) |eb| {
        if (model.findValue(a, eb.key) == null) {
            const path = try joinKey(arena, prefix, eb.key);
            try flattenSubtree(arena, out, path, eb.value, .added);
        }
    }
```

`diffSeq` の余剰要素も同様に `flattenSubtree(..., .removed)` / `flattenSubtree(..., .added)` に差し替え。

`compute()` の added 分岐(classID 1001 以外)で全展開:

```zig
        } else {
            var raw: std.ArrayList(FieldDiff) = .empty;
            if (ad.class_id != 1001) {
                for (ad.body.map) |e| try flattenSubtree(arena, &raw, e.key, e.value, .added);
            }
            try docs.append(arena, .{
                .file_id = ad.file_id,
                .class_id = ad.class_id,
                .type_name = try resolvedTypeName(ad),
                .script_guid = scriptGuid(ad),
                .class_name = editorClassName(ad),
                .status = .added,
                .fields = try presentFields(arena, try raw.toOwnedSlice(arena)),
            });
        }
```

- [ ] **Step 4: テストが通ることを確認**

Run: `zig build test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add core/src/diff.zig
git commit -m "feat: flatten added subtrees with vector collapse"
```

---

### Task 5: diff.zig — PrefabInstance override の (target, propertyPath) キー diff

**Files:**
- Modify: `core/src/diff.zig`

**Interfaces:**
- Consumes: Task 1 `inspector.groupOf` / `displayPath` / `isHidden`、Task 2 `model.OverrideDiff`
- Produces:
  - classID 1001 のドキュメントは `fields` 常に空、`overrides` に diff 結果が入る
  - modified: `(target.fileID, propertyPath)` キーで値比較、変更分のみ
  - added: 配置サマリ(Position/Rotation/Scale のベクトル合成、デフォルト値省略、`m_Name` 吸収)
  - `m_AddedComponents` 等の非空 seq は `Added Components (N)` の要約 1 行(group `"Overrides"`)

- [ ] **Step 1: 失敗するテストを書く**

```zig
test "diff: prefab instance override keyed by target+propertyPath" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalPosition.x
        \\      value: 0.41646004
        \\      objectReference: {fileID: 0}
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: Cylinder
        \\      objectReference: {fileID: 0}
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    // 順序を入れ替えつつ x のみ変更: 順序入れ替えは diff にならない。
    const after =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: Cylinder
        \\      objectReference: {fileID: 0}
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalPosition.x
        \\      value: 1
        \\      objectReference: {fileID: 0}
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    const fd = try compute(arena, before, after);
    const d = findDoc(fd, 1001).?;
    try testing.expectEqual(model.Status.modified, d.status);
    try testing.expectEqual(@as(usize, 0), d.fields.len);
    try testing.expectEqual(@as(usize, 1), d.overrides.len);
    try testing.expectEqualStrings("Transform", d.overrides[0].group);
    try testing.expectEqualStrings("Position.x", d.overrides[0].label);
    try testing.expectEqualStrings("0.41646004", d.overrides[0].before.?.scalar);
    try testing.expectEqualStrings("1", d.overrides[0].after.?.scalar);
}

test "diff: added prefab instance collapses placement to summary" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const after =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalPosition.x
        \\      value: 2.03
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalPosition.y
        \\      value: 3.63
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalPosition.z
        \\      value: 1.11797
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalRotation.w
        \\      value: 1
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalRotation.x
        \\      value: 0
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalRotation.y
        \\      value: 0
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalRotation.z
        \\      value: 0
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalEulerAnglesHint.x
        \\      value: 0
        \\    - target: {fileID: 8, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: Cylinder Variant
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    const fd = try compute(arena, "", after);
    const d = findDoc(fd, 1001).?;
    try testing.expectEqual(model.Status.added, d.status);
    // Position のみ: 合成 1 行。identity Rotation・EulerAnglesHint・m_Name は省略。
    try testing.expectEqual(@as(usize, 1), d.overrides.len);
    try testing.expectEqualStrings("Transform", d.overrides[0].group);
    try testing.expectEqualStrings("Position", d.overrides[0].label);
    try testing.expectEqualStrings("(2.03, 3.63, 1.11797)", d.overrides[0].after.?.scalar);
}

test "diff: added prefab instance keeps partial scale override" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const after =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications:
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalScale.y
        \\      value: 2
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    const fd = try compute(arena, "", after);
    const d = findDoc(fd, 1001).?;
    try testing.expectEqual(@as(usize, 1), d.overrides.len);
    try testing.expectEqualStrings("Scale.y", d.overrides[0].label);
    try testing.expectEqualStrings("2", d.overrides[0].after.?.scalar);
}

test "diff: non-empty added components produce a summary row" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications: []
        \\    m_AddedComponents: []
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    const after =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_Modifications: []
        \\    m_AddedComponents:
        \\    - targetCorrespondingSourceObject: {fileID: 7, guid: aaa, type: 3}
        \\      insertIndex: -1
        \\      addedObject: {fileID: 55}
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    const fd = try compute(arena, before, after);
    const d = findDoc(fd, 1001).?;
    try testing.expectEqual(@as(usize, 1), d.overrides.len);
    try testing.expectEqualStrings("Overrides", d.overrides[0].group);
    try testing.expectEqualStrings("Added Components (1)", d.overrides[0].label);
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `zig build test 2>&1 | head -30`
Expected: 新テスト 4 本 FAIL(1001 が通常 field diff として処理され `m_Modification...` の生パスが出る)

- [ ] **Step 3: 実装**

override 収集ヘルパー(`flattenSubtree` の後に追加):

```zig
const Mod = struct { target: i64, path: []const u8, value: ?*Node, obj_ref: ?*Node };

fn collectMods(arena: std.mem.Allocator, doc: *const model.Document) ![]Mod {
    var mods: std.ArrayList(Mod) = .empty;
    const m = model.findValue(doc.body.map, "m_Modification") orelse return mods.toOwnedSlice(arena);
    if (m.* != .map) return mods.toOwnedSlice(arena);
    const list = model.findValue(m.map, "m_Modifications") orelse return mods.toOwnedSlice(arena);
    if (list.* != .seq) return mods.toOwnedSlice(arena);
    for (list.seq) |item| {
        if (item.* != .map) continue;
        const pp = model.findValue(item.map, "propertyPath") orelse continue;
        if (pp.* != .scalar) continue;
        const target: i64 = blk: {
            const t = model.findValue(item.map, "target") orelse break :blk 0;
            break :blk switch (t.*) {
                .ref => |r| r.file_id,
                else => 0,
            };
        };
        try mods.append(arena, .{
            .target = target,
            .path = pp.scalar,
            .value = model.findValue(item.map, "value"),
            .obj_ref = objRefIfSet(model.findValue(item.map, "objectReference")),
        });
    }
    return mods.toOwnedSlice(arena);
}

fn objRefIfSet(n: ?*Node) ?*Node {
    const node = n orelse return null;
    return switch (node.*) {
        .ref => |r| if (r.file_id != 0 or r.guid != null) node else null,
        else => null,
    };
}

/// objectReference が設定されていればそれ、なければ value。
fn modValue(m: Mod) ?*Node {
    return m.obj_ref orelse m.value;
}

fn modKey(arena: std.mem.Allocator, m: Mod) ![]const u8 {
    return std.fmt.allocPrint(arena, "{d}:{s}", .{ m.target, m.path });
}

fn nodeEqlOpt(a: ?*const Node, b: ?*const Node) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return Node.eql(a.?, b.?);
}

fn makeOverride(arena: std.mem.Allocator, property_path: []const u8, status: Status, before: ?*const Node, after: ?*const Node) !model.OverrideDiff {
    return .{
        .group = inspector.groupOf(property_path),
        .label = try inspector.displayPath(arena, property_path),
        .status = status,
        .before = before,
        .after = after,
    };
}
```

modified 用 diff:

```zig
fn diffOverrides(arena: std.mem.Allocator, before_doc: ?*const model.Document, after_doc: *const model.Document) ![]model.OverrideDiff {
    var out: std.ArrayList(model.OverrideDiff) = .empty;
    const after_mods = try collectMods(arena, after_doc);
    const before_mods: []Mod = if (before_doc) |bd| try collectMods(arena, bd) else &.{};

    var before_map = std.StringHashMap(Mod).init(arena);
    for (before_mods) |m| try before_map.put(try modKey(arena, m), m);

    var seen = std.StringHashMap(void).init(arena);
    for (after_mods) |am| {
        const key = try modKey(arena, am);
        try seen.put(key, {});
        if (inspector.isHidden(am.path)) continue;
        const av: ?*const Node = modValue(am);
        if (before_map.get(key)) |bm| {
            const bv: ?*const Node = modValue(bm);
            if (nodeEqlOpt(bv, av)) continue;
            try out.append(arena, try makeOverride(arena, am.path, .modified, bv, av));
        } else {
            try out.append(arena, try makeOverride(arena, am.path, .added, null, av));
        }
    }
    // removed: before 側の順序で決定的に。
    for (before_mods) |bm| {
        if (seen.contains(try modKey(arena, bm))) continue;
        if (inspector.isHidden(bm.path)) continue;
        try out.append(arena, try makeOverride(arena, bm.path, .removed, modValue(bm), null));
    }
    try appendStructuralSummaries(arena, &out, before_doc, after_doc);
    return out.toOwnedSlice(arena);
}
```

added 用サマリ:

```zig
const Placement = struct { prefix: []const u8, label: []const u8, comps: []const []const u8 };
const placements = [_]Placement{
    .{ .prefix = "m_LocalPosition", .label = "Position", .comps = &.{ "x", "y", "z" } },
    .{ .prefix = "m_LocalRotation", .label = "Rotation", .comps = &.{ "x", "y", "z", "w" } },
    .{ .prefix = "m_LocalScale", .label = "Scale", .comps = &.{ "x", "y", "z" } },
};

fn scalarOf(n: ?*Node) ?[]const u8 {
    const node = n orelse return null;
    return switch (node.*) {
        .scalar => |s| s,
        else => null,
    };
}

fn numEql(s: []const u8, want: f64) bool {
    const v = std.fmt.parseFloat(f64, std.mem.trim(u8, s, " ")) catch return false;
    return v == want;
}

fn findMod(mods: []Mod, path: []const u8) ?Mod {
    for (mods) |m| if (std.mem.eql(u8, m.path, path)) return m;
    return null;
}

fn addedInstanceOverrides(arena: std.mem.Allocator, doc: *const model.Document) ![]model.OverrideDiff {
    const mods = try collectMods(arena, doc);
    var out: std.ArrayList(model.OverrideDiff) = .empty;

    // Placement サマリ: 全成分が揃っていれば合成 1 行(デフォルト値なら省略)。
    var consumed = [_]bool{false} ** placements.len;
    for (placements, 0..) |p, pi| {
        var vals: [4][]const u8 = undefined;
        var all = true;
        var is_default = true;
        for (p.comps, 0..) |c, i| {
            const path = try std.fmt.allocPrint(arena, "{s}.{s}", .{ p.prefix, c });
            const m = findMod(mods, path) orelse {
                all = false;
                break;
            };
            const v = scalarOf(m.value) orelse {
                all = false;
                break;
            };
            vals[i] = v;
            // デフォルト: Position/Scale の各成分は 0/1、Rotation は (0,0,0,1)。
            const want: f64 = if (std.mem.eql(u8, p.label, "Scale"))
                1
            else if (std.mem.eql(u8, p.label, "Rotation") and std.mem.eql(u8, c, "w"))
                1
            else
                0;
            if (!numEql(v, want)) is_default = false;
        }
        if (!all) continue;
        consumed[pi] = true;
        if (is_default) continue;
        var buf: std.ArrayList(u8) = .empty;
        try buf.append(arena, '(');
        for (p.comps, 0..) |_, i| {
            if (i != 0) try buf.appendSlice(arena, ", ");
            try buf.appendSlice(arena, vals[i]);
        }
        try buf.append(arena, ')');
        const n = try arena.create(Node);
        n.* = .{ .scalar = try buf.toOwnedSlice(arena) };
        try out.append(arena, .{ .group = "Transform", .label = p.label, .status = .added, .before = null, .after = n });
    }

    for (mods) |m| {
        if (inspector.isHidden(m.path)) continue;
        if (std.mem.eql(u8, m.path, "m_Name")) continue; // ノード名に吸収
        const in_consumed = blk: {
            for (placements, 0..) |p, pi| {
                if (consumed[pi] and std.mem.startsWith(u8, m.path, p.prefix) and
                    m.path.len > p.prefix.len and m.path[p.prefix.len] == '.') break :blk true;
            }
            break :blk false;
        };
        if (in_consumed) continue;
        try out.append(arena, try makeOverride(arena, m.path, .added, null, modValue(m)));
    }
    try appendStructuralSummaries(arena, &out, null, doc);
    return out.toOwnedSlice(arena);
}
```

構造変更の要約:

```zig
fn modificationSeqLen(doc: *const model.Document, key: []const u8) usize {
    const m = model.findValue(doc.body.map, "m_Modification") orelse return 0;
    if (m.* != .map) return 0;
    const v = model.findValue(m.map, key) orelse return 0;
    return switch (v.*) {
        .seq => |s| s.len,
        else => 0,
    };
}

/// m_Added*/m_Removed* の完全展開はスコープ外。件数の要約 1 行で情報が黙って消えるのを防ぐ。
fn appendStructuralSummaries(arena: std.mem.Allocator, out: *std.ArrayList(model.OverrideDiff), before_doc: ?*const model.Document, after_doc: *const model.Document) !void {
    const keys = [_]struct { key: []const u8, label: []const u8 }{
        .{ .key = "m_AddedGameObjects", .label = "Added GameObjects" },
        .{ .key = "m_AddedComponents", .label = "Added Components" },
        .{ .key = "m_RemovedComponents", .label = "Removed Components" },
        .{ .key = "m_RemovedGameObjects", .label = "Removed GameObjects" },
    };
    for (keys) |e| {
        const alen = modificationSeqLen(after_doc, e.key);
        const blen = if (before_doc) |bd| modificationSeqLen(bd, e.key) else 0;
        if (alen == blen) continue;
        try out.append(arena, .{
            .group = "Overrides",
            .label = try std.fmt.allocPrint(arena, "{s} ({d})", .{ e.label, alen }),
            .status = if (alen > blen) .added else .removed,
            .before = null,
            .after = null,
        });
    }
}
```

`compute()` の分岐を classID 1001 で切り替え — modified 分岐:

```zig
        if (bd) |b| {
            try collectGuids(&guids, b.body);
            if (ad.class_id == 1001) {
                const overrides = try diffOverrides(arena, b, ad);
                try docs.append(arena, .{
                    .file_id = ad.file_id,
                    .class_id = ad.class_id,
                    .type_name = try resolvedTypeName(ad),
                    .script_guid = scriptGuid(ad),
                    .status = if (overrides.len == 0) .unchanged else .modified,
                    .fields = &[_]FieldDiff{},
                    .overrides = overrides,
                });
            } else {
                ...既存(Task 3/4 の形)...
            }
        } else {
            if (ad.class_id == 1001) {
                try docs.append(arena, .{
                    .file_id = ad.file_id,
                    .class_id = ad.class_id,
                    .type_name = try resolvedTypeName(ad),
                    .script_guid = scriptGuid(ad),
                    .status = .added,
                    .fields = &[_]FieldDiff{},
                    .overrides = try addedInstanceOverrides(arena, ad),
                });
            } else {
                ...既存(Task 4 の flatten 形)...
            }
        }
```

removed 1001 は既存の removed 分岐のまま(overrides 空・中身列挙なし)。

- [ ] **Step 4: テストが通ることを確認**

Run: `zig build test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add core/src/diff.zig
git commit -m "feat: diff prefab instance overrides by target+path"
```

---

### Task 6: tree.zig — PrefabInstance の階層ノード化と stripped 橋渡し

**Files:**
- Modify: `core/src/tree.zig`

**Interfaces:**
- Consumes: Task 5 の `DocDiff.overrides`、`model.Document.stripped`、Task 2 の `ObjectDiff.kind/source_guid/overrides`
- Produces:
  - `build()` が classID 1001 を `kind = .prefab_instance` の ObjectDiff として `roots`/`children` に配置(loose に落とさない)
  - 親解決: `m_Modification.m_TransformParent` → Transform の GameObject。stripped Transform なら `m_PrefabInstance` を辿って親インスタンスへ
  - `ObjectDiff.name` = `m_Name` override(after 優先)、無ければ `""`(レンダラーが解決)
  - Transform の `m_Children` / GameObject の `m_Component` の生 diff は Task 3 の非表示テーブルで既に落ちている(ここでは何もしない)

- [ ] **Step 1: 失敗するテストを書く**

`core/src/tree.zig` のテスト群に追加:

```zig
test "tree: prefab instance nests under parent GameObject with name from m_Name override" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: Plane
        \\  m_Component:
        \\  - component: {fileID: 4}
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_Father: {fileID: 0}
    ;
    const after =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: Plane
        \\  m_Component:
        \\  - component: {fileID: 4}
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_Father: {fileID: 0}
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_TransformParent: {fileID: 4}
        \\    m_Modifications:
        \\    - target: {fileID: 8, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: Cylinder Variant
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalScale.y
        \\      value: 2
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
        \\--- !u!4 &42 stripped
        \\Transform:
        \\  m_CorrespondingSourceObject: {fileID: 7, guid: aaa, type: 3}
        \\  m_PrefabInstance: {fileID: 1001}
        \\  m_PrefabAsset: {fileID: 0}
    ;
    const res = try root.diffBytes(arena, before, after);
    try testing.expectEqual(@as(usize, 1), res.roots.len);
    try testing.expectEqual(@as(usize, 0), res.loose.len);
    const plane = res.roots[0];
    try testing.expectEqual(@as(usize, 1), plane.children.len);
    const inst = plane.children[0];
    try testing.expectEqual(model.ObjectKind.prefab_instance, inst.kind);
    try testing.expectEqualStrings("Cylinder Variant", inst.name);
    try testing.expectEqualStrings("aaa", inst.source_guid.?);
    try testing.expectEqual(model.Status.added, inst.status);
    try testing.expect(inst.overrides.len != 0);
    // stripped Transform はどこにも現れない。
    try testing.expectEqual(@as(usize, 0), inst.components.len);
}

test "tree: prefab instance with root transform parent becomes a root" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const after =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_TransformParent: {fileID: 0}
        \\    m_Modifications:
        \\    - target: {fileID: 8, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: Cylinder Variant
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    const res = try root.diffBytes(arena, "", after);
    try testing.expectEqual(@as(usize, 1), res.roots.len);
    try testing.expectEqual(model.ObjectKind.prefab_instance, res.roots[0].kind);
    try testing.expectEqualStrings("Cylinder Variant", res.roots[0].name);
}

test "tree: nested prefab instance bridges through stripped transform to parent instance" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const after =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_TransformParent: {fileID: 0}
        \\    m_Modifications:
        \\    - target: {fileID: 8, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: Outer
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
        \\--- !u!4 &42 stripped
        \\Transform:
        \\  m_PrefabInstance: {fileID: 1001}
        \\--- !u!1001 &2002
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_TransformParent: {fileID: 42}
        \\    m_Modifications:
        \\    - target: {fileID: 9, guid: bbb, type: 3}
        \\      propertyPath: m_Name
        \\      value: Inner
        \\  m_SourcePrefab: {fileID: 100100000, guid: bbb, type: 3}
    ;
    const res = try root.diffBytes(arena, "", after);
    try testing.expectEqual(@as(usize, 1), res.roots.len);
    try testing.expectEqualStrings("Outer", res.roots[0].name);
    try testing.expectEqual(@as(usize, 1), res.roots[0].children.len);
    try testing.expectEqualStrings("Inner", res.roots[0].children[0].name);
}
```

既存テスト "tree: ScriptableObject .asset becomes a loose component" のコメント(`or PrefabInstance`)を実態に合わせて後で更新。

- [ ] **Step 2: テストが失敗することを確認**

Run: `zig build test 2>&1 | head -30`
Expected: 新テスト 3 本 FAIL(PrefabInstance が loose に落ちる)

- [ ] **Step 3: 実装**

ヘルパー追加(`parentGoId` 周辺):

```zig
fn isTransformClass(id: u32) bool {
    return id == 4 or id == 224;
}

fn sourcePrefabGuid(doc: *const model.Document) ?[]const u8 {
    const s = model.findValue(doc.body.map, "m_SourcePrefab") orelse return null;
    return switch (s.*) {
        .ref => |r| r.guid,
        else => null,
    };
}

/// m_Name override をインスタンス名として拾う(after 優先の structural doc から)。
fn instanceName(idx: *Index, pi_id: i64) []const u8 {
    const doc = idx.structuralDoc(pi_id) orelse return "";
    const m = model.findValue(doc.body.map, "m_Modification") orelse return "";
    if (m.* != .map) return "";
    const list = model.findValue(m.map, "m_Modifications") orelse return "";
    if (list.* != .seq) return "";
    for (list.seq) |item| {
        if (item.* != .map) continue;
        const pp = model.findValue(item.map, "propertyPath") orelse continue;
        if (pp.* != .scalar or !std.mem.eql(u8, pp.scalar, "m_Name")) continue;
        const v = model.findValue(item.map, "value") orelse continue;
        return switch (v.*) {
            .scalar => |s| s,
            else => "",
        };
    }
    return "";
}

/// Transform の file_id から親ノード(GameObject または PrefabInstance)の id。
/// stripped Transform は m_PrefabInstance を辿って所属インスタンスに橋渡し。
fn ownerNodeIdOfTransform(idx: *Index, tr_id: i64) ?i64 {
    if (tr_id == 0) return null;
    const tr = idx.structuralDoc(tr_id) orelse return null;
    if (!isTransformClass(tr.class_id)) return null;
    if (tr.stripped) return refFileId(model.findValue(tr.body.map, "m_PrefabInstance"));
    return gameObjectIdOfComponent(tr);
}

fn instanceParentId(idx: *Index, pi_id: i64) ?i64 {
    const doc = idx.structuralDoc(pi_id) orelse return null;
    const m = model.findValue(doc.body.map, "m_Modification") orelse return null;
    if (m.* != .map) return null;
    const tp = refFileId(model.findValue(m.map, "m_TransformParent")) orelse return null;
    return ownerNodeIdOfTransform(idx, tp);
}
```

`parentGoId` の末尾 2 行を `ownerNodeIdOfTransform` 経由に置換:

```zig
fn parentGoId(idx: *Index, go_id: i64) ?i64 {
    const tr = transformOf(idx, go_id) orelse return null;
    const father_id = refFileId(model.findValue(tr.body.map, "m_Father")) orelse return null;
    return ownerNodeIdOfTransform(idx, father_id);
}
```

`build()` の変更点:

1. パーティションループに 1001 分岐を追加(GameObject 分岐の直後):

```zig
    var pi_ids: std.ArrayList(i64) = .empty;
    ...
    for (fd.docs) |d| {
        if (d.class_id == 1) { ...既存... }
        if (d.class_id == 1001) {
            try pi_ids.append(arena, d.file_id);
            continue;
        }
        ...既存の component/loose 分岐(loose のコメントから "or PrefabInstance" を削除)...
    }
```

2. ObjectDiff 構築ループの後に、インスタンス用構築を追加:

```zig
    for (pi_ids.items) |pi_id| {
        const dd = idx.diff_by_id.get(pi_id).?;
        const doc = idx.structuralDoc(pi_id);
        try obj_by_id.put(pi_id, .{
            .kind = .prefab_instance,
            .file_id = pi_id,
            .name = instanceName(&idx, pi_id),
            .source_guid = if (doc) |dc| sourcePrefabGuid(dc) else null,
            .status = dd.status,
            .overrides = dd.overrides,
            .components = &[_]ComponentDiff{},
            .children = &[_]ObjectDiff{},
        });
    }
```

3. 親子リンクのループにインスタンス分を追加(GameObject リンクの後):

```zig
    for (pi_ids.items) |pi_id| {
        if (instanceParentId(&idx, pi_id)) |pid| {
            if (obj_by_id.contains(pid)) {
                const e = try children_of.getOrPut(pid);
                if (!e.found_existing) e.value_ptr.* = .empty;
                try e.value_ptr.append(arena, pi_id);
                continue;
            }
        }
        try roots_ids.append(arena, pi_id);
    }
```

4. `materialize()` の has_change に overrides を追加:

```zig
    const has_change = self.status != .unchanged or self.components.len != 0 or
        self.children.len != 0 or self.overrides.len != 0;
```

5. `makeComponent()` に class_name を通す:

```zig
fn makeComponent(dd: diffmod.DocDiff) ComponentDiff {
    return .{
        .file_id = dd.file_id,
        .class_id = dd.class_id,
        .type_name = dd.type_name,
        .script_guid = dd.script_guid,
        .class_name = dd.class_name,
        .status = dd.status,
        .fields = dd.fields,
    };
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `zig build test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add core/src/tree.zig
git commit -m "feat: place prefab instances in the hierarchy tree"
```

---

### Task 7: json.zig — prefablens.diff.v2 出力

**Files:**
- Modify: `core/src/json.zig`
- Modify: `cli/src/main.zig:120`(schema ゴールデン)

**Interfaces:**
- Consumes: Task 2/5/6 のモデル
- Produces(extension / CLI が読む JSON):
  - `"schema":"prefablens.diff.v2"`
  - gameObject ノード: `{"kind":"gameObject","fileId","name","status","components":[],"children":[]}`(v1 と同形)
  - prefabInstance ノード: `{"kind":"prefabInstance","fileId","name","status","sourceGuid":string|null,"overrides":[{"group","label","status","before","after"}],"components":[],"children":[]}`
  - component: `"scriptGuid"` の直後に `"className":string|null`

- [ ] **Step 1: 失敗するテストを書く**

`core/src/json.zig` に追加:

```zig
test "json: v2 prefab instance node with overrides" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const after =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_TransformParent: {fileID: 0}
        \\    m_Modifications:
        \\    - target: {fileID: 8, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: Cylinder Variant
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalScale.y
        \\      value: 2
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    const out = try root.diffToJson(arena, "", after);
    try testing.expect(std.mem.indexOf(u8, out, "\"schema\":\"prefablens.diff.v2\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"prefabInstance\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"name\":\"Cylinder Variant\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"sourceGuid\":\"aaa\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"overrides\":[{\"group\":\"Transform\",\"label\":\"Scale.y\",\"status\":\"added\",\"before\":null,\"after\":\"2\"}]") != null);
}

test "json: component carries className" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_EditorClassIdentifier: Assembly-CSharp::Cylinder1
        \\  hp: 1
    ;
    const after =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_EditorClassIdentifier: Assembly-CSharp::Cylinder1
        \\  hp: 2
    ;
    const out = try root.diffToJson(arena, before, after);
    try testing.expect(std.mem.indexOf(u8, out, "\"className\":\"Cylinder1\"") != null);
}
```

既存ゴールデンを v2 へ更新:
- "json: modified loose component matches golden" の golden 文字列: `prefablens.diff.v1` → `prefablens.diff.v2`、`"scriptGuid":"def"` の直後に `,"className":null` を挿入、`"path":"volume"` → `"path":"Volume"`
- `cli/src/main.zig:120` の `"schema":"prefablens.diff.v1"` → `"schema":"prefablens.diff.v2"`

- [ ] **Step 2: テストが失敗することを確認**

Run: `zig build test 2>&1 | head -30`
Expected: 新テスト FAIL + 旧 golden FAIL

- [ ] **Step 3: 実装**

`serialize()` の schema 文字列を `prefablens.diff.v2` に。`writeObject` を kind 対応に:

```zig
fn writeObject(w: *std.Io.Writer, o: model.ObjectDiff, resolved: ?*const Resolver) !void {
    const kind = switch (o.kind) {
        .game_object => "gameObject",
        .prefab_instance => "prefabInstance",
    };
    try w.print("{{\"kind\":\"{s}\",\"fileId\":", .{kind});
    try writeI64String(w, o.file_id);
    try w.writeAll(",\"name\":");
    try writeJsonString(w, o.name);
    try w.writeAll(",\"status\":");
    try writeStatus(w, o.status);
    if (o.kind == .prefab_instance) {
        try w.writeAll(",\"sourceGuid\":");
        if (o.source_guid) |g| try writeJsonString(w, g) else try w.writeAll("null");
        try w.writeAll(",\"overrides\":[");
        for (o.overrides, 0..) |ov, i| {
            if (i != 0) try w.writeByte(',');
            try writeOverride(w, ov);
        }
        try w.writeByte(']');
    }
    try w.writeAll(",\"components\":[");
    ...既存...
}

fn writeOverride(w: anytype, ov: model.OverrideDiff) !void {
    try w.writeAll("{\"group\":");
    try writeJsonString(w, ov.group);
    try w.writeAll(",\"label\":");
    try writeJsonString(w, ov.label);
    try w.writeAll(",\"status\":");
    try writeStatus(w, ov.status);
    try w.writeAll(",\"before\":");
    try writeValue(w, ov.before);
    try w.writeAll(",\"after\":");
    try writeValue(w, ov.after);
    try w.writeByte('}');
}
```

`writeComponent` の scriptGuid 出力の直後に:

```zig
    try w.writeAll(",\"className\":");
    if (c.class_name) |n| try writeJsonString(w, n) else try w.writeAll("null");
```

- [ ] **Step 4: テストが通ることを確認**

Run: `zig build test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add core/src/json.zig cli/src/main.zig
git commit -m "feat: emit prefablens.diff.v2 with instance nodes"
```

---

### Task 8: core 統合テスト — 検証 PR の実データ fixture

**Files:**
- Create: `core/src/testdata/plane_before.prefab`, `plane_after.prefab`, `cylinder_before.prefab`, `cylinder_after.prefab`, `cylinder_variant_after.prefab`
- Create: `core/src/fixture_test.zig`
- Modify: `core/src/root.zig`(テスト参照追加)

**Interfaces:**
- Consumes: `root.diffBytes`(全タスクの統合)
- Produces: 承認済みモック(spec §表示イメージ)と同じ構造の保証

- [ ] **Step 1: fixture を取得**

```bash
mkdir -p core/src/testdata
gh api "repos/hashiiiii/unity-yaml-playground/contents/Assets/Plane.prefab" -X GET -f ref=main --jq .content | base64 -d > core/src/testdata/plane_before.prefab
gh api "repos/hashiiiii/unity-yaml-playground/contents/Assets/Plane.prefab" -X GET -f ref=feature/test-prefab-lens --jq .content | base64 -d > core/src/testdata/plane_after.prefab
gh api "repos/hashiiiii/unity-yaml-playground/contents/Assets/Cylinder.prefab" -X GET -f ref=main --jq .content | base64 -d > core/src/testdata/cylinder_before.prefab
gh api "repos/hashiiiii/unity-yaml-playground/contents/Assets/Cylinder.prefab" -X GET -f ref=feature/test-prefab-lens --jq .content | base64 -d > core/src/testdata/cylinder_after.prefab
gh api "repos/hashiiiii/unity-yaml-playground/contents/Assets/Cylinder%20Variant.prefab" -X GET -f ref=feature/test-prefab-lens --jq .content | base64 -d > core/src/testdata/cylinder_variant_after.prefab
head -5 core/src/testdata/plane_before.prefab
```

Expected: `%YAML 1.1` から始まる Unity YAML が 5 ファイルとも取れている

- [ ] **Step 2: 失敗するテストを書く**

`core/src/fixture_test.zig`:

```zig
//! 検証 PR (hashiiiii/unity-yaml-playground#1) の実データに対する統合テスト。
//! 期待値は spec の承認済みモック(docs/superpowers/specs/2026-07-03-semantic-diff-inspector-model-design.md)。
const std = @import("std");
const root = @import("root.zig");
const model = @import("model.zig");
const testing = std.testing;

const plane_before = @embedFile("testdata/plane_before.prefab");
const plane_after = @embedFile("testdata/plane_after.prefab");
const cylinder_before = @embedFile("testdata/cylinder_before.prefab");
const cylinder_after = @embedFile("testdata/cylinder_after.prefab");
const cylinder_variant_after = @embedFile("testdata/cylinder_variant_after.prefab");

fn childByName(o: model.ObjectDiff, name: []const u8) ?model.ObjectDiff {
    for (o.children) |c| if (std.mem.eql(u8, c.name, name)) return c;
    return null;
}

test "fixture: Plane.prefab shows both cylinder instances under Plane" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try root.diffBytes(arena, plane_before, plane_after);

    // stripped Transform や PrefabInstance が loose に漏れない。
    try testing.expectEqual(@as(usize, 0), res.loose.len);
    try testing.expectEqual(@as(usize, 1), res.roots.len);
    const plane = res.roots[0];
    try testing.expectEqualStrings("Plane", plane.name);

    // 追加された Cylinder Variant: 配置サマリのみ(Position 合成 1 行)。
    const variant = childByName(plane, "Cylinder Variant").?;
    try testing.expectEqual(model.ObjectKind.prefab_instance, variant.kind);
    try testing.expectEqual(model.Status.added, variant.status);
    try testing.expectEqual(@as(usize, 1), variant.overrides.len);
    try testing.expectEqualStrings("Transform", variant.overrides[0].group);
    try testing.expectEqualStrings("Position", variant.overrides[0].label);
    try testing.expectEqualStrings("(2.03, 3.63, 1.11797)", variant.overrides[0].after.?.scalar);

    // 変更された Cylinder: Position.x の 1 override のみ。
    const cylinder = childByName(plane, "Cylinder").?;
    try testing.expectEqual(model.ObjectKind.prefab_instance, cylinder.kind);
    try testing.expectEqual(model.Status.modified, cylinder.status);
    try testing.expectEqual(@as(usize, 1), cylinder.overrides.len);
    try testing.expectEqualStrings("Transform", cylinder.overrides[0].group);
    try testing.expectEqualStrings("Position.x", cylinder.overrides[0].label);
    try testing.expectEqualStrings("0.41646004", cylinder.overrides[0].before.?.scalar);
    try testing.expectEqualStrings("1", cylinder.overrides[0].after.?.scalar);
}

test "fixture: Cylinder.prefab shows added script and transform change" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try root.diffBytes(arena, cylinder_before, cylinder_after);
    try testing.expectEqual(@as(usize, 1), res.roots.len);
    const go = res.roots[0];
    try testing.expectEqualStrings("Cylinder", go.name);

    var saw_script = false;
    var saw_transform = false;
    for (go.components) |c| {
        if (c.class_id == 114) {
            saw_script = true;
            try testing.expectEqual(model.Status.added, c.status);
            try testing.expectEqualStrings("Cylinder1", c.class_name.?);
            // 追加コンポーネントは初期値を全列挙している(空ではない)。
            try testing.expect(c.fields.len != 0);
        }
        if (c.class_id == 4) {
            saw_transform = true;
            try testing.expectEqual(@as(usize, 1), c.fields.len);
            try testing.expectEqualStrings("Position.x", c.fields[0].path);
            try testing.expectEqualStrings("0.64596", c.fields[0].before.?.scalar);
            try testing.expectEqualStrings("1", c.fields[0].after.?.scalar);
        }
    }
    try testing.expect(saw_script and saw_transform);
}

test "fixture: new Cylinder Variant.prefab is a single added instance with Scale.y" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try root.diffBytes(arena, "", cylinder_variant_after);
    try testing.expectEqual(@as(usize, 1), res.roots.len);
    const inst = res.roots[0];
    try testing.expectEqual(model.ObjectKind.prefab_instance, inst.kind);
    try testing.expectEqualStrings("Cylinder Variant", inst.name);
    try testing.expectEqual(model.Status.added, inst.status);
    // Position (0,0,0)・identity Rotation・EulerAnglesHint・m_Name は省略され Scale.y だけ残る。
    try testing.expectEqual(@as(usize, 1), inst.overrides.len);
    try testing.expectEqualStrings("Scale.y", inst.overrides[0].label);
    try testing.expectEqualStrings("2", inst.overrides[0].after.?.scalar);
}
```

`core/src/root.zig` の `test { refAllDecls }` ブロックに追加:

```zig
test {
    std.testing.refAllDecls(@This());
    _ = @import("fixture_test.zig");
}
```

- [ ] **Step 3: テストを実行**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS(Task 1〜7 が正しければ通る。落ちたら該当タスクの実装のバグ — 期待値ではなく実装を直す)

- [ ] **Step 4: Commit**

```bash
git add core/src/testdata core/src/fixture_test.zig core/src/root.zig
git commit -m "test: add real-PR fixture integration tests"
```

---

### Task 9: CLI レンダラー追従(render_tree / render_html)

**Files:**
- Modify: `cli/src/render_tree.zig`
- Modify: `cli/src/render_html.zig`

**Interfaces:**
- Consumes: Task 6/7 のモデル(`ObjectDiff.kind/source_guid/overrides`、`ComponentDiff.class_name`)
- Produces: テキスト/HTML 出力の表示次元規則(オブジェクト → `components` ラベル行 → コンポーネント/override グループ → プロパティ)。CLI は折りたたみが無いので全展開

- [ ] **Step 1: 失敗するテストを書く**

`cli/src/render_tree.zig` に追加:

```zig
test "render: prefab instance shows name, components label and grouped overrides" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const after =
        \\--- !u!1001 &1001
        \\PrefabInstance:
        \\  m_Modification:
        \\    m_TransformParent: {fileID: 0}
        \\    m_Modifications:
        \\    - target: {fileID: 8, guid: aaa, type: 3}
        \\      propertyPath: m_Name
        \\      value: Cylinder Variant
        \\    - target: {fileID: 7, guid: aaa, type: 3}
        \\      propertyPath: m_LocalScale.y
        \\      value: 2
        \\  m_SourcePrefab: {fileID: 100100000, guid: aaa, type: 3}
    ;
    const res = try core.diffBytes(arena, "", after);
    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    try render(arena, &aw.writer, res, null, false);
    const text = aw.toArrayList().items;
    try testing.expect(std.mem.indexOf(u8, text, "+ Cylinder Variant  <Prefab>") != null);
    try testing.expect(std.mem.indexOf(u8, text, "components") != null);
    try testing.expect(std.mem.indexOf(u8, text, "+ Transform") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Scale.y: 2") != null);
}

test "render: components label separates object and component dimensions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: Player
        \\  m_Component:
        \\  - component: {fileID: 5}
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_GameObject: {fileID: 1}
        \\  hp: 100
    ;
    const after =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: Player
        \\  m_Component:
        \\  - component: {fileID: 5}
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_GameObject: {fileID: 1}
        \\  hp: 250
    ;
    const res = try core.diffBytes(arena, before, after);
    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    try render(arena, &aw.writer, res, null, false);
    const text = aw.toArrayList().items;
    // "  Player" → "    components" → "      ~ MonoBehaviour" の深度になる。
    try testing.expect(std.mem.indexOf(u8, text, "\n    components\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\n      ~ MonoBehaviour\n") != null);
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `zig build test 2>&1 | head -20`
Expected: FAIL(components ラベルが無い、instance 名が空)

- [ ] **Step 3: render_tree.zig 実装**

`renderObject` / `renderComponent` を差し替え、override 描画を追加:

```zig
fn displayObjectName(o: model.ObjectDiff, resolved: ?*const core.json.Resolver) []const u8 {
    if (o.name.len != 0) return o.name;
    if (o.kind == .prefab_instance) {
        if (o.source_guid) |g| if (resolved) |r| if (r.get(g)) |p| {
            return std.fs.path.stem(p);
        };
        return "Prefab Instance";
    }
    return "(GameObject)";
}

fn renderObject(
    arena: std.mem.Allocator,
    w: anytype,
    o: model.ObjectDiff,
    resolved: ?*const core.json.Resolver,
    color: bool,
    depth: usize,
) !void {
    try indent(w, depth);
    try paint(w, color, statusColor(o.status), statusSign(o.status));
    try w.print(" {s}", .{displayObjectName(o, resolved)});
    if (o.kind == .prefab_instance) try w.writeAll("  <Prefab>");
    try w.writeByte('\n');
    // 表示次元の規則: コンポーネント/override は必ず components セクション配下。
    if (o.overrides.len != 0 or o.components.len != 0) {
        try indent(w, depth + 1);
        try paint(w, color, Color.dim, "components");
        try w.writeByte('\n');
        try renderOverrides(w, o.overrides, color, depth + 2);
        for (o.components) |c| try renderComponent(arena, w, c, resolved, color, depth + 2);
    }
    for (o.children) |child| try renderObject(arena, w, child, resolved, color, depth + 1);
}

fn renderOverrides(w: anytype, overrides: []const model.OverrideDiff, color: bool, depth: usize) !void {
    var current: []const u8 = "";
    for (overrides) |ov| {
        if (!std.mem.eql(u8, current, ov.group)) {
            current = ov.group;
            try indent(w, depth);
            try paint(w, color, statusColor(ov.status), statusSign(ov.status));
            try w.print(" {s}\n", .{ov.group});
        }
        try indent(w, depth + 1);
        try paint(w, color, statusColor(ov.status), statusSign(ov.status));
        try w.print(" {s}: ", .{ov.label});
        switch (ov.status) {
            .modified => {
                try writeValueText(w, ov.before);
                try w.writeAll(" -> ");
                try writeValueText(w, ov.after);
            },
            .added => try writeValueText(w, ov.after),
            .removed => try writeValueText(w, ov.before),
            .unchanged => {},
        }
        try w.writeByte('\n');
    }
}
```

`renderComponent` の表示名解決を stem + class_name フォールバックに:

```zig
    var display = c.type_name;
    if (c.class_name) |n| display = n;
    if (c.script_guid) |g| if (resolved) |r| if (r.get(g)) |p| {
        display = std.fs.path.stem(p);
    };
```

注意: `renderComponent` は loose(depth 0)からも呼ばれる。loose はオブジェクト行を持たないので components ラベルは付けない(呼び出し側 `render()` は変更なし)。

- [ ] **Step 4: render_html.zig を同じ構造に**

`renderObject` に同じ変更(components ラベル行 + `<Prefab>` バッジ + override グループ)。HTML はラベルを `<span class="unchanged">components</span>` で出す:

```zig
fn renderObject(arena: std.mem.Allocator, w: anytype, o: model.ObjectDiff, resolved: ?*const core.json.Resolver, depth: usize) !void {
    try pad(w, depth);
    try w.print("<span class=\"{s} go\">{s} ", .{ cls(o.status), sign(o.status) });
    try writeEscaped(w, displayObjectName(o, resolved));
    if (o.kind == .prefab_instance) try w.writeAll(" &lt;Prefab&gt;");
    try w.writeAll("</span>\n");
    if (o.overrides.len != 0 or o.components.len != 0) {
        try pad(w, depth + 1);
        try w.writeAll("<span class=\"unchanged\">components</span>\n");
        try renderOverrides(w, o.overrides, depth + 2);
        for (o.components) |c| try renderComponent(arena, w, c, resolved, depth + 2);
    }
    for (o.children) |child| try renderObject(arena, w, child, resolved, depth + 1);
}

fn renderOverrides(w: anytype, overrides: []const model.OverrideDiff, depth: usize) !void {
    var current: []const u8 = "";
    for (overrides) |ov| {
        if (!std.mem.eql(u8, current, ov.group)) {
            current = ov.group;
            try pad(w, depth);
            try w.print("<span class=\"{s}\">{s} ", .{ cls(ov.status), sign(ov.status) });
            try writeEscaped(w, ov.group);
            try w.writeAll("</span>\n");
        }
        try renderField(w, .{ .path = ov.label, .status = ov.status, .before = ov.before, .after = ov.after }, depth + 1);
    }
}
```

`displayObjectName` は render_tree.zig と同じものを render_html.zig にも定義(2 ファイルは独立モジュール)。`renderComponent` の表示名も同様に stem + class_name 化。head の `<h1>` を `prefablens.diff.v2` に更新。

既存 HTML テストへの影響:
- "html: nested child GameObject renders indented one level under its parent": 子オブジェクトの深度はオブジェクト次元のまま(depth+1)なので、表明 `"  <span class=\"modified go\">~ ChildRenamed</span>"` はそのまま通る(Child にはコンポーネントカードが無く components 行も出ない)。
- なお GameObject 自身の field diff(m_Name 変更など)は現行 tree.zig が ObjectDiff に持ち込まない(status のみ反映、名前は行頭に出る)。この挙動は変更しない — 追加作業なし。

- [ ] **Step 5: テストが通ることを確認**

Run: `zig build test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add cli/src/render_tree.zig cli/src/render_html.zig
git commit -m "feat: render components section and instances in CLI"
```

---

### Task 10: extension 追従 — types / differ / render の v2 対応

**Files:**
- Modify: `extension/src/types.ts`
- Modify: `extension/src/wasm/differ.ts:32`
- Modify: `extension/src/renderer/render.ts`
- Modify: `extension/src/renderer/render.test.ts`
- Modify: `extension/src/background/handler.test.ts:9`、`extension/src/github/guids.test.ts:80`、`extension/src/wasm/differ.test.ts`、`extension/e2e/smoke.spec.ts:10`(schema 文字列と fixture 形の機械的更新)

**Interfaces:**
- Consumes: Task 7 の v2 JSON
- Produces:
  - `types.ts`: `DiffV2` / `NodeDiff = GameObjectDiff | PrefabInstanceDiff` / `OverrideDiff` / `ComponentDiff.className`
  - `render.ts`: components セクション、‹Prefab› バッジ、名前フォールバック、開閉デフォルト(added コンポーネント = 閉、modified = 開、override グループ = 開)

- [ ] **Step 1: types.ts を v2 に更新**

```ts
// prefablens.diff.v2 (core/src/json.zig の出力と 1:1)
export type Status = 'added' | 'removed' | 'modified' | 'unchanged';

export type RefValue = { ref: { fileId: string; guid: string | null; type: number | null } };
export type FieldValue = string | RefValue | null;

export type FieldDiff = { path: string; status: Status; before: FieldValue; after: FieldValue };

export type OverrideDiff = {
  group: string; // "Transform" | "GameObject" | "Overrides"
  label: string; // humanize 済み ("Position.x")
  status: Status;
  before: FieldValue;
  after: FieldValue;
};

export type ComponentDiff = {
  kind: 'component';
  fileId: string;
  classId: number;
  typeName: string;
  scriptGuid: string | null;
  className: string | null;
  status: Status;
  fields: FieldDiff[];
};

export type GameObjectDiff = {
  kind: 'gameObject';
  fileId: string;
  name: string;
  status: Status;
  components: ComponentDiff[];
  children: NodeDiff[];
};

export type PrefabInstanceDiff = {
  kind: 'prefabInstance';
  fileId: string;
  name: string;
  status: Status;
  sourceGuid: string | null;
  overrides: OverrideDiff[];
  components: ComponentDiff[];
  children: NodeDiff[];
};

export type NodeDiff = GameObjectDiff | PrefabInstanceDiff;

export type DiffV2 = {
  schema: 'prefablens.diff.v2';
  unresolvedGuids: string[];
  resolved?: Record<string, string>; // ホスト側(applyResolved)が付与
  roots: NodeDiff[];
  loose: ComponentDiff[];
};

export type DiffErrorV1 = { schema: 'prefablens.error.v1'; error: string };
```

`DiffV1` の名前を使う箇所(`differ.ts`, `render.ts`, `github/guids.ts`, `background/handler.ts`, 各テスト)を `DiffV2` に一括置換:

```bash
grep -rln "DiffV1" extension/src extension/e2e | xargs sed -i '' 's/DiffV1/DiffV2/g'
grep -rln "prefablens.diff.v1" extension/src extension/e2e | xargs sed -i '' 's/prefablens.diff.v1/prefablens.diff.v2/g'
```

- [ ] **Step 2: 失敗するテストを書く(render.test.ts)**

`extension/src/renderer/render.test.ts` の fixture を v2 形に直した上で、新テストを追加:

```ts
const INSTANCE: DiffV2 = {
  schema: 'prefablens.diff.v2',
  unresolvedGuids: ['aaa'],
  resolved: { aaa: 'Assets/Cylinder Variant.prefab' },
  roots: [
    {
      kind: 'gameObject',
      fileId: '1',
      name: 'Plane',
      status: 'unchanged',
      components: [],
      children: [
        {
          kind: 'prefabInstance',
          fileId: '1001',
          name: 'Cylinder Variant',
          status: 'added',
          sourceGuid: 'aaa',
          overrides: [
            { group: 'Transform', label: 'Position', status: 'added', before: null, after: '(2.03, 3.63, 1.12)' },
          ],
          components: [],
          children: [],
        },
      ],
    },
  ],
  loose: [],
};

it('renders prefab instance with badge, components section and open override card', () => {
  const root = host();
  render(root, INSTANCE);
  const text = root.textContent ?? '';
  expect(text).toContain('Cylinder Variant');
  expect(text).toContain('‹Prefab: Assets/Cylinder Variant.prefab›');
  expect(text).toContain('components');
  expect(text).toContain('Transform');
  expect(text).toContain('Position');
  // override カードは開いている。
  const card = root.querySelector('.pl-components details') as HTMLDetailsElement;
  expect(card.open).toBe(true);
});

it('collapses added component cards but keeps modified ones open', () => {
  const root = host();
  const diff: DiffV2 = {
    schema: 'prefablens.diff.v2',
    unresolvedGuids: [],
    roots: [
      {
        kind: 'gameObject',
        fileId: '1',
        name: 'Cylinder',
        status: 'modified',
        components: [
          {
            kind: 'component', fileId: '8', classId: 114, typeName: 'MonoBehaviour',
            scriptGuid: null, className: 'Cylinder1', status: 'added',
            fields: [{ path: 'Enabled', status: 'added', before: null, after: '1' }],
          },
          {
            kind: 'component', fileId: '4', classId: 4, typeName: 'Transform',
            scriptGuid: null, className: null, status: 'modified',
            fields: [{ path: 'Position.x', status: 'modified', before: '0.64596', after: '1' }],
          },
        ],
        children: [],
      },
    ],
    loose: [],
  };
  render(root, diff);
  const cards = [...root.querySelectorAll('.pl-components > details')] as HTMLDetailsElement[];
  expect(cards).toHaveLength(2);
  expect(cards[0].open).toBe(false); // added Cylinder1 は閉
  expect(cards[0].textContent).toContain('Cylinder1'); // className フォールバック
  expect(cards[1].open).toBe(true); // modified Transform は開
});

it('falls back instance name to resolved source prefab stem', () => {
  const root = host();
  const diff: DiffV2 = {
    schema: 'prefablens.diff.v2',
    unresolvedGuids: ['bbb'],
    resolved: { bbb: 'Assets/Enemy.prefab' },
    roots: [
      {
        kind: 'prefabInstance', fileId: '1001', name: '', status: 'added',
        sourceGuid: 'bbb', overrides: [], components: [], children: [],
      },
    ],
    loose: [],
  };
  render(root, diff);
  expect(root.textContent).toContain('Enemy');
});
```

(`host()` は既存テストの ShadowRoot 生成ヘルパーに合わせる — 無ければ既存テストの生成コードを使う。)

- [ ] **Step 3: テストが失敗することを確認**

Run: `cd extension && npm test 2>&1 | tail -20`
Expected: 新テスト FAIL(components セクション・バッジ未実装)。※ differ.test.ts は Task 11 の wasm 再ビルドまで FAIL のままで正常

- [ ] **Step 4: render.ts 実装**

`renderGameObject` を `renderNode` に置き換え:

```ts
import type { ComponentDiff, DiffV2, FieldValue, NodeDiff, OverrideDiff, Status } from '../types';

function stem(path: string): string {
  const base = path.split('/').pop() ?? path;
  const dot = base.lastIndexOf('.');
  return dot > 0 ? base.slice(0, dot) : base;
}

function nodeName(node: NodeDiff, diff: DiffV2): string {
  if (node.name) return node.name;
  if (node.kind === 'prefabInstance') {
    const p = node.sourceGuid ? diff.resolved?.[node.sourceGuid] : undefined;
    return p ? stem(p) : 'Prefab Instance';
  }
  return '(GameObject)';
}

function renderNode(node: NodeDiff, diff: DiffV2): HTMLElement {
  const details = openDetails(node.kind === 'prefabInstance' ? 'pl-pi' : 'pl-go', node.status);
  const summary = summaryLine(node.status, nodeName(node, diff));
  if (node.kind === 'prefabInstance') {
    const badge = document.createElement('span');
    badge.className = 'pl-script';
    const p = node.sourceGuid ? diff.resolved?.[node.sourceGuid] : undefined;
    badge.textContent = p ? `‹Prefab: ${p}›` : '‹Prefab›';
    summary.append(badge);
  }
  details.append(summary);

  // 表示次元の規則: コンポーネント/override カードは components セクション配下のみ。
  const cards: HTMLElement[] = [];
  if (node.kind === 'prefabInstance') cards.push(...renderOverrideGroups(node.overrides, diff));
  cards.push(...node.components.map((c) => renderComponent(c, diff)));
  if (cards.length) {
    const section = document.createElement('div');
    section.className = 'pl-components';
    const label = document.createElement('div');
    label.className = 'pl-components-label';
    label.textContent = 'components';
    section.append(label, ...cards);
    details.append(section);
  }
  for (const child of node.children) details.append(renderNode(child, diff));
  return details;
}

function renderOverrideGroups(overrides: OverrideDiff[], diff: DiffV2): HTMLElement[] {
  const cards: HTMLElement[] = [];
  let current: { name: string; el: HTMLDetailsElement } | null = null;
  for (const ov of overrides) {
    if (!current || current.name !== ov.group) {
      const el = openDetails('pl-comp', ov.status);
      el.open = true; // override カードは常に開(spec: 縮約サマリのみで軽い)
      el.append(summaryLine(ov.status, ov.group));
      cards.push(el);
      current = { name: ov.group, el };
    }
    current.el.append(fieldRow(ov.label, ov.status, ov.before, ov.after, diff));
  }
  return cards;
}
```

`renderComponent` の変更 — 表示名フォールバックと開閉、field 行の共通化:

```ts
function renderComponent(c: ComponentDiff, diff: DiffV2): HTMLElement {
  const details = openDetails('pl-comp', c.status);
  details.open = c.status !== 'added'; // added(初期値の全列挙)は閉、それ以外は開
  const resolved = c.scriptGuid ? diff.resolved?.[c.scriptGuid] : undefined;
  const display = resolved ? stem(resolved) : (c.className ?? c.typeName);
  const summary = summaryLine(c.status, display);
  if (c.scriptGuid) {
    const script = document.createElement('span');
    script.className = 'pl-script';
    script.textContent = '‹Script›';
    summary.append(script);
  }
  details.append(summary);
  for (const f of c.fields) details.append(fieldRow(f.path, f.status, f.before, f.after, diff));
  return details;
}

function fieldRow(label: string, status: Status, before: FieldValue, after: FieldValue, diff: DiffV2): HTMLElement {
  const row = document.createElement('div');
  row.className = `pl-field pl-${status}`;
  const path = document.createElement('span');
  path.className = 'pl-path';
  path.textContent = label;
  row.append(path);
  if (status === 'modified') {
    row.append(valueSpan('pl-before', before, diff));
    const arrow = document.createElement('span');
    arrow.className = 'pl-arrow';
    arrow.textContent = '→';
    row.append(arrow);
    row.append(valueSpan('pl-after', after, diff));
  } else if (status === 'added') {
    row.append(valueSpan('pl-after', after, diff));
  } else if (status === 'removed') {
    row.append(valueSpan('pl-before', before, diff));
  }
  return row;
}
```

`render()` 本体の roots ループを `renderNode` に差し替え。STYLES に追加:

```css
  .pl-components { border-left: 1px solid var(--pl-border); margin: 2px 0 2px 4px; padding-left: 8px; }
  .pl-components-label { color: var(--pl-muted); font-size: 10px; text-transform: uppercase; letter-spacing: 0.5px; user-select: none; }
```

- [ ] **Step 5: テストと型チェック**

Run: `cd extension && npm test -- --exclude '**/differ.test.ts' && npm run typecheck`
Expected: render/handler/guids/options/content 系 PASS、typecheck PASS(differ.test は wasm 再ビルド前なので除外)

- [ ] **Step 6: Commit**

```bash
git add extension/src extension/e2e
git commit -m "feat: render v2 instance nodes and components section"
```

---

### Task 11: WASM 再ビルドと全体検証

**Files:**
- 生成物: `zig-out/bin/prefablens.wasm`(コミット対象外)

- [ ] **Step 1: WASM を再ビルドして全テスト**

```bash
zig build test && zig build wasm
cd extension && npm test && npm run typecheck && npm run build && npm run size
```

Expected: すべて PASS。`npm run size` が gzip サイズ予算内(≤ 80 KB 目標 / 150 KB 上限)であること — テーブル追加は数 KB 程度のはず

- [ ] **Step 2: E2E スモーク**

```bash
cd extension && npm run e2e
```

Expected: PASS(smoke.spec.ts は Step 10 で v2 fixture に更新済み)

- [ ] **Step 3: fixture の実 PR で目視確認(可能なら)**

`zig build run`(CLI)で fixture を直接 diff し、spec のモックと見比べる:

```bash
zig build run -- diff core/src/testdata/plane_before.prefab core/src/testdata/plane_after.prefab
```

Expected(構造がモックと一致):

```
~ Plane
  + Cylinder Variant  <Prefab>
    components
      + Transform
        + Position: (2.03, 3.63, 1.11797)
  ~ Cylinder  <Prefab>
    components
      ~ Transform
        ~ Position.x: 0.41646004 -> 1
```

(CLI の引数形式が異なる場合は `cli/src/main.zig` の usage に従う。)

- [ ] **Step 4: Commit(残り物があれば)+ 完了処理**

```bash
git status --short
```

未コミットの変更が無いことを確認。その後 superpowers:verification-before-completion → superpowers:requesting-code-review → superpowers:finishing-a-development-branch の順で完了処理(PR 作成は `feat/inspector-model-diff` → `main`)。
