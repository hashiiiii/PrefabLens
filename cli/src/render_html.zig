const std = @import("std");
const core = @import("core");
const testing = std.testing;

// Renders `files` and returns the HTML for assertions.
fn renderToString(
    arena: std.mem.Allocator,
    files: []const FileDiff,
    resolved: ?*const core.json.Resolver,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var aw = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    try render(&aw.writer, files, resolved);
    return aw.toArrayList().items;
}

test "html: self-contained page with pl-root and escaped content" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: A<x>
        \\  m_Component:
        \\  - component: {fileID: 5}
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_GameObject: {fileID: 1}
        \\  hp: 1
    ;
    const after =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: A<x>
        \\  m_Component:
        \\  - component: {fileID: 5}
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_GameObject: {fileID: 1}
        \\  hp: 2
    ;
    const res = try core.diffBytes(arena, before, after);
    const html = try renderToString(arena, &.{.{ .path = null, .res = res }}, null);
    try testing.expect(std.mem.startsWith(u8, html, "<!DOCTYPE html>"));
    try testing.expect(std.mem.indexOf(u8, html, "<style>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "</html>") != null);
    // The stylesheet is embedded, not linked: no external requests ever.
    try testing.expect(std.mem.indexOf(u8, html, "pl-root") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<link") == null);
    try testing.expect(std.mem.indexOf(u8, html, "<script") == null);
    // HTML special chars escaped: "A<x>" -> "A&lt;x&gt;"
    try testing.expect(std.mem.indexOf(u8, html, "A&lt;x&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, html, "Hp") != null);
}

test "html: modified component renders an extension-shaped card" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  hp: 1
    ;
    const after =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  hp: 2
    ;
    const res = try core.diffBytes(arena, before, after);
    const html = try renderToString(arena, &.{.{ .path = null, .res = res }}, null);
    // Loose components sit in a components section, like the extension's
    // diff.loose rendering.
    try testing.expect(std.mem.indexOf(u8, html, "components (1)") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<details open class=\"pl-comp pl-modified\">") != null);
    // Badge chip carries the ~ marker; the row itself is a native summary.
    try testing.expect(std.mem.indexOf(u8, html, "<span class=\"pl-badge\">~</span>") != null);
    // Modified field: before -> arrow -> after, extension class names.
    try testing.expect(std.mem.indexOf(u8, html, "<span class=\"pl-path\">Hp</span>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<span class=\"pl-before\">1</span>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<span class=\"pl-arrow\">→</span>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<span class=\"pl-after\">2</span>") != null);
}

test "html: ref guid with markup is escaped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The parser enforces no hex-only constraint on guids: this parses
    // cleanly into Node.ref.guid and must not reach the HTML unescaped.
    const before =
        \\--- !u!114 &1
        \\MonoBehaviour:
        \\  m_Target: {fileID: 2, guid: <img src=x onerror=alert(1)>, type: 3}
    ;
    const after =
        \\--- !u!114 &1
        \\MonoBehaviour:
        \\  m_Target: {fileID: 3, guid: <img src=x onerror=alert(1)>, type: 3}
    ;
    const res = try core.diffBytes(arena, before, after);
    const html = try renderToString(arena, &.{.{ .path = null, .res = res }}, null);
    try testing.expect(std.mem.indexOf(u8, html, "<img") == null);
    try testing.expect(std.mem.indexOf(u8, html, "&lt;img") != null);
}

test "html: resolved script guid renders stem as name and full path as meta" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_Script: {fileID: 11500000, guid: abc123, type: 3}
        \\  hp: 1
    ;
    const after =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_Script: {fileID: 11500000, guid: abc123, type: 3}
        \\  hp: 2
    ;
    const res = try core.diffBytes(arena, before, after);
    var resolver = core.json.Resolver.init(arena);
    try resolver.put("abc123", "Assets/Scripts/PlayerController.cs");
    const html = try renderToString(arena, &.{.{ .path = null, .res = res }}, &resolver);
    // Same display rule as the extension: stem replaces the type name, the
    // full path rides in the pl-script meta span.
    try testing.expect(std.mem.indexOf(u8, html, "PlayerController<") != null);
    try testing.expect(std.mem.indexOf(u8, html, "‹Script: Assets/Scripts/PlayerController.cs›") != null);
    try testing.expect(std.mem.indexOf(u8, html, "MonoBehaviour") == null);
}

