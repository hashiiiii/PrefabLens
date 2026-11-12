const std = @import("std");
const builtin = @import("builtin");
const t = @import("integration");

const base = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 1\n  m_Right: 1\n";
const ours = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 2\n  m_Right: 1\n";
const theirs = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 1\n  m_Right: 3\n";
const merged = "--- !u!114 &1\nMonoBehaviour:\n  m_Left: 2\n  m_Right: 3\n";
const Operation = enum { strategy, rebase, ort };
const usage = "zig build benchmark-merge-strategy -- --before <binary> --after <binary> --output <json> [--files N] [--fields N] [--padding N] [--commits N] [--runs N] [--operations strategy rebase ort]\n";

const Options = struct {
    before: []const u8 = "",
    after: []const u8 = "",
    output: []const u8 = "",
    files: usize = 1001,
    fields: usize = 50,
    padding: usize = 0,
    commits: usize = 5,
    runs: usize = 3,
    operations: []const Operation = &.{ .strategy, .rebase },

    fn parse(a: std.mem.Allocator, args: []const []const u8) !Options {
        var result: Options = .{};
        var i: usize = 0;
        while (i < args.len) {
            const key = args[i];
            i += 1;
            if (i == args.len) return error.InvalidArguments;
            if (std.mem.eql(u8, key, "--operations")) {
                var operations: std.ArrayList(Operation) = .empty;
                while (i < args.len and !std.mem.startsWith(u8, args[i], "--")) : (i += 1) {
                    try operations.append(a, std.meta.stringToEnum(Operation, args[i]) orelse return error.InvalidArguments);
                }
                if (operations.items.len == 0) return error.InvalidArguments;
                result.operations = operations.items;
                continue;
            }
            const value = args[i];
            i += 1;
            if (std.mem.eql(u8, key, "--before")) result.before = value else if (std.mem.eql(u8, key, "--after")) result.after = value else if (std.mem.eql(u8, key, "--output")) result.output = value else {
                const n = std.fmt.parseInt(usize, value, 10) catch return error.InvalidArguments;
                if (std.mem.eql(u8, key, "--files")) result.files = n else if (std.mem.eql(u8, key, "--fields")) result.fields = n else if (std.mem.eql(u8, key, "--padding")) result.padding = n else if (std.mem.eql(u8, key, "--commits")) result.commits = n else if (std.mem.eql(u8, key, "--runs")) result.runs = n else return error.InvalidArguments;
            }
        }
        if (result.before.len == 0 or result.after.len == 0 or result.output.len == 0 or result.commits == 0 or result.runs == 0) return error.InvalidArguments;
        return result;
    }
};

const Git = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    env: *std.process.Environ.Map,
    cwd: []const u8,

    fn run(self: Git, args: []const []const u8) ![]const u8 {
        const result = try std.process.run(self.arena, self.io, .{
            .argv = try std.mem.concat(self.arena, []const u8, &.{ &.{"git"}, args }),
            .cwd = .{ .path = self.cwd },
            .environ_map = self.env,
            .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(180) } },
        });
        try t.expectCode(result, 0, "benchmark Git command");
        return std.mem.trimEnd(u8, result.stdout, "\r\n");
    }

    fn write(self: Git, path: []const u8, bytes: []const u8) !void {
        try t.writeFile(self.io, self.arena, self.cwd, path, bytes);
    }
};

const Sample = struct {
    binary: []const u8,
    operation: Operation,
    sample: usize,
    seconds: f64,
    command_max_rss_bytes: ?usize,
    strategy_calls: usize = 0,
    driver_calls: usize = 0,
};

