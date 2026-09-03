const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Single source of the version is build.zig.zon; inject it into the CLI binary via build options.
    const opts = b.addOptions();
    opts.addOption([]const u8, "version", zon.version);
    const build_options_mod = opts.createModule();

    const test_opts = b.addOptions();
    test_opts.addOption([]const u8, "fixture_root", b.pathFromRoot("core/src/testdata/merge"));
    const readme = b.build_root.handle.readFileAlloc(
        b.graph.io,
        "README.md",
        b.allocator,
        .unlimited,
    ) catch @panic("failed to read README.md");
    test_opts.addOption([]const u8, "readme", readme);
    const test_options_mod = test_opts.createModule();

    const core_mod = b.addModule("core", .{
        .root_source_file = b.path("core/src/root.zig"),
        .target = target,
    });
    const vaxis_dep = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
    const vaxis_mod = vaxis_dep.module("vaxis");
    const cli_imports: []const std.Build.Module.Import = &.{
        .{ .name = "core", .module = core_mod },
        .{ .name = "build_options", .module = build_options_mod },
        .{ .name = "vaxis", .module = vaxis_mod },
    };

    const exe = b.addExecutable(.{
        .name = "prefablens",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = cli_imports,
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
    const cli_test_mod = b.createModule(.{
        .root_source_file = b.path("cli/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = cli_imports,
    });
    // Test fixtures stay explicit so the external-cwd gate cannot read ambient paths.
    cli_test_mod.addImport("test_options", test_options_mod);
    const cli_tests = b.addTest(.{
        .root_module = cli_test_mod,
    });
    const run_cli_tests = b.addRunArtifact(cli_tests);
    run_cli_tests.setCwd(b.path("."));

    const merge_driver_cwd_tests = b.addTest(.{
        .name = "merge-driver-cwd-test",
        .root_module = cli_test_mod,
        .filters = &.{"merge driver: writes automatic and partial results"},
    });
    const run_merge_driver_cwd_tests = b.addRunArtifact(merge_driver_cwd_tests);
    // The global cache is outside the checkout, so this run detects accidental ambient-cwd reads.
    run_merge_driver_cwd_tests.setCwd(.{ .cwd_relative = b.graph.global_cache_root.path.? });

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_merge_driver_cwd_tests.step);

    const git_merge_tests = b.addExecutable(.{
        .name = "git-merge-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/src/git_merge_test_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_git_merge_tests = b.addRunArtifact(git_merge_tests);
    run_git_merge_tests.addArtifactArg(exe);
    test_step.dependOn(&run_git_merge_tests.step);

    const pty_smoke = b.addExecutable(.{
        .name = "pty-smoke-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/src/pty_smoke_test_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_pty_smoke = b.addRunArtifact(pty_smoke);
    run_pty_smoke.addArtifactArg(exe);
    test_step.dependOn(&run_pty_smoke.step);

    const merge_driver_test_step = b.step("test-merge-driver", "Run merge-driver fixture tests outside the checkout");
    merge_driver_test_step.dependOn(&run_merge_driver_cwd_tests.step);

    const merge_tui_tests = b.addTest(.{
        .name = "merge-tui-test",
        .root_module = cli_test_mod,
        .filters = &.{"merge TUI:"},
    });
    const run_merge_tui_tests = b.addRunArtifact(merge_tui_tests);
    run_merge_tui_tests.setCwd(b.path("."));
    const merge_tui_test_step = b.step("test-merge-tui", "Run merge TUI renderer and event tests");
    merge_tui_test_step.dependOn(&run_merge_tui_tests.step);

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

    // The CLI's guid-resolution scan has its own budget: it must stay
    // concurrent (see cli/src/perf_scan_main.zig).
    const perf_scan_exe = b.addExecutable(.{
        .name = "perf-scan",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/src/perf_scan_main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "core", .module = core_mod },
            },
        }),
    });
    perf_step.dependOn(&b.addRunArtifact(perf_scan_exe).step);

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
