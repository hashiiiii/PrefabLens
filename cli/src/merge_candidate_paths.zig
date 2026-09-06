const std = @import("std");
const strategy = @import("git_merge_strategy.zig");
const files = @import("merge_file_conflict.zig");
const session = @import("merge_session_context.zig");
const merge_git = @import("merge_git.zig");
const Git = merge_git.Git;

const Rename = struct { before: []const u8, after: []const u8 };
const Side = struct {
    renames: []const Rename = &.{},

    fn before(self: Side, path: []const u8) ?[]const u8 {
        for (self.renames) |rename| if (std.mem.eql(u8, rename.after, path)) return rename.before;
        return null;
    }
    fn after(self: Side, path: []const u8) []const u8 {
        for (self.renames) |rename| if (std.mem.eql(u8, rename.before, path)) return rename.after;
        return path;
    }
};

// These are file relationships reported by Git, never collection item identities.
// A clean checkout path alone cannot establish which historical blobs it merged.
pub const Map = struct {
    git: Git,
    result: strategy.Result,
    ours: Side = .{},
    theirs: Side = .{},
    enabled: bool = true,

    pub fn init(git: Git, result: strategy.Result) !Map {
        var self: Map = .{ .git = git, .result = result };
        const known = result.sources.?.known orelse return self;
        const configured = (try config(git, "merge.renames")) orelse try config(git, "diff.renames");
        if (configured) |value| self.enabled = !isFalse(value);
        var find: []const u8 = "--find-renames";
        for (result.strategy_options) |option| {
            if (std.mem.eql(u8, option, "-Xno-renames")) self.enabled = false;
            if (std.mem.eql(u8, option, "-Xfind-renames") or std.mem.eql(u8, option, "-Xrenames")) {
                self.enabled = true;
                find = "--find-renames";
            }
            for ([_][]const u8{ "-Xfind-renames=", "-Xrename-threshold=" }) |prefix| {
                if (std.mem.startsWith(u8, option, prefix)) {
                    self.enabled = true;
                    find = try std.fmt.allocPrint(git.arena, "--find-renames={s}", .{option[prefix.len..]});
                }
            }
        }
        if (!self.enabled) find = "--no-renames";
        const limit = (try config(git, "merge.renameLimit")) orelse (try config(git, "diff.renameLimit")) orelse "7000";
        self.ours = try scan(git, known.base, known.ours, find, limit);
        self.theirs = try scan(git, known.base, known.theirs, find, limit);
        return self;
    }

    pub fn resolve(self: Map, path: []const u8) !?session.Paths {
        const direct: session.Paths = .{ .base = path, .ours = path, .theirs = path };
        const known = self.result.sources.?.known orelse return direct;
        const local_origin = self.ours.before(path);
        const remote_origin = self.theirs.before(path);
        if (local_origin != null and remote_origin != null and !std.mem.eql(u8, local_origin.?, remote_origin.?)) return null;
        const origin = local_origin orelse remote_origin orelse {
            const base = try files.treeEntry(self.git, known.base, path);
            const ours = try files.treeEntry(self.git, known.ours, path);
            const theirs = try files.treeEntry(self.git, known.theirs, path);
            if (ours == null and theirs == null) return null;
            if (base == null and (ours == null or theirs == null)) {
                // A direct one-sided addition is proven by this path's exact
                // accepted blob and mode. Unrelated deletions provide no identity
                // evidence. Propagated candidate content still needs a mapping.
                const added = ours orelse theirs.?;
                const accepted = (try files.treeEntry(self.git, self.result.tree, path)) orelse return null;
                if (!std.mem.eql(u8, added.oid, accepted.oid) or !std.mem.eql(u8, added.mode, accepted.mode)) return null;
            }
            if (!std.mem.eql(u8, self.ours.after(path), path) or !std.mem.eql(u8, self.theirs.after(path), path)) return null;
            return direct;
        };
        const paths: session.Paths = .{ .base = origin, .ours = self.ours.after(origin), .theirs = self.theirs.after(origin) };
        // A rename/add collision, divergent destination, or surviving old checkout
        // path is not the clean one-identity relationship handled here.
        if (try files.treeEntry(self.git, known.base, origin) == null or
            try files.treeEntry(self.git, known.base, path) != null or
            try files.treeEntry(self.git, self.result.tree, origin) != null or
            try files.treeEntry(self.git, known.ours, paths.ours) == null or
            try files.treeEntry(self.git, known.theirs, paths.theirs) == null) return null;
        if (!std.mem.eql(u8, paths.ours, path) and (!std.mem.eql(u8, paths.ours, origin) or try files.treeEntry(self.git, known.ours, path) != null)) return null;
        if (!std.mem.eql(u8, paths.theirs, path) and (!std.mem.eql(u8, paths.theirs, origin) or try files.treeEntry(self.git, known.theirs, path) != null)) return null;
        for (self.result.conflicts) |conflict| for (conflict.paths) |conflict_path| {
            if (std.mem.eql(u8, conflict_path, origin)) return null;
        };
        return paths;
    }
};

fn scan(git: Git, base: []const u8, side: []const u8, find: []const u8, limit: ?[]const u8) !Side {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(git.arena, &.{ "diff-tree", "--no-commit-id", "--name-status", "-r", "-z", find });
    if (limit) |value| try args.append(git.arena, try std.fmt.allocPrint(git.arena, "-l{s}", .{value}));
    try args.appendSlice(git.arena, &.{ base, side, "--" });
    const bytes = try git.output(args.items);
    var records = std.mem.splitScalar(u8, bytes, 0);
    var renames: std.ArrayList(Rename) = .empty;
    while (records.next()) |status| {
        if (status.len == 0) break;
        const path = records.next() orelse return error.InvalidRenameOutput;
        if (status[0] == 'R') {
            const destination = records.next() orelse return error.InvalidRenameOutput;
            try renames.append(git.arena, .{ .before = path, .after = destination });
        }
    }
    return .{ .renames = renames.items };
}

fn config(git: Git, key: []const u8) !?[]const u8 {
    const result = try git.run(&.{ "config", "--get", key });
    return switch (merge_git.exitCode(result)) {
        0 => merge_git.trim(result.stdout),
        1 => null,
        else => error.InvalidRenameConfig,
    };
}
fn isFalse(value: []const u8) bool {
    for ([_][]const u8{ "false", "no", "off", "0" }) |word| if (std.ascii.eqlIgnoreCase(value, word)) return true;
    return false;
}