pub fn main(init: std.process.Init) !u8 {
    var memory = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer memory.deinit();
    const a = memory.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const args = try init.minimal.args.toSlice(a);
    const options = Options.parse(a, args[2..]) catch {
        try std.Io.File.stderr().writeStreamingAll(io, usage);
        return 2;
    };
    const scratch = try t.scratchDirectory(io, a, "merge-benchmark");
    defer cwd.deleteTree(io, scratch) catch {};
    const repo = try std.fs.path.join(a, &.{ scratch, "repo" });
    try cwd.createDirPath(io, try std.fs.path.join(a, &.{ repo, "Assets" }));
    try cwd.createDirPath(io, try std.fs.path.join(a, &.{ repo, "Notes" }));
    var env = std.process.Environ.Map.init(a);
    var entries = init.environ_map.iterator();
    while (entries.next()) |entry| {
        if (std.mem.startsWith(u8, entry.key_ptr.*, "GIT_") or std.mem.startsWith(u8, entry.key_ptr.*, "PREFABLENS_MERGE_")) continue;
        try env.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    const null_path = if (builtin.os.tag == .windows) "NUL" else "/dev/null";
    for ([_][]const u8{ "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM" }) |key| try env.put(key, null_path);
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_ATTR_NOSYSTEM", "1");
    try env.put("GIT_CONFIG_COUNT", "0");
    try env.put("GIT_TERMINAL_PROMPT", "0");
    try env.put("GIT_EDITOR", "true");
    const git: Git = .{ .io = io, .arena = a, .env = &env, .cwd = repo };
    try fixture(git, options);

    var samples: std.ArrayList(Sample) = .empty;
    for ([_][]const u8{ "before", "after" }, [_][]const u8{ options.before, options.after }) |label, executable| {
        const bindir = try std.fs.path.join(a, &.{ scratch, label });
        try cwd.createDirPath(io, bindir);
        const binary = try std.fs.path.join(a, &.{ bindir, if (builtin.os.tag == .windows) "prefablens.exe" else "prefablens" });
        try cwd.copyFile(try cwd.realPathFileAlloc(io, executable, a), cwd, binary, io, .{});
        try cwd.copyFile(args[1], cwd, try std.fs.path.join(a, &.{ bindir, "git-merge-prefablens" }), io, .{});
        var active = try env.clone(a);
        try active.put("PATH", try std.fmt.allocPrint(a, "{s}{c}{s}", .{ bindir, std.fs.path.delimiter, env.get("PATH") orelse "" }));
        var installed = git;
        installed.env = &active;
        for (options.operations) |operation| for (0..options.runs) |sample| {
            // A new arena keeps the benchmark harness from retaining subprocess
            // output and trace data across samples of a large repository.
            var run_memory = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer run_memory.deinit();
            var current = installed;
            current.arena = run_memory.allocator();
            _ = try current.run(&.{ "reset", "--hard", "feature-original" });
            _ = try current.run(&.{ "checkout", "-q", "-B", "feature", "feature-original" });
            _ = try current.run(&.{ "config", "merge.prefablens.driver", "prefablens merge-driver %O %A %B %P %L" });
            _ = try current.run(&.{ "config", "merge.prefablens.recursive", "text" });
            _ = try current.run(&.{ "config", "pull.twohead", "prefablens" });
            const command: []const []const u8 = switch (operation) {
                .strategy => &.{ binary, "merge-strategy", try current.run(&.{ "rev-parse", "main" }), "--", try current.run(&.{ "rev-parse", "HEAD" }), try current.run(&.{ "rev-parse", "develop" }) },
                .rebase => &.{ "git", "rebase", "develop" },
                .ort => &.{ "git", "rebase", "-s", "ort", "develop" },
            };
            const trace = try std.fs.path.join(current.arena, &.{ scratch, "trace.json" });
            cwd.deleteFile(io, trace) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            try active.put("GIT_TRACE2_EVENT", trace);
            var row = try measure(current, command, try std.fs.path.join(current.arena, &.{ scratch, "command.log" }));
            row.binary = label;
            row.operation = operation;
            row.sample = sample + 1;
            try countCalls(current, trace, &row);
            _ = active.swapRemove("GIT_TRACE2_EVENT");
            try t.expectFile(io, current.arena, repo, "Assets/Changed.prefab", merged);
            if (operation != .strategy) {
                try t.require(std.mem.eql(u8, try current.run(&.{ "rev-list", "--count", "develop..HEAD" }), try std.fmt.allocPrint(current.arena, "{d}", .{options.commits})), "benchmark lost replayed commits");
                for (0..options.commits) |i| try t.expectFile(io, current.arena, repo, try std.fmt.allocPrint(current.arena, "Notes/feature-{d}.txt", .{i}), try std.fmt.allocPrint(current.arena, "feature {d}\n", .{i}));
            }
            try samples.append(a, row);
            try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.allocPrint(current.arena, "{s}\n", .{try std.json.Stringify.valueAlloc(current.arena, row, .{})}));
        };
    }
    const report = .{ .platform = @tagName(builtin.os.tag), .arch = @tagName(builtin.cpu.arch), .git = try git.run(&.{"--version"}), .files = options.files, .fields = options.fields, .padding = options.padding, .commits = options.commits, .samples = samples.items };
    try cwd.writeFile(io, .{ .sub_path = options.output, .data = try std.json.Stringify.valueAlloc(a, report, .{ .whitespace = .indent_2 }) });
    return 0;
}