test "html: unity built-in ref values render object names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!33 &5
        \\MeshFilter:
        \\  m_Mesh: {fileID: 0}
    ;
    const after =
        \\--- !u!33 &5
        \\MeshFilter:
        \\  m_Mesh: {fileID: 10202, guid: 0000000000000000e000000000000000, type: 0}
    ;
    const res = try core.diffBytes(arena, before, after);
    // No resolver: built-in names come from the checked-in table, not .meta files.
    const html = try renderToString(arena, &.{.{ .path = null, .res = res }}, null);
    try testing.expect(std.mem.indexOf(u8, html, "Cube (built-in)") != null);
    try testing.expect(std.mem.indexOf(u8, html, "guid:0000000000000000e000000000000000") == null);
}

test "html: null reference reads as None, local refs as #fileID" {
    // Same decision-table cases as render_tree.zig ("null reference reads as
    // None") and the extension's render.test.ts.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!65 &5
        \\CapsuleCollider:
        \\  m_Material: {fileID: 0}
    ;
    const after =
        \\--- !u!65 &5
        \\CapsuleCollider:
        \\  m_Material: {fileID: 42}
    ;
    const res = try core.diffBytes(arena, before, after);
    const html = try renderToString(arena, &.{.{ .path = null, .res = res }}, null);
    try testing.expect(std.mem.indexOf(u8, html, ">None<") != null);
    try testing.expect(std.mem.indexOf(u8, html, ">#42<") != null);
    // ">#0<" (not bare "#0"): the embedded semantic_view.css contains color
    // codes like #0969da, so only the value-span form proves absence.
    try testing.expect(std.mem.indexOf(u8, html, ">#0<") == null);
}

test "html: nested child GameObject nests inside the parent's pl-kids" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: Parent
        \\  m_Component:
        \\  - component: {fileID: 4}
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_Father: {fileID: 0}
        \\--- !u!1 &2
        \\GameObject:
        \\  m_Name: Child
        \\  m_Component:
        \\  - component: {fileID: 5}
        \\--- !u!4 &5
        \\Transform:
        \\  m_GameObject: {fileID: 2}
        \\  m_Father: {fileID: 4}
    ;
    const after =
        \\--- !u!1 &1
        \\GameObject:
        \\  m_Name: Parent
        \\  m_Component:
        \\  - component: {fileID: 4}
        \\--- !u!4 &4
        \\Transform:
        \\  m_GameObject: {fileID: 1}
        \\  m_Father: {fileID: 0}
        \\--- !u!1 &2
        \\GameObject:
        \\  m_Name: ChildRenamed
        \\  m_Component:
        \\  - component: {fileID: 5}
        \\--- !u!4 &5
        \\Transform:
        \\  m_GameObject: {fileID: 2}
        \\  m_Father: {fileID: 4}
    ;
    const res = try core.diffBytes(arena, before, after);
    const html = try renderToString(arena, &.{.{ .path = null, .res = res }}, null);
    // Parent (unchanged) row exists, then a kids container, then the child.
    const parent_at = std.mem.indexOf(u8, html, "Parent").?;
    const kids_at = std.mem.indexOfPos(u8, html, parent_at, "<div class=\"pl-kids\">").?;
    const child_at = std.mem.indexOfPos(u8, html, kids_at, "ChildRenamed").?;
    try testing.expect(parent_at < kids_at and kids_at < child_at);
    // The renamed child is a modified GameObject card.
    try testing.expect(std.mem.indexOf(u8, html, "<details open class=\"pl-go pl-modified\">") != null);
}

test "html: added and removed fields render only their one side" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!4 &4
        \\Transform:
        \\  m_LocalPosition: {x: 0, y: 0, z: 0}
        \\  m_OldField: 1
    ;
    const after =
        \\--- !u!4 &4
        \\Transform:
        \\  m_LocalPosition: {x: 0, y: 0, z: 0}
        \\  m_NewField: 2
    ;
    const res = try core.diffBytes(arena, before, after);
    const html = try renderToString(arena, &.{.{ .path = null, .res = res }}, null);
    // Added field: pl-after value only. Removed field: pl-before value only.
    try testing.expect(std.mem.indexOf(u8, html, "<div class=\"pl-field pl-added\"><span class=\"pl-path\">New Field</span><span class=\"pl-after\">2</span></div>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<div class=\"pl-field pl-removed\"><span class=\"pl-path\">Old Field</span><span class=\"pl-before\">1</span></div>") != null);
}

