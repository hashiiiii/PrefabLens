const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Single source of the version is build.zig.zon; inject it into the CLI binary via build options.
    const opts = b.addOptions();
    opts.addOption([]const u8, "version", zon.version);
    const build_options_mod = opts.createModule();

    const core_mod = b.addModule("core", .{
        .root_source_file = b.path("core/src/root.zig"),
        .target = target,
    });

    // Wiring so the mcp parity test can @embedFile the same plane fixture as server.test.ts.
    const plane_before = b.createModule(.{ .root_source_file = b.path("core/src/testdata/plane_before.prefab") });
    const plane_after = b.createModule(.{ .root_source_file = b.path("core/src/testdata/plane_after.prefab") });

    const exe = b.addExecutable(.{
        .name = "prefablens",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core_mod },
                .{ .name = "testdata_plane_before", .module = plane_before },
                .{ .name = "testdata_plane_after", .module = plane_after },
                .{ .name = "build_options", .module = build_options_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the PrefabLens CLI");
    run_step.dependOn(&run_cmd.step);

    const core_tests = b.addTest(.{
        .root_module = core_mod,
    });
    const cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core_mod },
                .{ .name = "testdata_plane_before", .module = plane_before },
                .{ .name = "testdata_plane_after", .module = plane_after },
                .{ .name = "build_options", .module = build_options_mod },
            },
        }),
    });

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
    test_step.dependOn(&b.addRunArtifact(cli_tests).step);

    // MCP protocol smoke against the real binary; exact-match only the static, git-free responses.
    // The tools/list expectation embeds the same tools_list.json as cli/src/mcp.zig.
    const tools_list_json = comptime std.mem.trimEnd(u8, @embedFile("cli/src/tools_list.json"), "\r\n");
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

    const perf_exe = b.addExecutable(.{
        .name = "perf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/src/perf_main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const run_perf = b.addRunArtifact(perf_exe);
    const perf_step = b.step("perf", "Run the performance budget gate (ReleaseFast)");
    perf_step.dependOn(&run_perf.step);

    const wasm = b.addExecutable(.{
        .name = "prefablens",
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/src/wasm.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = .ReleaseSmall,
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    const wasm_step = b.step("wasm", "Build the core as a freestanding WASM library");
    wasm_step.dependOn(&b.addInstallArtifact(wasm, .{}).step);

    const zig_sources = &.{ "build.zig", "core", "cli" };

    const fmt = b.addFmt(.{ .paths = zig_sources });
    const fmt_step = b.step("fmt", "Format Zig sources");
    fmt_step.dependOn(&fmt.step);

    const fmt_check = b.addFmt(.{ .paths = zig_sources, .check = true });
    const lint_step = b.step("lint", "Check Zig source formatting");
    lint_step.dependOn(&fmt_check.step);
}