fn fixture(git: Git, options: Options) !void {
    _ = try git.run(&.{ "init", "-q", "-b", "main" });
    try t.configureHermeticRepository(git.io, git.arena, git.cwd);
    for ([_][2][]const u8{ .{ "user.name", "Benchmark" }, .{ "user.email", "benchmark@example.invalid" }, .{ "gc.auto", "0" }, .{ "maintenance.auto", "false" } }) |pair| _ = try git.run(&.{ "config", pair[0], pair[1] });
    try git.write(".gitattributes", "*.prefab merge=prefablens\n");
    for (0..options.files) |i| {
        const path = try std.fs.path.join(git.arena, &.{ git.cwd, try std.fmt.allocPrint(git.arena, "Assets/F{d:0>5}.prefab", .{i}) });
        const file = try std.Io.Dir.cwd().createFile(git.io, path, .{});
        defer file.close(git.io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(git.io, &buffer);
        try writer.interface.print("--- !u!114 &1\nMonoBehaviour:\n  m_Id: {d}\n", .{i});
        for (0..options.fields) |field| try writer.interface.print("  m_Field{d}: {d}\n", .{ field, field });
        // Stream large scalars so fixture generation does not itself retain
        // gigabytes of padding and obscure the strategy's memory behavior.
        if (options.padding != 0) {
            try writer.interface.writeAll("  m_Padding: ");
            try writer.interface.splatByteAll('x', options.padding);
            try writer.interface.writeByte('\n');
        }
        try writer.flush();
        try git.write(try std.fmt.allocPrint(git.arena, "Assets/F{d:0>5}.prefab.meta", .{i}), try std.fmt.allocPrint(git.arena, "fileFormatVersion: 2\nguid: {x:0>32}\n", .{i + 1}));
    }
    try git.write("Assets/Changed.prefab", base);
    try git.write("Notes/develop.txt", "base\n");
    _ = try git.run(&.{ "add", "." });
    _ = try git.run(&.{ "commit", "-qm", "base" });
    _ = try git.run(&.{ "switch", "-qc", "feature" });
    for (0..options.commits) |i| {
        try git.write(try std.fmt.allocPrint(git.arena, "Notes/feature-{d}.txt", .{i}), try std.fmt.allocPrint(git.arena, "feature {d}\n", .{i}));
        if (i == 0) try git.write("Assets/Changed.prefab", ours);
        _ = try git.run(&.{ "add", "." });
        _ = try git.run(&.{ "commit", "-qm", "feature change" });
    }
    _ = try git.run(&.{ "branch", "feature-original" });
    _ = try git.run(&.{ "switch", "-qc", "develop", "main" });
    try git.write("Notes/develop.txt", "develop\n");
    try git.write("Assets/Changed.prefab", theirs);
    _ = try git.run(&.{ "add", "." });
    _ = try git.run(&.{ "commit", "-qm", "develop" });
    _ = try git.run(&.{ "switch", "-q", "feature" });
    _ = try git.run(&.{ "fsck", "--no-reflogs" });
}

fn measure(git: Git, command: []const []const u8, log_path: []const u8) !Sample {
    const log = try std.Io.Dir.cwd().createFile(git.io, log_path, .{});
    defer log.close(git.io);
    const started = std.Io.Clock.Timestamp.now(git.io, .awake);
    // File-backed output cannot fill a pipe while the parent waits for rusage.
    var child = try std.process.spawn(git.io, .{ .argv = command, .cwd = .{ .path = git.cwd }, .environ_map = git.env, .stdin = .ignore, .stdout = .{ .file = log }, .stderr = .{ .file = log }, .request_resource_usage_statistics = true });
    defer child.kill(git.io);
    const Event = union(enum) { finished: std.process.Child.WaitError!std.process.Child.Term, expired: std.Io.Cancelable!void };
    var events: [2]Event = undefined;
    var select: std.Io.Select(Event) = .init(git.io, &events);
    defer _ = select.cancel();
    try select.concurrent(.finished, std.process.Child.wait, .{ &child, git.io });
    select.async(.expired, std.Io.sleep, .{ git.io, .fromSeconds(180), .awake });
    const term = switch (try select.await()) {
        .finished => |result| try result,
        .expired => |result| {
            try result;
            return error.BenchmarkTimedOut;
        },
    };
    if (!term.success()) {
        try std.Io.File.stderr().writeStreamingAll(git.io, try std.Io.Dir.cwd().readFileAlloc(git.io, log_path, git.arena, .limited(1024 * 1024)));
        return error.BenchmarkCommandFailed;
    }
    const ended = std.Io.Clock.Timestamp.now(git.io, .awake);
    return .{ .binary = "", .operation = .strategy, .sample = 0, .seconds = @as(f64, @floatFromInt(started.durationTo(ended).raw.toNanoseconds())) / std.time.ns_per_s, .command_max_rss_bytes = child.resource_usage_statistics.getMaxRss() };
}

fn countCalls(git: Git, path: []const u8, row: *Sample) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(git.io, path, git.arena, .limited(64 * 1024 * 1024));
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const Event = struct { event: []const u8, argv: []const []const u8 = &.{} };
        const parsed = try std.json.parseFromSlice(Event, git.arena, line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.event, "child_start")) continue;
        var strategy = false;
        var version = false;
        var driver = false;
        for (parsed.value.argv) |arg| {
            if (std.mem.eql(u8, arg, "merge-prefablens")) strategy = true;
            if (std.mem.eql(u8, arg, "--version")) version = true;
            if (std.mem.indexOf(u8, arg, "merge-driver") != null) driver = true;
        }
        if (strategy and !version) row.strategy_calls += 1;
        if (driver) row.driver_calls += 1;
    }
}
