const std = @import("std");
const manifest = @import("build.zig.zon");

/// The only two values the application is allowed to know about itself both
/// come from `build.zig.zon`, through the generated `build_options` module.
const application_name = @tagName(manifest.name);
const application_version: []const u8 = manifest.version;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // A prompt runs for every command a human types, so the default build is
    // ReleaseFast with debug information stripped: 71 KiB instead of 12 MiB,
    // and 0.7 ms instead of 1.2 ms per prompt. `-Dmode=debug` builds one you can
    // attach a debugger to; `-Dmode=safe` turns the runtime checks on.
    // An explicit switch rather than `standardOptimizeOption`: `zig build` must
    // produce the fast binary by default, and `-Dmode=safe` must really produce
    // one with the runtime safety checks on, which is what audits need.
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

    // `zig build fmt` writes, `zig build fmt:check` only reports: the second is
    // what CI runs.
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

    // A prompt runs on the shell's own stack, so its memory budget is a
    // property of the whole program, not of any one function. A limit of 64 KiB
    // is the smallest a shell may hand us, and the only way to notice a buffer
    // that grew back into the megabytes.
    const stack_step = b.step("stack", "Render under a 64 KiB stack");
    const stack_check = b.addSystemCommand(&.{ "sh", "-c", "ulimit -s 64 && exec \"$0\" render > /dev/null" });
    stack_check.addFileArg(exe.getEmittedBin());
    stack_check.has_side_effects = true;
    stack_step.dependOn(&stack_check.step);

    // The shipping configuration is ReleaseFast, where assertions are gone.
    // Running each command in it catches a program that only works in Debug.
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

    // Coverage needs an unstripped, LLVM-built binary: kcov maps breakpoints
    // through DWARF, which stripping removes.
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

    // kcov matches source paths as substrings, so the pattern needs the trailing
    // separator to avoid matching a sibling directory that merely starts with
    // the same name.
    const include = b.fmt("--include-pattern={s}/", .{source_root});

    // kcov insists on cleaning directories that exist, so create them first.
    // The directory is emptied first: `coverage/merged` from a previous run is
    // itself a merge input, and a stale copy of the source makes the report
    // disagree with the code it claims to measure.
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
    // Every one of these steps writes into the coverage directory: caching them
    // would mean a stale, or empty, report after the directory is removed.
    test_run.has_side_effects = true;

    // The installed binary is traced too: `main` and the real adapters only run
    // when the real process runs.
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
