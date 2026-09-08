const std = @import("std");
const builtin = @import("builtin");
const integration = @import("git.zig");
const gwidth = @import("vaxis").gwidth;

const capture_width = 100;
const capture_height = 24;

pub fn terminalCaptureContains(capture: []const u8, needle: []const u8) bool {
    return captureCount(capture, needle, false) != 0;
}

pub fn terminalScreenContains(capture: []const u8, needle: []const u8) bool {
    return terminalScreenLineCount(capture, needle) != 0;
}

pub fn terminalScreenLineCount(capture: []const u8, needle: []const u8) usize {
    return captureCount(capture, needle, true);
}

fn captureCount(capture: []const u8, needle: []const u8, current_only: bool) usize {
    var cells: [capture_height][capture_width]u8 = undefined;
    for (&cells) |*screen_row| @memset(screen_row, ' ');
    var row: usize = 0;
    var col: usize = 0;
    var index: usize = 0;
    var alternate_active = false;

    while (index < capture.len) {
        const byte = capture[index];
        if (byte == 0x1b) {
            index = consumeEscape(capture, index, &row, &col, &cells, &alternate_active);
            continue;
        }
        if (byte >= 0xc0) {
            const length = std.unicode.utf8ByteSequenceLength(byte) catch 1;
            if (index + length > capture.len) break;
            const width = gwidth.gwidth(capture[index..][0..length], .wcwidth);
            const end = @min(col + width, capture_width);
            @memset(cells[row][col..end], ' ');
            col = end;
            index += length;
            continue;
        }
        index += 1;
        switch (byte) {
            '\r' => col = 0,
            '\n' => row = @min(row + 1, capture_height - 1),
            '\x08' => col -|= 1,
            '\t' => col = @min((col / 8 + 1) * 8, capture_width - 1),
            0x20...0x7e => {
                if (col < capture_width) {
                    cells[row][col] = byte;
                    col += 1;
                }
                if (!current_only and alternate_active and std.mem.indexOf(u8, &cells[row], needle) != null) return 1;
            },
            else => {},
        }
    }
    var count: usize = 0;
    if (current_only and alternate_active) {
        for (cells) |screen_row| {
            count = @max(count, std.mem.count(u8, &screen_row, needle));
        }
    }
    return count;
}

fn consumeEscape(
    capture: []const u8,
    escape_index: usize,
    row: *usize,
    col: *usize,
    cells: *[capture_height][capture_width]u8,
    alternate_active: *bool,
) usize {
    if (escape_index + 1 >= capture.len) return capture.len;
    return switch (capture[escape_index + 1]) {
        '[' => consumeCsi(capture, escape_index + 2, row, col, cells, alternate_active),
        ']', 'P', '_', '^' => consumeControlString(capture, escape_index + 2),
        else => escape_index + 2,
    };
}

fn consumeControlString(capture: []const u8, start: usize) usize {
    var index = start;
    while (index < capture.len) : (index += 1) {
        if (capture[index] == 0x07) return index + 1;
        if (capture[index] == 0x1b and index + 1 < capture.len and capture[index + 1] == '\\') {
            return index + 2;
        }
    }
    return capture.len;
}

fn consumeCsi(
    capture: []const u8,
    start: usize,
    row: *usize,
    col: *usize,
    cells: *[capture_height][capture_width]u8,
    alternate_active: *bool,
) usize {
    var params = [_]usize{0} ** 4;
    var param_count: usize = 1;
    var index = start;
    var private_mode = false;
    while (index < capture.len) : (index += 1) {
        const byte = capture[index];
        switch (byte) {
            '0'...'9' => {
                const param = &params[param_count - 1];
                param.* = param.* * 10 + byte - '0';
            },
            ';' => {
                if (param_count < params.len) param_count += 1;
            },
            '?' => private_mode = true,
            0x40...0x7e => {
                applyCsi(byte, params, param_count, private_mode, row, col, cells, alternate_active);
                return index + 1;
            },
            else => {},
        }
    }
    return capture.len;
}

