const std = @import("std");
const model = @import("model.zig");

pub const Span = struct {
    start: usize,
    end: usize,

    pub fn bytes(self: Span, source_bytes: []const u8) []const u8 {
        return source_bytes[self.start..self.end];
    }
};

pub const EntrySpan = struct { whole: Span, key: Span, value: Span };
pub const DocumentSpan = struct {
    whole: Span,
    header: Span,
    class_id: Span,
    file_id: Span,
};
pub const LineEnding = enum { lf, crlf };
pub const Diagnostic = enum {
    invalid_document_header,
    missing_type_name,
    invalid_map_entry,
    invalid_flow_value,
    non_map_document_body,
    duplicate_key,
    unconsumed_line,
};

pub const ParsedFile = struct {
    bytes: []const u8,
    documents: []model.Document,
    document_spans: []DocumentSpan,
    node_spans: std.AutoHashMapUnmanaged(*const model.Node, Span),
    entry_spans: std.AutoHashMapUnmanaged(*const model.Node, EntrySpan),
    sequence_item_spans: std.AutoHashMapUnmanaged(*const model.Node, Span),
    diagnostics: []Diagnostic,
    line_ending: LineEnding,

    pub fn documentBytes(self: ParsedFile, index: usize) []const u8 {
        return self.document_spans[index].whole.bytes(self.bytes);
    }

    pub fn nodeBytes(self: ParsedFile, node: *const model.Node) ?[]const u8 {
        const span = self.node_spans.get(node) orelse return null;
        return span.bytes(self.bytes);
    }

    pub fn sequenceItemBytes(self: ParsedFile, node: *const model.Node) ?[]const u8 {
        const span = self.sequence_item_spans.get(node) orelse return null;
        return span.bytes(self.bytes);
    }

    pub fn lineEndingAt(self: ParsedFile, offset: usize) []const u8 {
        const next_lf = std.mem.indexOfScalarPos(u8, self.bytes, offset, '\n');
        if (next_lf) |lf| return if (lf != 0 and self.bytes[lf - 1] == '\r') "\r\n" else "\n";
        if (offset > 0 and offset <= self.bytes.len and self.bytes[offset - 1] == '\n') {
            return if (offset > 1 and self.bytes[offset - 2] == '\r') "\r\n" else "\n";
        }
        return if (self.line_ending == .crlf) "\r\n" else "\n";
    }
};