test "html: file sections wrap per-path reports; empty diff notes no changes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const changed = try core.diffBytes(arena, "--- !u!4 &4\nTransform:\n  x: 1", "--- !u!4 &4\nTransform:\n  x: 2");
    const same = try core.diffBytes(arena, "--- !u!4 &4\nTransform:\n  x: 1", "--- !u!4 &4\nTransform:\n  x: 1");
    const html = try renderToString(arena, &.{
        .{ .path = "Assets/A & B.prefab", .res = changed },
        .{ .path = "Assets/Same.prefab", .res = same },
    }, null);
    // Section summaries carry the escaped path (a non pl-* class so the
    // parity tripwire stays clean).
    try testing.expect(std.mem.indexOf(u8, html, "<details open class=\"file\">") != null);
    try testing.expect(std.mem.indexOf(u8, html, "Assets/A &amp; B.prefab") != null);
    // A semantically unchanged file is listed with the extension's note, not
    // silently dropped.
    try testing.expect(std.mem.indexOf(u8, html, "No semantic changes") != null);
}

test "html: unresolved guids surface the --project hint as a note" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_Script: {fileID: 11500000, guid: abc123, type: 3}
        \\  hp: 1
    ;
    const after =
        \\--- !u!114 &5
        \\MonoBehaviour:
        \\  m_Script: {fileID: 11500000, guid: abc123, type: 3}
        \\  hp: 2
    ;
    const res = try core.diffBytes(arena, before, after);
    const html = try renderToString(arena, &.{.{ .path = null, .res = res }}, null);
    try testing.expect(std.mem.indexOf(u8, html, "--project") != null);
}

const model = core.model;
const display = @import("display.zig");
const builtin_refs = @import("builtin_refs.zig");

pub const FileDiff = struct {
    /// null for a single unnamed report (plain two-file mode / single git target).
    path: ?[]const u8,
    res: model.DiffResult,
};

// Inline SVG markup for tree glyphs, byte-identical to
// extension/src/renderer/icons.ts. Static strings only — never interpolate data.
const chevron_svg =
    \\<svg width="12" height="12" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true"><path d="M6 4l4 4-4 4" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>
;
const cube_svg =
    \\<svg width="14" height="14" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true"><path d="M8 1.5 14 5v6l-6 3.5L2 11V5l6-3.5Z" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"/><path d="M2 5l6 3.5L14 5M8 8.5V14" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"/></svg>
;
const gear_svg =
    \\<svg width="14" height="14" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true"><circle cx="8" cy="8" r="2.2" stroke="currentColor" stroke-width="1.2"/><path d="M8 1.8v2M8 12.2v2M1.8 8h2M12.2 8h2M3.7 3.7l1.4 1.4M10.9 10.9l1.4 1.4M12.3 3.7l-1.4 1.4M5.1 10.9l-1.4 1.4" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/></svg>
;
const alert_svg =
    \\<svg width="14" height="14" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true"><path d="M8 1.75a.9.9 0 0 1 .78.45l6.3 10.9a.9.9 0 0 1-.78 1.35H1.7a.9.9 0 0 1-.78-1.35l6.3-10.9A.9.9 0 0 1 8 1.75Z" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"/><path d="M8 6v3.2" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/><circle cx="8" cy="11.6" r=".8" fill="currentColor"/></svg>
;
const check_svg =
    \\<svg width="14" height="14" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true"><path d="M13.5 4.5 6.5 11.5 2.5 7.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>
;

const page_head = "<!DOCTYPE html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n" ++
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n" ++
    "<title>PrefabLens diff</title>\n<style>\n" ++ @embedFile("semantic_view.css") ++
    "</style></head><body><main>\n";
const page_tail = "</main></body></html>\n";

pub fn render(
    w: *std.Io.Writer,
    files: []const FileDiff,
    resolved: ?*const core.json.Resolver,
) !void {
    try w.writeAll(page_head);
    for (files) |f| {
        if (f.path) |p| {
            try w.writeAll("<details open class=\"file\"><summary>");
            try writeEscaped(w, p);
            try w.writeAll("</summary>");
            try renderDiff(w, f.res, resolved);
            try w.writeAll("</details>\n");
        } else {
            try renderDiff(w, f.res, resolved);
        }
    }
    try w.writeAll(page_tail);
}

fn statusClass(s: model.Status) []const u8 {
    return switch (s) {
        .added => " pl-added",
        .removed => " pl-removed",
        .modified => " pl-modified",
        .unchanged => " pl-unchanged",
    };
}

// Same marks as the extension's BADGE map (removed is U+2212 minus).
fn badge(s: model.Status) []const u8 {
    return switch (s) {
        .added => "+",
        .removed => "−",
        .modified => "~",
        .unchanged => "",
    };
}