fn applyCsi(
    command: u8,
    params: [4]usize,
    param_count: usize,
    private_mode: bool,
    row: *usize,
    col: *usize,
    cells: *[capture_height][capture_width]u8,
    alternate_active: *bool,
) void {
    const first = if (params[0] == 0) 1 else params[0];
    const second = if (param_count < 2 or params[1] == 0) 1 else params[1];
    switch (command) {
        'H', 'f' => {
            row.* = @min(first - 1, capture_height - 1);
            col.* = @min(second - 1, capture_width - 1);
        },
        'G' => col.* = @min(first - 1, capture_width - 1),
        'd' => row.* = @min(first - 1, capture_height - 1),
        'A' => row.* -|= first,
        'B' => row.* = @min(row.* + first, capture_height - 1),
        'C' => col.* = @min(col.* + first, capture_width - 1),
        'D' => col.* -|= first,
        'X' => @memset(cells[row.*][@min(col.*, capture_width)..@min(col.* + first, capture_width)], ' '),
        'P' => {
            const start = @min(col.*, capture_width);
            const count = @min(first, capture_width - start);
            std.mem.copyForwards(u8, cells[row.*][start .. capture_width - count], cells[row.*][start + count ..]);
            @memset(cells[row.*][capture_width - count ..], ' ');
        },
        'J' => switch (params[0]) {
            0 => {
                @memset(cells[row.*][@min(col.*, capture_width)..], ' ');
                for (cells[row.* + 1 ..]) |*screen_row| @memset(screen_row, ' ');
            },
            1 => {
                for (cells[0..row.*]) |*screen_row| @memset(screen_row, ' ');
                @memset(cells[row.*][0..@min(col.* + 1, capture_width)], ' ');
            },
            2, 3 => for (cells) |*screen_row| @memset(screen_row, ' '),
            else => {},
        },
        'K' => switch (params[0]) {
            0 => @memset(cells[row.*][@min(col.*, capture_width)..], ' '),
            1 => @memset(cells[row.*][0..@min(col.* + 1, capture_width)], ' '),
            2 => @memset(&cells[row.*], ' '),
            else => {},
        },
        'h' => if (private_mode and params[0] == 1049) {
            for (cells) |*screen_row| @memset(screen_row, ' ');
            row.* = 0;
            col.* = 0;
            alternate_active.* = true;
        },
        'l' => if (private_mode and params[0] == 1049) {
            alternate_active.* = false;
        },
        else => {},
    }
}

pub fn runCommandInPty(
    io: std.Io,
    arena: std.mem.Allocator,
    repository: []const u8,
    git_command: []const u8,
    input_keys: []const u8,
    timeout_seconds: i64,
) !std.process.RunResult {
    return runCommandInPtyBatches(io, arena, repository, git_command, input_keys, "", timeout_seconds);
}

// A nonempty first batch advances to another terminal session before the second.
// An empty first batch holds the initial UI for concurrent-mutation fixtures.
pub fn runCommandInPtyBatches(
    io: std.Io,
    arena: std.mem.Allocator,
    repository: []const u8,
    git_command: []const u8,
    input_keys: []const u8,
    second_keys: []const u8,
    timeout_seconds: i64,
) !std.process.RunResult {
    return runCommandInPtyThreeBatches(io, arena, repository, git_command, input_keys, second_keys, "", timeout_seconds);
}

// The third batch continues the second UI after it renders the second batch's result.
pub fn runCommandInPtyThreeBatches(
    io: std.Io,
    arena: std.mem.Allocator,
    repository: []const u8,
    git_command: []const u8,
    input_keys: []const u8,
    second_keys: []const u8,
    third_keys: []const u8,
    timeout_seconds: i64,
) !std.process.RunResult {
    return runPty(io, arena, repository, git_command, input_keys, second_keys, third_keys, "", timeout_seconds);
}

// Concurrent changes must happen after checkout finishes and before the first UI accepts input.
pub fn runCommandInPtyWithUiAction(
    io: std.Io,
    arena: std.mem.Allocator,
    repository: []const u8,
    git_command: []const u8,
    ui_action: []const u8,
    input_keys: []const u8,
    second_keys: []const u8,
    timeout_seconds: i64,
) !std.process.RunResult {
    return runPty(io, arena, repository, git_command, input_keys, second_keys, "", ui_action, timeout_seconds);
}

