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

    const exe = b.addExecutable(.{
        .name = "prefablens",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core_mod },
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
                .{ .name = "build_options", .module = build_options_mod },
            },
        }),
    });

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
    test_step.dependOn(&b.addRunArtifact(cli_tests).step);

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
