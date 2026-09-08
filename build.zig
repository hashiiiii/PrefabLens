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
    const strategy_script = b.addInstallBinFile(b.path("cli/bin/git-merge-prefablens"), "git-merge-prefablens");
    b.getInstallStep().dependOn(&strategy_script.step);
    const installed_strategy_script = b.getInstallPath(.bin, "git-merge-prefablens");

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the PrefabLens CLI");
    run_step.dependOn(&run_cmd.step);

    const core_tests = b.addTest(.{
        .name = "core-test",
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
        .name = "cli-test",
        .root_module = cli_test_mod,
    });
    const run_cli_tests = b.addRunArtifact(cli_tests);
    run_cli_tests.setCwd(b.path("."));
    run_cli_tests.setEnvironmentVariable("GIT_CONFIG_COUNT", "1");
    run_cli_tests.setEnvironmentVariable("GIT_CONFIG_KEY_0", "merge.conflictStyle");
    run_cli_tests.setEnvironmentVariable("GIT_CONFIG_VALUE_0", "merge");

    const merge_driver_cwd_tests = b.addTest(.{
        .name = "merge-driver-cwd-test",
        .root_module = cli_test_mod,
        .filters = &.{"merge driver: writes automatic results and marker fallback"},
    });
    const run_merge_driver_cwd_tests = b.addRunArtifact(merge_driver_cwd_tests);
    // The global cache is outside the checkout, so this run detects accidental ambient-cwd reads.
    run_merge_driver_cwd_tests.setCwd(.{ .cwd_relative = b.graph.global_cache_root.path.? });
    run_merge_driver_cwd_tests.setEnvironmentVariable("GIT_CONFIG_COUNT", "1");
    run_merge_driver_cwd_tests.setEnvironmentVariable("GIT_CONFIG_KEY_0", "merge.conflictStyle");
    run_merge_driver_cwd_tests.setEnvironmentVariable("GIT_CONFIG_VALUE_0", "merge");

    const test_step = b.step("test", "Run native unit and integration tests");
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_merge_driver_cwd_tests.step);

    const diff_driver_tests = b.addExecutable(.{
        .name = "git-diff-driver-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/src/diff_driver_test_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_diff_driver_tests = b.addRunArtifact(diff_driver_tests);
    run_diff_driver_tests.addArtifactArg(exe);
    run_diff_driver_tests.addArg(b.pathFromRoot("core/src/testdata"));
    test_step.dependOn(&run_diff_driver_tests.step);
    const diff_driver_test_step = b.step("test-diff-driver", "Run Git external diff driver integration tests");
    diff_driver_test_step.dependOn(&run_diff_driver_tests.step);

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

    const collection_fixture_tests = b.addExecutable(.{
        .name = "collection-fixture-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/src/collection_fixture_test_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "core", .module = core_mod }},
        }),
    });
    const run_collection_fixture_tests = b.addRunArtifact(collection_fixture_tests);
    run_collection_fixture_tests.addArg(b.pathFromRoot("core/src/testdata/collections"));
    if (b.args) |args| run_collection_fixture_tests.addArgs(args);
    test_step.dependOn(&run_collection_fixture_tests.step);
    const collection_test_step = b.step("test-collection-fixtures", "Check collection fixtures and optionally export Unity inputs");
    collection_test_step.dependOn(&run_collection_fixture_tests.step);

    const strategy_tests = b.addExecutable(.{
        .name = "git-strategy-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/src/git_strategy_test_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = build_options_mod },
            },
        }),
    });
    const run_strategy_tests = b.addRunArtifact(strategy_tests);
    run_strategy_tests.addArtifactArg(exe);
    run_strategy_tests.addArg(installed_strategy_script);
    run_strategy_tests.addArg(b.pathFromRoot("core/src/testdata/collections"));
    if (b.args) |args| run_strategy_tests.addArgs(args);
    run_strategy_tests.step.dependOn(&strategy_script.step);
    test_step.dependOn(&run_strategy_tests.step);
    const strategy_test_step = b.step("test-merge-strategy", "Run the native Git strategy integration tests");
    strategy_test_step.dependOn(&run_strategy_tests.step);

    const setup_tests = b.addExecutable(.{
        .name = "merge-setup-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/src/merge_setup_test_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_setup_tests = b.addRunArtifact(setup_tests);
    run_setup_tests.addArtifactArg(exe);
    run_setup_tests.addArg(installed_strategy_script);
    run_setup_tests.step.dependOn(&strategy_script.step);
    test_step.dependOn(&run_setup_tests.step);
    const setup_test_step = b.step("test-merge-setup", "Run merge setup scope integration tests");
    setup_test_step.dependOn(&run_setup_tests.step);

    // Real alternate-release commands expose mixed installations without a runtime version override.
    const alternate_opts = b.addOptions();
    alternate_opts.addOption([]const u8, "version", zon.version ++ "-installation-test");
    const alternate_imports: []const std.Build.Module.Import = &.{
        .{ .name = "core", .module = core_mod },
        .{ .name = "build_options", .module = alternate_opts.createModule() },
        .{ .name = "vaxis", .module = vaxis_mod },
    };
    const alternate_exe = b.addExecutable(.{
        .name = "prefablens",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = alternate_imports,
        }),
    });
    const installation_tests = b.addExecutable(.{
        .name = "cli-installation-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/src/installation_test_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_installation_tests = b.addRunArtifact(installation_tests);
    run_installation_tests.addArtifactArg(exe);
    run_installation_tests.addArg(installed_strategy_script);
    run_installation_tests.addArtifactArg(alternate_exe);
    run_installation_tests.step.dependOn(&strategy_script.step);
    test_step.dependOn(&run_installation_tests.step);
    const installation_test_step = b.step("test-cli-installation", "Run native CLI installation integration tests");
    installation_test_step.dependOn(&run_installation_tests.step);

    const installation_binaries_step = b.step("test-installation-binaries", "Install two native releases for installation tests");
    installation_binaries_step.dependOn(b.getInstallStep());
    installation_binaries_step.dependOn(&b.addInstallArtifact(alternate_exe, .{
        .dest_dir = .{ .override = .{ .custom = "test-alternate-bin" } },
    }).step);

    const structural_tests = b.addExecutable(.{
        .name = "git-structural-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/src/git_structural_test_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_structural_tests = b.addRunArtifact(structural_tests);
    run_structural_tests.addArtifactArg(exe);
    run_structural_tests.addArg(installed_strategy_script);
    run_structural_tests.step.dependOn(&strategy_script.step);
    test_step.dependOn(&run_structural_tests.step);
    const structural_test_step = b.step("test-merge-structural", "Run structural Unity merge integration tests");
    structural_test_step.dependOn(&run_structural_tests.step);

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
    const pty_test_step = b.step("test-merge-pty", "Run merge interaction tests in a real terminal");
    pty_test_step.dependOn(&run_pty_smoke.step);

    for ([_]*std.Build.Step.Run{
        run_git_merge_tests,
        run_collection_fixture_tests,
        run_strategy_tests,
        run_setup_tests,
        run_installation_tests,
        run_structural_tests,
        run_pty_smoke,
        run_diff_driver_tests,
    }) |run| {
        // Independent scratch directories let these checks share the build without inherited stdio.
        run.expectExitCode(0);
        // Git and terminal checks must execute even when compilation inputs are cached.
        run.has_side_effects = true;
    }

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

    // The CLI's GUID scan has a separate budget to catch regressions in its
    // concurrent file reads (see cli/src/perf_scan_main.zig).
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
    // Finish both builds before measuring, then run the benchmarks sequentially
    // so compilation and the GUID scan cannot contend with the diff samples.
    run_perf.step.dependOn(&perf_scan_exe.step);
    const run_perf_scan = b.addRunArtifact(perf_scan_exe);
    run_perf_scan.step.dependOn(&run_perf.step);
    perf_step.dependOn(&run_perf_scan.step);

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
