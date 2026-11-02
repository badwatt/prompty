const std = @import("std");
const manifest = @import("build.zig.zon");

/// The only two values the application is allowed to know about itself both
/// come from `build.zig.zon`, through the generated `build_options` module.
const application_name = @tagName(manifest.name);
const application_version: []const u8 = manifest.version;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "mode",
        "Optimisation and safety mode: debug, safe, fast (default) or small",
    ) orelse .fast;
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

    const source_paths = [_]std.Build.LazyPath{
        b.path("build.zig"),
        b.path("build.zig.zon"),
        b.path("src"),
        b.path("tools"),
    };
    const fmt_step = b.step("fmt", "Format the sources");
    const fmt = b.addFmt(.{ .paths = &source_paths });
    fmt_step.dependOn(&fmt.step);

    const fmt_check_step = b.step("fmt:check", "Fail if a source is not formatted");
    const fmt_check = b.addFmt(.{ .paths = &source_paths, .check = true });
    fmt_check_step.dependOn(&fmt_check.step);

    const stack_step = b.step("stack", "Render under a 64 KiB stack");
    const stack_check = b.addSystemCommand(&.{ "sh", "-c", "ulimit -s 64 && exec \"$0\" render > /dev/null" });
    stack_check.addFileArg(exe.getEmittedBin());
    stack_check.has_side_effects = true;
    stack_step.dependOn(&stack_check.step);

    const smoke_step = b.step("smoke", "Run every command in the shipping build");
    const smoke = b.addSystemCommand(&.{
        "sh",
        "-c",
        "for arguments in version help theme 'init zsh' 'init bash' 'render --no-color' 'render --shell=zsh' 'render --shell=bash' 'render -d' 'render --duration' 'render --git=false' 'render -g=false' 'render --color=false' 'theme detect'; do " ++
            "\"$0\" $arguments > /dev/null 2>&1 || { echo \"failed: $arguments\"; exit 1; }; done",
    });
    smoke.addFileArg(exe.getEmittedBin());
    smoke.has_side_effects = true;
    smoke_step.dependOn(&smoke.step);

    const layers_step = b.step("layers", "Fail if an import leaves its layer");
    const layers_module = b.createModule(.{
        .root_source_file = b.path("tools/check_layers.zig"),
        .target = b.graph.host,
    });
    const layers_check = b.addExecutable(.{ .name = "check-layers", .root_module = layers_module });
    const layers_run = b.addRunArtifact(layers_check);
    layers_run.has_side_effects = true;
    layers_run.addArg("src");
    layers_step.dependOn(&layers_run.step);

    const comments_step = b.step("comments", "Fail on a plain comment in the source");
    const comments_module = b.createModule(.{
        .root_source_file = b.path("tools/check_comments.zig"),
        .target = b.graph.host,
    });
    const comments_check = b.addExecutable(.{ .name = "check-comments", .root_module = comments_module });
    const comments_run = b.addRunArtifact(comments_check);
    comments_run.has_side_effects = true;
    comments_run.addArg("src");
    comments_run.addArg("tools");
    comments_run.addArg("build.zig");
    comments_step.dependOn(&comments_run.step);

    const run_step = b.step("run", "Run prompty");
    const run_command = b.addRunArtifact(exe);
    run_command.step.dependOn(b.getInstallStep());
    run_command.addPassthruArgs();
    run_step.dependOn(&run_command.step);

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

    const coverage_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .debug,
        .strip = false,
    });
    coverage_module.addOptions("build_options", options);
    const coverage_exe = b.addExecutable(.{
        .name = application_name,
        .root_module = coverage_module,
        .use_llvm = true,
    });

    const coverage_step = b.step("coverage", "Require 100% line coverage via kcov");
    coverage_step.dependOn(addCoverage(b, test_binary, coverage_exe));

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

    const include = b.fmt("--include-pattern={s}/", .{source_root});

    var clear = b.addSystemCommand(&.{ "rm", "-rf" });
    clear.addArg(output_root);
    clear.setName("rm -rf coverage");
    clear.has_side_effects = true;

    var prepare = b.addSystemCommand(&.{"mkdir"});
    prepare.setName("mkdir coverage");
    prepare.step.dependOn(&clear.step);
    prepare.addArg("-p");
    prepare.addArg(b.fmt("{s}/tests", .{output_root}));
    prepare.addArg(b.fmt("{s}/merged", .{output_root}));
    prepare.has_side_effects = true;

    const test_run = b.addSystemCommand(&.{ kcov, "--clean", include, b.fmt("{s}/tests", .{output_root}) });
    test_run.addArtifactArg(test_binary);
    test_run.expectExitCode(0);
    test_run.step.dependOn(&prepare.step);
    test_run.has_side_effects = true;

    const scenarios = [_]Scenario{
        .{ .arguments = &.{"version"} },
        .{ .arguments = &.{"theme"} },
        .{ .arguments = &.{"init"}, .expected_exit = 2 },
        .{ .arguments = &.{ "init", "zsh" } },
        .{ .arguments = &.{ "init", "bash" } },
        .{ .arguments = &.{"nonsense"}, .expected_exit = 2 },
        .{ .arguments = &.{ "render", "--shell=zsh" } },
        .{ .arguments = &.{ "render", "--shell=bash", "--no-color" } },
        .{ .arguments = &.{ "render", "--no-color" } },
        .{ .arguments = &.{ "render", "--wat" }, .expected_exit = 2 },
    };

    var merge = b.addSystemCommand(&.{ kcov, "--merge", b.fmt("{s}/merged", .{output_root}) });
    merge.step.dependOn(&test_run.step);
    merge.has_side_effects = true;
    merge.addArg(b.fmt("{s}/tests", .{output_root}));

    for (scenarios, 0..) |scenario, index| {
        const directory = b.fmt("{s}/scenario-{d}", .{ output_root, index });
        prepare.addArg(directory);

        const run = b.addSystemCommand(&.{ kcov, "--clean", include, directory });
        run.addArtifactArg(exe);
        run.addArgs(scenario.arguments);
        run.expectExitCode(scenario.expected_exit);
        run.step.dependOn(&prepare.step);
        run.has_side_effects = true;
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
    check.has_side_effects = true;
    check.addArg(b.fmt("{s}/merged/kcov-merged/coverage.json", .{output_root}));
    check.addArg(source_root);
    return &check.step;
}

const Scenario = struct {
    arguments: []const []const u8,
    expected_exit: u8 = 0,
};