fn runPty(
    io: std.Io,
    arena: std.mem.Allocator,
    repository: []const u8,
    git_command: []const u8,
    input_keys: []const u8,
    second_keys: []const u8,
    third_keys: []const u8,
    ui_action: []const u8,
    timeout_seconds: i64,
) !std.process.RunResult {
    var random: [16]u8 = undefined;
    io.random(&random);
    const capture = try std.fmt.allocPrint(arena, "/tmp/prefablens-pty-{x}.log", .{random});
    defer std.Io.Dir.cwd().deleteFile(io, capture) catch {};
    const completed = try std.fmt.allocPrint(arena, "{s}.done", .{capture});
    defer std.Io.Dir.cwd().deleteFile(io, completed) catch {};
    const action_failed = try std.fmt.allocPrint(arena, "{s}.action-failed", .{capture});
    defer std.Io.Dir.cwd().deleteFile(io, action_failed) catch {};
    const capture_argument = try integration.shellQuote(arena, capture);
    const terminal_command = try integration.shellQuote(arena, try std.fmt.allocPrint(arena, "stty cols 100 rows 24; {s}; terminal_status=$?; : > {s}; exit \"$terminal_status\"", .{ git_command, try integration.shellQuote(arena, completed) }));
    const shell_command = switch (builtin.os.tag) {
        .linux => try std.fmt.allocPrint(arena, "script -qfec {s} {s}", .{ terminal_command, capture_argument }),
        .macos => try std.fmt.allocPrint(arena, "script -qF {s} sh -c {s}", .{ capture_argument, terminal_command }),
        else => unreachable,
    };
    const command = try std.fmt.allocPrint(
        arena,
        // Reply once per Kitty query so capability logs cannot disturb later UI frames.
        // DA1 must follow keyboard support because it ends capability discovery.
        // libvaxis needs a DSR reply to stop its input thread.
        // Wait for the active UI and any fixture mutation before sending user input.
        \\(
        \\capture_file=$4
        \\keyboard_replies=0
        \\status_replies=0
        \\reply_terminal() {{
        \\  [ ! -e "$capture_file.done" ] || return 1
        \\  state=$(LC_ALL=C awk {s} "$capture_file" 2>/dev/null)
        \\  set -- $state
        \\  if [ "$#" -eq 6 ] && [ "$5" -gt "$keyboard_replies" ]; then
        \\    printf '\033[?0u\033[?1;2c' || return 1
        \\    keyboard_replies=$5
        \\  fi
        \\  if [ "$#" -eq 6 ] && [ "$6" -gt "$status_replies" ]; then
        \\    printf '\033[0n' || return 1
        \\    status_replies=$6
        \\  fi
        \\}}
        \\wait_frame() {{
        \\  min_session=$1
        \\  min_frame=$2
        \\  while :; do
        \\    reply_terminal || exit 0
        \\    set -- $state
        \\    if [ "$#" -eq 6 ] && [ "$4" -eq 1 ] && [ "$3" -eq "$1" ] && [ "$1" -ge "$min_session" ] && [ "$2" -gt "$min_frame" ]; then
        \\      observed_session=$1
        \\      observed_frame=$2
        \\      return
        \\    fi
        \\    sleep 0.1
        \\  done
        \\}}
        \\wait_frame 1 0
        \\first_session=$observed_session
        // Action output must not become terminal input. Keep failures visible after the UI exits.
        \\if [ -n "$5" ]; then
        \\  sh -c "$5" >&2 || : > "$capture_file.action-failed"
        \\fi
        \\printf '%s' "$1"
        \\if [ -n "$2" ]; then
        \\  if [ -n "$1" ]; then
        \\    wait_frame "$((first_session + 1))" 0
        \\  else
        \\    wait_frame "$first_session" 0
        \\  fi
        \\  second_frame=$observed_frame
        \\  second_session=$observed_session
        \\  printf '%s' "$2"
        \\fi
        \\if [ -n "$3" ]; then
        \\  wait_frame "$second_session" "$second_frame"
        \\  printf '%s' "$3"
        \\fi
        \\i=0
        \\while [ "$i" -lt 100 ]; do
        \\  sleep 0.1
        \\  reply_terminal || exit 0
        \\  i=$((i + 1))
        \\done
        \\) | TERM=xterm-256color {s} &
        \\pty_pid=$!
        \\trap ': > "$4.done"; kill "$pty_pid" 2>/dev/null; wait "$pty_pid" 2>/dev/null; exit 124' HUP INT TERM
        \\wait "$pty_pid"
        \\status=$?
        \\trap - HUP INT TERM
        \\if [ -e "$4.action-failed" ]; then status=125; fi
        \\exit "$status"
    ,
        .{ try integration.shellQuote(arena, frame_probe), shell_command },
    );
    return std.process.run(arena, io, .{
        .argv = &.{ "sh", "-c", command, "prefablens-keys", input_keys, second_keys, third_keys, capture, ui_action },
        .cwd = .{ .path = repository },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(timeout_seconds) } },
    }) catch |err| {
        if (err == error.Timeout) {
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, capture, arena, .limited(1024 * 1024)) catch "(PTY capture unavailable)";
            try std.Io.File.stderr().writeStreamingAll(io, bytes);
        }
        return err;
    };
}

// libvaxis surrounds terminal sessions and synchronized renders with these CSI
// sequences. A partial frame or a completed frame from an exited UI is not ready.
const frame_probe =
    \\BEGIN { RS="\033" }
    \\/^\[\?1049h/ { session++; active=1; pending=0 }
    \\/^\[\?1049l/ { active=0; pending=0 }
    \\/^\[\?2026h/ { if (active) pending=1 }
    \\/^\[\?2026l/ { if (active && pending) { frames++; complete=session }; pending=0 }
    \\/^\[\?u/ { keyboards++ }
    \\/^\[5n/ { reports++ }
    \\END { print session+0, frames+0, complete+0, active+0, keyboards+0, reports+0 }
;