fn renderDiff(w: *std.Io.Writer, res: model.DiffResult, resolved: ?*const core.json.Resolver) !void {
    try w.writeAll("<div class=\"pl-root\">");
    for (res.roots) |o| try renderObject(w, o, resolved);
    if (res.loose.len != 0) {
        try openComponentsSection(w, res.loose.len);
        for (res.loose) |c| try renderComponent(w, c, resolved);
        try w.writeAll("</div></details>");
    }
    if (res.roots.len == 0 and res.loose.len == 0) {
        try w.writeAll("<div class=\"pl-note pl-empty\"><span class=\"pl-note-icon\">" ++ check_svg ++ "</span><span>No semantic changes</span></div>");
    }
    if (resolved == null) {
        // Built-ins display by name (no .meta exists for them), so counting
        // them here would advertise a --project run that cannot help.
        const n = display.unresolvedCount(res);
        if (n != 0) {
            try w.writeAll("<div class=\"pl-note\"><span class=\"pl-note-icon\">" ++ alert_svg ++ "</span><span>");
            try w.print("{d} unresolved guid reference(s); pass --project DIR to resolve", .{n});
            try w.writeAll("</span></div>");
        }
    }
    try w.writeAll("</div>");
}

const Meta = union(enum) { none, prefab: ?[]const u8, script: ?[]const u8 };

fn writeSummary(
    w: *std.Io.Writer,
    status: model.Status,
    icon: []const u8,
    icon_class: []const u8,
    name: []const u8,
    meta: Meta,
    leaf: bool,
) !void {
    try w.writeAll("<summary class=\"pl-row");
    if (leaf) try w.writeAll(" pl-leaf");
    try w.writeAll("\"><span class=\"pl-chevron\">" ++ chevron_svg ++ "</span><span class=\"");
    try w.writeAll(icon_class);
    try w.writeAll("\">");
    try w.writeAll(icon);
    try w.writeAll("</span><span class=\"pl-name\">");
    try writeEscaped(w, name);
    switch (meta) {
        .none => {},
        .prefab => |p| {
            try w.writeAll("<span class=\"pl-script\">‹Prefab");
            if (p) |path| {
                try w.writeAll(": ");
                try writeEscaped(w, path);
            }
            try w.writeAll("›</span>");
        },
        .script => |p| {
            try w.writeAll("<span class=\"pl-script\">‹Script");
            if (p) |path| {
                try w.writeAll(": ");
                try writeEscaped(w, path);
            }
            try w.writeAll("›</span>");
        },
    }
    try w.writeAll("</span>");
    if (status != .unchanged) {
        try w.writeAll("<span class=\"pl-badge\">");
        try w.writeAll(badge(status));
        try w.writeAll("</span>");
    }
    try w.writeAll("</summary>");
}

fn openComponentsSection(w: *std.Io.Writer, count: usize) !void {
    try w.writeAll("<details open class=\"pl-components\"><summary class=\"pl-components-label\"><span class=\"pl-chevron\">" ++ chevron_svg ++ "</span><span>");
    try w.print("components ({d})", .{count});
    try w.writeAll("</span></summary><div class=\"pl-kids\">");
}

fn renderObject(w: *std.Io.Writer, o: model.ObjectDiff, resolved: ?*const core.json.Resolver) anyerror!void {
    const is_prefab = o.kind == .prefab_instance;
    const card_count = display.overrideGroupCount(o.overrides) + o.components.len;
    const leaf = card_count == 0 and o.children.len == 0;
    try w.writeAll(if (is_prefab) "<details open class=\"pl-pi" else "<details open class=\"pl-go");
    try w.writeAll(statusClass(o.status));
    try w.writeAll("\">");
    var meta: Meta = .none;
    if (is_prefab) {
        const path: ?[]const u8 = if (o.source_guid) |g|
            (if (resolved) |r| r.get(g) else null)
        else
            null;
        meta = .{ .prefab = path };
    }
    try writeSummary(
        w,
        o.status,
        cube_svg,
        if (is_prefab) "pl-icon pl-icon-prefab" else "pl-icon",
        display.objectName(o, resolved),
        meta,
        leaf,
    );
    if (!leaf) {
        try w.writeAll("<div class=\"pl-kids\">");
        if (card_count != 0) {
            try openComponentsSection(w, card_count);
            try renderOverrideGroups(w, o.overrides, resolved);
            for (o.components) |c| try renderComponent(w, c, resolved);
            try w.writeAll("</div></details>");
        }
        for (o.children) |child| try renderObject(w, child, resolved);
        try w.writeAll("</div>");
    }
    try w.writeAll("</details>");
}

