const std = @import("std");
const manifest = @import("build.zig.zon");

/// The only two values the application is allowed to know about itself both
/// come from `build.zig.zon`, through the generated `build_options` module.
const application_name = @tagName(manifest.name);
const application_version: []const u8 = manifest.version;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // ReleaseFast by default: a prompt runs for every command a human types, so
    // an unoptimised default would be a trap.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .fast });
    const strip = b.option(
        bool,
        "strip",
        "Omit debug information from the installed binary",
    ) orelse (optimize != .debug);

    const options = b.addOptions();
    options.addOption([]const u8, "name", application_name);
    options.addOption([]const u8, "version", application_version);

    const application_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    application_module.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = application_name,
        .root_module = application_module,
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run prompty");
    const run_command = b.addRunArtifact(exe);
    run_command.step.dependOn(b.getInstallStep());
    run_command.addPassthruArgs();
    run_step.dependOn(&run_command.step);

    // Tests are always Debug and always LLVM: kcov reads the DWARF that the
    // self-hosted backend does not emit for user files.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = .debug,
    });
    test_module.addOptions("build_options", options);

    const test_binary = b.addTest(.{
        .name = application_name ++ "-tests",
        .root_module = test_module,
        .use_llvm = true,
    });
    const run_tests = b.addRunArtifact(test_binary);
    const test_step = b.step("test", "Run the unit and integration tests");
    test_step.dependOn(&run_tests.step);

    const coverage_step = b.step("coverage", "Require 100% line coverage via kcov");
    coverage_step.dependOn(addCoverage(b, test_binary, exe));

    const bench_step = b.step("bench", "Measure the wall clock cost of a render");
    const bench_module = b.createModule(.{
        .root_source_file = b.path("tools/bench.zig"),
        .target = b.graph.host,
    });
    const bench = b.addExecutable(.{ .name = "bench", .root_module = bench_module });
    const run_bench = b.addRunArtifact(bench);
    run_bench.step.dependOn(b.getInstallStep());
    run_bench.addPassthruArgs();
    bench_step.dependOn(&run_bench.step);
    bench_step.dependOn(&exe.step);
}

fn addCoverage(b: *std.Build, test_binary: *std.Build.Step.Compile, exe: *std.Build.Step.Compile) *std.Build.Step {
    const kcov = b.option([]const u8, "kcov", "Path to the kcov binary") orelse "kcov";
    const source_root = b.root.joinString(b.allocator, "src") catch @panic("OOM");
    const output_root = b.root.joinString(b.allocator, "coverage") catch @panic("OOM");

    // kcov matches source paths as substrings, so the pattern needs the trailing
    // separator to avoid matching a sibling directory that merely starts with
    // the same name.
    const include = b.fmt("--include-pattern={s}/", .{source_root});

    const test_run = b.addSystemCommand(&.{ kcov, "--clean", include, b.fmt("{s}/tests", .{output_root}) });
    test_run.addArtifactArg(test_binary);
    test_run.expectExitCode(0);

    // The installed binary is traced too: `main` and the real adapters only run
    // when the real process runs.
    const scenarios = [_]Scenario{
        .{ .arguments = &.{"version"} },
        .{ .arguments = &.{"theme"} },
        .{ .arguments = &.{"init"} },
        .{ .arguments = &.{ "init", "zsh" } },
        .{ .arguments = &.{ "init", "bash" } },
        .{ .arguments = &.{"nonsense"} },
        .{ .arguments = &.{ "render", "--shell=zsh" } },
        .{ .arguments = &.{ "render", "--shell=bash", "--no-color" } },
        .{ .arguments = &.{ "render", "--no-color" } },
        .{ .arguments = &.{ "render", "--wat" } },
    };

    var merge = b.addSystemCommand(&.{ kcov, "--merge", b.fmt("{s}/merged", .{output_root}) });
    merge.step.dependOn(&test_run.step);
    merge.addArg(b.fmt("{s}/tests", .{output_root}));

    for (scenarios, 0..) |scenario, index| {
        const directory = b.fmt("{s}/scenario-{d}", .{ output_root, index });
        const run = b.addSystemCommand(&.{ kcov, "--clean", include, directory });
        run.addArtifactArg(exe);
        run.addArgs(scenario.arguments);
        run.expectExitCode(scenario.expected_exit);
        merge.step.dependOn(&run.step);
        merge.addArg(directory);
    }

    const checker_module = b.createModule(.{
        .root_source_file = b.path("tools/check_coverage.zig"),
        .target = b.graph.host,
    });
    const checker = b.addExecutable(.{ .name = "check-coverage", .root_module = checker_module });
    const check = b.addRunArtifact(checker);
    check.step.dependOn(&merge.step);
    check.addArg(b.fmt("{s}/merged/coverage.json", .{output_root}));
    check.addArg(source_root);
    return &check.step;
}

const Scenario = struct {
    arguments: []const []const u8,
    expected_exit: u8 = 0,
};
