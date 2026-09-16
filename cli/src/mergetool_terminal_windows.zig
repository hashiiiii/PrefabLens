const std = @import("std");
const windows = std.os.windows;

pub fn run(arena: std.mem.Allocator, argv: []const []const u8) !u8 {
    const application = try std.unicode.wtf8ToWtf16LeAllocZ(arena, argv[0]);
    const command_line = try commandLine(arena, argv);
    var startup: windows.STARTUPINFOW = std.mem.zeroes(windows.STARTUPINFOW);
    startup.cb = @sizeOf(windows.STARTUPINFOW);
    var process: windows.PROCESS.INFORMATION = undefined;
    // Inheriting Fork's redirected handles would leave the new window without terminal input.
    if (windows.kernel32.CreateProcessW(application, command_line, null, null, .FALSE, .{ .create_new_console = true }, null, null, &startup, &process) == .FALSE)
        return error.TerminalLaunchFailed;
    defer windows.CloseHandle(process.hProcess);
    defer windows.CloseHandle(process.hThread);
    if (WaitForSingleObject(process.hProcess, 0xffffffff) != 0) return error.TerminalWaitFailed;
    var code: windows.DWORD = undefined;
    if (GetExitCodeProcess(process.hProcess, &code) == .FALSE) return error.TerminalWaitFailed;
    // Closing the console produces a Windows status code, which must never become success by truncation.
    return if (code <= 2) @intCast(code) else 2;
}

extern "kernel32" fn WaitForSingleObject(windows.HANDLE, windows.DWORD) callconv(.winapi) windows.DWORD;
extern "kernel32" fn GetExitCodeProcess(windows.HANDLE, *windows.DWORD) callconv(.winapi) windows.BOOL;

fn commandLine(arena: std.mem.Allocator, argv: []const []const u8) ![:0]u16 {
    var line: std.Io.Writer.Allocating = .init(arena);
    const out = &line.writer;
    for (argv, 0..) |arg, index| {
        if (index > 0) try out.writeByte(' ');
        try out.writeByte('"');
        var slashes: usize = 0;
        for (arg) |byte| {
            if (byte == '\\') {
                slashes += 1;
                continue;
            }
            try out.splatByteAll('\\', if (byte == '"') slashes * 2 + 1 else slashes);
            slashes = 0;
            try out.writeByte(byte);
        }
        try out.splatByteAll('\\', slashes * 2);
        try out.writeByte('"');
    }
    return std.unicode.wtf8ToWtf16LeAllocZ(arena, line.written());
}

test "terminal: Windows arguments survive spaces quotes and trailing backslashes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The executable and each path must arrive intact without passing through cmd.exe expansion.
    const argv = [_][]const u8{ "C:\\Program Files\\PrefabLens\\prefablens.exe", "mergetool", "C:\\日本語 folder\\base.prefab", "quote\"in\\path", "%PATH% !value! &file", "trailing\\", "" };
    const line = try commandLine(arena, &argv);
    var parsed = try std.process.Args.Iterator.Windows.init(arena, line);
    defer parsed.deinit();
    for (argv) |expected| try std.testing.expectEqualStrings(expected, parsed.next().?);
    try std.testing.expect(parsed.next() == null);
}