fn renderOverrideGroups(w: *std.Io.Writer, overrides: []const model.OverrideDiff, resolved: ?*const core.json.Resolver) !void {
    var current: []const u8 = "";
    var i: usize = 0;
    while (i < overrides.len) {
        if (!std.mem.eql(u8, current, overrides[i].group)) {
            if (current.len != 0) try w.writeAll("</div></details>");
            current = overrides[i].group;
            const hs = display.groupHeadingStatus(overrides, i);
            try w.writeAll("<details open class=\"pl-comp");
            try w.writeAll(statusClass(hs));
            try w.writeAll("\">");
            try writeSummary(w, hs, gear_svg, "pl-icon", current, .none, false);
            try w.writeAll("<div class=\"pl-kids\">");
        }
        const ov = overrides[i];
        try renderField(w, ov.label, ov.status, ov.before, ov.after, resolved);
        i += 1;
    }
    if (current.len != 0) try w.writeAll("</div></details>");
}

fn renderComponent(w: *std.Io.Writer, c: model.ComponentDiff, resolved: ?*const core.json.Resolver) !void {
    const leaf = c.fields.len == 0;
    try w.writeAll("<details open class=\"pl-comp");
    try w.writeAll(statusClass(c.status));
    try w.writeAll("\">");
    // Mirror the extension: full source path as meta once the guid resolves.
    var meta: Meta = .none;
    if (c.script_guid) |g| {
        meta = .{ .script = if (resolved) |r| r.get(g) else null };
    }
    try writeSummary(w, c.status, gear_svg, "pl-icon", display.componentName(c, resolved), meta, leaf);
    if (!leaf) {
        try w.writeAll("<div class=\"pl-kids\">");
        for (c.fields) |f| try renderField(w, f.path, f.status, f.before, f.after, resolved);
        try w.writeAll("</div>");
    }
    try w.writeAll("</details>");
}

fn renderField(
    w: *std.Io.Writer,
    label: []const u8,
    status: model.Status,
    before: ?*const model.Node,
    after: ?*const model.Node,
    resolved: ?*const core.json.Resolver,
) !void {
    try w.writeAll("<div class=\"pl-field");
    try w.writeAll(statusClass(status));
    try w.writeAll("\"><span class=\"pl-path\">");
    try writeEscaped(w, label);
    try w.writeAll("</span>");
    // A structural summary row (before=after=null) has the count in its
    // label and no value — same as the extension's fieldRow.
    if (before != null or after != null) {
        switch (status) {
            .modified => {
                try w.writeAll("<span class=\"pl-before\">");
                try writeValue(w, before, resolved);
                try w.writeAll("</span><span class=\"pl-arrow\">→</span><span class=\"pl-after\">");
                try writeValue(w, after, resolved);
                try w.writeAll("</span>");
            },
            .added => {
                try w.writeAll("<span class=\"pl-after\">");
                try writeValue(w, after, resolved);
                try w.writeAll("</span>");
            },
            .removed => {
                try w.writeAll("<span class=\"pl-before\">");
                try writeValue(w, before, resolved);
                try w.writeAll("</span>");
            },
            .unchanged => {},
        }
    }
    try w.writeAll("</div>");
}

// Extension formatValue parity: — for null, None for {fileID: 0}, #fileID for
// other local refs, resolved path / built-in name / raw guid: for external refs.
fn writeValue(w: *std.Io.Writer, node: ?*const model.Node, resolved: ?*const core.json.Resolver) !void {
    const n = node orelse {
        try w.writeAll("—");
        return;
    };
    switch (n.*) {
        .scalar => |s| try writeEscaped(w, s),
        .ref => |r| {
            if (r.guid) |g| {
                if (resolved) |rr| {
                    if (rr.get(g)) |p| {
                        try writeEscaped(w, p);
                        return;
                    }
                }
                if (builtin_refs.name(g, r.file_id)) |builtin| {
                    try writeEscaped(w, builtin);
                    try w.writeAll(" (built-in)");
                    return;
                }
                try w.writeAll("guid:");
                try writeEscaped(w, g);
            } else if (r.file_id == 0) {
                // Unity's null reference; the Inspector shows it as None.
                try w.writeAll("None");
            } else {
                try w.print("#{d}", .{r.file_id});
            }
        },
        .map => try w.writeAll("{...}"),
        .seq => try w.writeAll("[...]"),
    }
}

fn writeEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(c),
    };
}
