//! The compose use case: gather facts through the ports, then hand a view model
//! to the domain renderer.
//!
//! Everything here is bounded. There is no allocation, no subprocess and no
//! unbounded loop, so the cost of a render depends only on how many files the
//! prompt has to look at, never on how big they are.

const std = @import("std");

const cache_mod = @import("../domain/cache.zig");
const canvas = @import("../domain/canvas.zig");
const clock_mod = @import("../domain/clock.zig");
const git_mod = @import("../domain/git.zig");
const git_status_mod = @import("../domain/git_status.zig");
const osc_mod = @import("../domain/osc.zig");
const path_mod = @import("../domain/path.zig");
const prompt = @import("../domain/prompt.zig");
const store_mod = @import("../domain/store.zig");
const theme_mod = @import("../domain/theme.zig");
const ports = @import("../ports/host.zig");
const repository = @import("repository.zig");

pub const Options = struct {
    shell: canvas.Shell = .plain,
    color: bool = true,
    keep_components: u8 = 3,
    /// Ask git for the working tree status. One process, once per prompt, only
    /// inside a repository. Turn it off for the absolute fastest path.
    git: bool = true,
    /// Show the last command's duration against the right edge of the terminal
    /// instead of dimmed after the pill.
    duration: bool = false,
};

pub const max_duration_ms: u64 = 24 * 60 * 60 * 1000;

pub fn build(host: ports.Host, store: *store_mod.Store, options: Options) prompt.Model {
    std.debug.assert(options.keep_components > 0);

    var model = prompt.Model{
        .theme = themeFor(host),
        .shell = options.shell,
        .color = options.color and colorAllowed(host),
        .path = "/",
    };
    if (host.environ.get("USER") orelse host.environ.get("LOGNAME")) |user| {
        model.user = store.dupeDisplay(user, prompt.max_user_bytes);
    }
    model.is_root = host.user_id == 0;

    var working_directory_buffer: [path_mod.max_display_bytes]u8 = undefined;
    const working_directory = workingDirectory(host, &working_directory_buffer);

    // The repository is looked up before the path is formatted: inside one, the
    // label is anchored on its name rather than on home. Both the root and the
    // git directory borrow this buffer, so it lives here, in the caller.
    var git_dir_buffer: [path_mod.scratch_bytes]u8 = undefined;
    const found_repository = repository.probe(host, working_directory, store, &git_dir_buffer);
    if (found_repository) |found| {
        model.git = found.git;
        const mode = statusMode(host, options.git);
        if (mode != .off) {
            if (readStatus(host, mode)) |report| {
                model.git = withStatus(found.git, report, store);
            }
        }
        if (repository.hasStash(host, found.git_dir)) model.git.?.status.stashed = 1;
    }

    var display_buffer: [path_mod.max_display_bytes]u8 = undefined;
    model.path = store.dupePrintable(path_mod.display(&display_buffer, .{
        .cwd = working_directory,
        .home = host.environ.get("HOME") orelse "",
        .repository_root = if (found_repository) |found| found.root else null,
        .keep = options.keep_components,
    }));

    const unix_seconds = host.clock.now();
    model.time = clock_mod.fromUnix(unix_seconds, host.clock.offsetAt(unix_seconds));
    model.duration_ms = parseDuration(host);
    // A right edge to put it on exists in one shell: zsh's `RPROMPT`. Anywhere
    // else the same number goes inline, which is what those shells can draw.
    if (options.duration and options.shell == .zsh) model.duration_placement = .right;
    model.exit_code = parseExitCode(host);
    model.direnv = direnvActive(host);
    return model;
}

pub fn themeFor(host: ports.Host) theme_mod.Theme {
    return theme_mod.Theme.derive(background(host));
}

/// The background precedence, in order: an explicit override, the colour
/// detected once and remembered, then the tuned default.
pub fn background(host: ports.Host) theme_mod.Rgb {
    if (host.environ.get("PROMTY_BACKGROUND")) |configured| {
        if (theme_mod.Rgb.parse(configured)) |color| return color;
    }
    return cachedBackground(host) orelse theme_mod.Theme.default_background;
}

pub fn cachedBackground(host: ports.Host) ?theme_mod.Rgb {
    var path_buffer: [cache_mod.max_path_bytes]u8 = undefined;
    const location = cache_mod.path(
        &path_buffer,
        host.environ.get("XDG_CACHE_HOME"),
        host.environ.get("HOME"),
    ) orelse return null;
    var contents: [64]u8 = undefined;
    const stored = host.files.read(location, &contents) orelse return null;
    return theme_mod.Rgb.parse(std.mem.trim(u8, stored, " \t\r\n"));
}

/// Asks the terminal for its background. This is the only code path in prompty
/// that waits for the terminal, and it is never on the prompt path.
pub fn detectBackground(host: ports.Host) ?theme_mod.Rgb {
    var response_buffer: [128]u8 = undefined;
    const response = host.terminal.background(&response_buffer) orelse return null;
    return osc_mod.parseBackground(response);
}

pub fn rememberBackground(host: ports.Host, color: theme_mod.Rgb) bool {
    var path_buffer: [cache_mod.max_path_bytes]u8 = undefined;
    const location = cache_mod.path(
        &path_buffer,
        host.environ.get("XDG_CACHE_HOME"),
        host.environ.get("HOME"),
    ) orelse return false;
    var line: [8]u8 = undefined;
    const contents = std.fmt.bufPrint(&line, "#{x:0>2}{x:0>2}{x:0>2}\n", .{
        color.r,
        color.g,
        color.b,
    }) catch return false;
    return host.files.write(location, contents);
}

/// How much `git status` is allowed to cost.
pub const StatusMode = enum {
    /// Branch, working tree, untracked files and upstream divergence.
    full,
    /// Skips the untracked walk and the commit-graph walk for divergence: in a
    /// repository with five thousand files and five hundred untracked ones,
    /// measured at 8.4 ms against 5.7 ms. It costs the `?` and the arrows.
    fast,
    /// No subprocess at all; the branch comes from `.git/HEAD`.
    off,
};

/// `git status` is the one subprocess a prompt may run, and it is most of what
/// a render costs, so it is worth asking how much of it the user wants.
fn statusMode(host: ports.Host, enabled: bool) StatusMode {
    if (!enabled) return .off;
    const value = host.environ.get("PROMTY_GIT") orelse return .full;
    if (std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "false")) return .off;
    if (std.mem.eql(u8, value, "fast")) return .fast;
    return .full;
}

/// The porcelain output carries the branch too, so it wins when available: one
/// source of truth per render beats two that can disagree.
fn withStatus(base: prompt.Git, report: git_status_mod.Report, store: *store_mod.Store) prompt.Git {
    var git = base;
    if (report.branch) |branch| {
        git.branch = store.dupePrintable(branch);
    } else if (report.detached) {
        if (report.commit) |commit| git.branch = store.dupePrintable(git_mod.short(commit));
    }
    git.status = report.status;
    return git;
}

/// Enough for a few thousand changed files. Larger output cannot be parsed
/// halfway, so the read fails cleanly and the prompt falls back to the branch,
/// which is what a repository with fifteen thousand open changes deserves.
///
/// Static rather than on the stack: a prompt runs on the shell's own stack, and
/// a quarter of a megabyte there is enough to make `ulimit -s 256` a segfault in
/// the middle of someone's prompt. Nothing here is reentrant — the process
/// renders one prompt and exits.
var status_output: [256 * 1024]u8 = undefined;

fn readStatus(host: ports.Host, mode: StatusMode) ?git_status_mod.Report {
    const full = [_][:0]const u8{
        "git",
        "--no-optional-locks",
        "status",
        "--porcelain=v2",
        "--branch",
        "--untracked-files=normal",
        "-z",
    };
    const fast = [_][:0]const u8{
        "git",
        "--no-optional-locks",
        "status",
        "--porcelain=v2",
        "--branch",
        "--untracked-files=no",
        "--no-ahead-behind",
        "-z",
    };
    const argv: []const [:0]const u8 = switch (mode) {
        .fast => &fast,
        .full, .off => &full,
    };
    const records = host.commands.run(argv, &status_output) orelse return null;
    return git_status_mod.parse(records);
}

fn colorAllowed(host: ports.Host) bool {
    if (host.environ.get("NO_COLOR") != null) return false;
    if (host.environ.get("TERM")) |term| {
        if (std.mem.eql(u8, term, "dumb")) return false;
    }
    return true;
}

/// `$PWD` is free and always right for an interactive shell; `getcwd` is the
/// fallback for everything else.
fn workingDirectory(host: ports.Host, buffer: []u8) []const u8 {
    if (host.environ.get("PWD")) |pwd| {
        if (pwd.len > 0 and pwd[0] == '/') return pwd;
    }
    return host.files.currentDir(buffer) orelse "/";
}

fn parseDuration(host: ports.Host) ?u64 {
    const raw = host.environ.get("PROMTY_LAST_DURATION_MS") orelse return null;
    const milliseconds = std.fmt.parseInt(u64, raw, 10) catch return null;
    if (milliseconds == 0) return null;
    if (milliseconds > max_duration_ms) return null;
    return milliseconds;
}

fn parseExitCode(host: ports.Host) ?u8 {
    const raw = host.environ.get("PROMTY_LAST_EXIT") orelse return null;
    return std.fmt.parseInt(u8, raw, 10) catch null;
}

fn direnvActive(host: ports.Host) bool {
    const diff = host.environ.get("DIRENV_DIFF") orelse return false;
    return diff.len > 0;
}

// ---------------------------------------------------------------------------
// Integration tests: the whole use case, driven through the ports with a fake
// filesystem, clock, terminal and environment.
// ---------------------------------------------------------------------------

const fakes = @import("../test_support/fakes.zig");

const project_directories = [_][]const u8{"/home/dev/proj"};

const project_sources = [_]fakes.FakeFiles.File{
    .{ .path = "/home/dev/proj/.git/HEAD", .contents = "ref: refs/heads/main\n" },
};

const FakeHarness = struct {
    files: fakes.FakeFiles,
    environment: fakes.FakeEnv,
    clock: fakes.FakeClock = .{},
    terminal: fakes.FakeTerminal = .{},
    host: fakes.FakeHost,
    store: store_mod.Store = undefined,

    fn init(environment: []const [2][]const u8) FakeHarness {
        var harness = FakeHarness{
            .files = fakes.FakeFiles.withDirectories(&project_sources, &project_directories),
            .environment = fakes.FakeEnv.init(environment),
            .host = undefined,
        };
        harness.host = .{
            .files = harness.files,
            .environment = harness.environment,
            .clock = harness.clock,
            .terminal = harness.terminal,
        };
        harness.store.reset();
        return harness;
    }

    fn model(self: *FakeHarness, options: Options) prompt.Model {
        return build(self.host.host(), &self.store, options);
    }
};

const default_environment = [_][2][]const u8{
    .{ "USER", "dev" },
    .{ "HOME", "/home/dev" },
    .{ "PWD", "/home/dev/proj" },
};

test "collects every fact from a fake project" {
    var harness = FakeHarness.init(&default_environment);
    const model = harness.model(.{});

    try std.testing.expectEqualStrings("dev", model.user.?);
    try std.testing.expect(!model.is_root);
    // Inside a repository the label is anchored on the repository name, so the
    // home prefix is replaced by the truncation symbol.
    try std.testing.expectEqualStrings("…/proj", model.path);
    try std.testing.expectEqualStrings("main", model.git.?.branch);
    try std.testing.expectEqual(git_mod.Operation.none, model.git.?.operation);
}

test "the right edge is zsh's, so only zsh gets it" {
    // RPROMPT is the only mechanism that keeps the cursor after the chevron
    // while putting the number at the edge. bash and the plain output have
    // none, so the same option leaves the duration where they can draw it.
    const environment = default_environment ++ [_][2][]const u8{
        .{ "PROMTY_LAST_DURATION_MS", "1234" },
    };
    for ([_]canvas.Shell{ .zsh, .bash, .plain }) |shell| {
        var harness = FakeHarness.init(&environment);
        const model = harness.model(.{ .duration = true, .shell = shell });
        const expected: prompt.DurationPlacement =
            if (shell == .zsh) .right else .line;
        try std.testing.expectEqual(expected, model.duration_placement);
        try std.testing.expectEqual(@as(?u64, 1_234), model.duration_ms);
    }
}

test "without the option the duration stays on the line" {
    var harness = FakeHarness.init(&(default_environment ++ [_][2][]const u8{
        .{ "PROMTY_LAST_DURATION_MS", "1234" },
    }));
    const model = harness.model(.{});
    try std.testing.expectEqual(prompt.DurationPlacement.line, model.duration_placement);
}

test "an absurdly long user name cannot take over the line" {
    // `$USER` is whatever the parent process left there. The store and the
    // canvas now stop at their bounds, but a name that long would still push
    // the path, the branch and the clock off the line.
    const long_name: [1000]u8 = @splat('u');
    var harness = FakeHarness.init(&.{
        .{ "USER", &long_name },
        .{ "HOME", "/home/dev" },
        .{ "PWD", "/home/dev/proj" },
    });
    const model = harness.model(.{});
    try std.testing.expectEqual(prompt.max_user_bytes, model.user.?.len);
    try std.testing.expectEqualStrings("…/proj", model.path);
}

test "a root shell is marked and can be rendered" {
    var harness = FakeHarness.init(&default_environment);
    harness.host.user_id = 0;
    const model = harness.model(.{ .color = false, .shell = .plain });
    try std.testing.expect(model.is_root);

    var buffer: [canvas.Canvas.capacity]u8 = undefined;
    const rendered = prompt.render(&model, &buffer).line;
    try std.testing.expect(std.mem.indexOf(u8, rendered, " dev ") != null);
}

test "the working directory falls back to getcwd and then to root" {
    {
        // A relative PWD is not trustworthy, so the filesystem is asked.
        var harness = FakeHarness.init(&.{.{ "HOME", "/home/dev" }});
        harness.host.files.directories = &.{};
        try std.testing.expectEqualStrings("/", harness.model(.{}).path);
    }
    {
        const directories = [_][]const u8{"/home/dev/scratch"};
        var harness = FakeHarness.init(&.{ .{ "HOME", "/home/dev" }, .{ "PWD", "relative" } });
        harness.host.files.directories = &directories;
        try std.testing.expectEqualStrings("~/scratch", harness.model(.{}).path);
    }
}

test "repository state is read from marker files" {
    const sources = [_]fakes.FakeFiles.File{
        .{ .path = "/home/dev/proj/.git/HEAD", .contents = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678\n" },
        .{ .path = "/home/dev/proj/.git/rebase-merge/head-name", .contents = "refs/heads/topic\n" },
    };
    const directories = [_][]const u8{
        "/home/dev/proj",
        "/home/dev/proj/.git/rebase-merge",
    };
    var harness = FakeHarness.init(&default_environment);
    harness.host.files.sources = &sources;
    harness.host.files.directories = &directories;

    const model = harness.model(.{});
    try std.testing.expectEqualStrings("a1b2c3d", model.git.?.branch);
    try std.testing.expectEqual(git_mod.Operation.rebase, model.git.?.operation);
}

test "worktrees find their git directory through the gitfile" {
    const sources = [_]fakes.FakeFiles.File{
        .{ .path = "/home/dev/wt/.git", .contents = "gitdir: /home/dev/proj/.git/worktrees/wt\n" },
        .{ .path = "/home/dev/proj/.git/worktrees/wt/HEAD", .contents = "ref: refs/heads/wt\n" },
        .{ .path = "/home/dev/proj/.git/worktrees/wt/MERGE_HEAD", .contents = "abc\n" },
    };
    var harness = FakeHarness.init(&default_environment);
    harness.host.files.sources = &sources;
    harness.host.environment = .{ .entries = &.{
        .{ "HOME", "/home/dev" },
        .{ "PWD", "/home/dev/wt" },
    } };

    const model = harness.model(.{});
    try std.testing.expectEqualStrings("wt", model.git.?.branch);
    try std.testing.expectEqual(git_mod.Operation.merge, model.git.?.operation);
}

test "a relative gitfile resolves against its own directory" {
    const sources = [_]fakes.FakeFiles.File{
        .{ .path = "/home/dev/sub/.git", .contents = "gitdir: ../.git/modules/sub\n" },
        .{ .path = "/home/dev/sub/../.git/modules/sub/HEAD", .contents = "ref: refs/heads/sub\n" },
    };
    var harness = FakeHarness.init(&default_environment);
    harness.host.files.sources = &sources;
    harness.host.environment = .{ .entries = &.{
        .{ "HOME", "/home/dev" },
        .{ "PWD", "/home/dev/sub" },
    } };

    // The fake filesystem does not normalise paths, so the literal join is what
    // must be requested.
    const model = harness.model(.{});
    try std.testing.expectEqualStrings("sub", model.git.?.branch);
}

test "walking up finds an enclosing repository" {
    const sources = [_]fakes.FakeFiles.File{
        .{ .path = "/home/dev/big/.git/HEAD", .contents = "ref: refs/heads/mono\n" },
    };
    var harness = FakeHarness.init(&default_environment);
    harness.host.files.sources = &sources;
    harness.host.environment = .{ .entries = &.{
        .{ "HOME", "/home/dev" },
        .{ "PWD", "/home/dev/big/a/b/c" },
    } };
    const model = harness.model(.{});
    try std.testing.expectEqualStrings("mono", model.git.?.branch);
}

test "no repository means no git segment" {
    var harness = FakeHarness.init(&default_environment);
    harness.host.files.sources = &.{};
    try std.testing.expectEqual(@as(?prompt.Git, null), harness.model(.{}).git);
}

test "the clock is read through the port" {
    var harness = FakeHarness.init(&default_environment);
    harness.host.clock = .{ .unix_seconds = 0, .offset_seconds = 3_600 };
    const model = harness.model(.{});
    try std.testing.expectEqual(@as(u8, 1), model.time.?.hour);
    try std.testing.expectEqual(@as(u8, 0), model.time.?.minute);
}

test "duration and exit status are read from the shell's environment" {
    {
        var harness = FakeHarness.init(&(default_environment ++ [_][2][]const u8{
            .{ "PROMTY_LAST_DURATION_MS", "1234" },
            .{ "PROMTY_LAST_EXIT", "130" },
        }));
        const model = harness.model(.{});
        try std.testing.expectEqual(@as(?u64, 1_234), model.duration_ms);
        try std.testing.expectEqual(@as(?u8, 130), model.exit_code);
    }
    {
        // Zero, junk and absurd durations are all ignored.
        var harness = FakeHarness.init(&(default_environment ++ [_][2][]const u8{
            .{ "PROMTY_LAST_DURATION_MS", "0" },
            .{ "PROMTY_LAST_EXIT", "not-a-code" },
        }));
        const model = harness.model(.{});
        try std.testing.expectEqual(@as(?u64, null), model.duration_ms);
        try std.testing.expectEqual(@as(?u8, null), model.exit_code);
    }
    {
        var harness = FakeHarness.init(&(default_environment ++ [_][2][]const u8{
            .{ "PROMTY_LAST_DURATION_MS", "999999999999" },
        }));
        try std.testing.expectEqual(@as(?u64, null), harness.model(.{}).duration_ms);
    }
}

test "direnv is visible without running it" {
    var harness = FakeHarness.init(&(default_environment ++ [_][2][]const u8{
        .{ "DIRENV_DIFF", "eJx..." },
    }));
    try std.testing.expect(harness.model(.{}).direnv);

    // An empty diff means direnv did nothing here.
    var idle = FakeHarness.init(&(default_environment ++ [_][2][]const u8{
        .{ "DIRENV_DIFF", "" },
    }));
    try std.testing.expect(!idle.model(.{}).direnv);
}

test "colour is disabled by NO_COLOR and by a dumb terminal" {
    var plain = FakeHarness.init(&(default_environment ++ [_][2][]const u8{.{ "NO_COLOR", "1" }}));
    try std.testing.expect(!plain.model(.{}).color);

    var dumb = FakeHarness.init(&(default_environment ++ [_][2][]const u8{.{ "TERM", "dumb" }}));
    try std.testing.expect(!dumb.model(.{}).color);

    var colourful = FakeHarness.init(&(default_environment ++ [_][2][]const u8{.{ "TERM", "xterm-256color" }}));
    try std.testing.expect(colourful.model(.{}).color);

    // The caller can also turn colour off explicitly.
    try std.testing.expect(!colourful.model(.{ .color = false }).color);
}

const default_theme_background = theme_mod.Theme.default_background;
const light_background = theme_mod.Rgb{ .r = 0xf5, .g = 0xf5, .b = 0xf5 };

test "the background comes from an override, then the cache, then the default" {
    {
        var harness = FakeHarness.init(&(default_environment ++ [_][2][]const u8{
            .{ "PROMTY_BACKGROUND", "#f5f5f5" },
        }));
        try std.testing.expectEqual(light_background, background(harness.host.host()));
    }
    {
        // An override that is not a colour is ignored, not fatal.
        var harness = FakeHarness.init(&(default_environment ++ [_][2][]const u8{
            .{ "PROMTY_BACKGROUND", "bright-green" },
        }));
        try std.testing.expectEqual(default_theme_background, background(harness.host.host()));
    }
    {
        var harness = FakeHarness.init(&(default_environment ++ [_][2][]const u8{
            .{ "XDG_CACHE_HOME", "/cache" },
        }));
        harness.host.files.sources = &.{
            .{ .path = "/cache/prompty/theme", .contents = "#f5f5f5\n" },
        };
        try std.testing.expectEqual(light_background, background(harness.host.host()));
        try std.testing.expectEqual(light_background, cachedBackground(harness.host.host()).?);
    }
    {
        // A cache file with junk in it falls back to the default.
        var harness = FakeHarness.init(&default_environment);
        harness.host.files.sources = &.{
            .{ .path = "/home/dev/.cache/prompty/theme", .contents = "not a colour" },
        };
        try std.testing.expectEqual(default_theme_background, background(harness.host.host()));
    }
    {
        // No HOME and no XDG_CACHE_HOME: nothing to read.
        var harness = FakeHarness.init(&.{});
        try std.testing.expectEqual(default_theme_background, background(harness.host.host()));
        try std.testing.expectEqual(@as(?theme_mod.Rgb, null), cachedBackground(harness.host.host()));
    }
}

test "detection asks the terminal and the answer is remembered" {
    var harness = FakeHarness.init(&(default_environment ++ [_][2][]const u8{
        .{ "XDG_CACHE_HOME", "/cache" },
    }));
    harness.host.terminal = .{ .response = "\x1b]11;rgb:1e1e/1e1e/2e2e\x1b\\" };

    const detected = detectBackground(harness.host.host()).?;
    try std.testing.expectEqual(default_theme_background, detected);

    try std.testing.expect(rememberBackground(harness.host.host(), detected));
    try std.testing.expectEqual(@as(usize, 1), harness.host.files.write_count);
    try std.testing.expectEqualStrings("/cache/prompty/theme", harness.host.files.written[0].path);
    try std.testing.expectEqualStrings("#1e1e2e\n", harness.host.files.written[0].bytes);
}

test "detection fails cleanly and is not remembered without a cache location" {
    var harness = FakeHarness.init(&.{});
    try std.testing.expectEqual(@as(?theme_mod.Rgb, null), detectBackground(harness.host.host()));

    harness.host.terminal = .{ .response = "garbage" };
    try std.testing.expectEqual(@as(?theme_mod.Rgb, null), detectBackground(harness.host.host()));

    try std.testing.expect(!rememberBackground(harness.host.host(), default_theme_background));
}

const status_porcelain =
    "# branch.oid 1cec0eae51f1f82b5bb5290d9309f73728b04aba\x00" ++
    "# branch.head main\x00" ++
    "# branch.upstream origin/main\x00" ++
    "# branch.ab +2 -1\x00" ++
    "1 .M N... 100644 100644 100644 aaaaaaa aaaaaaa src/modified.zig\x00" ++
    "1 M. N... 100644 100644 100644 aaaaaaa aaaaaaa src/staged.zig\x00" ++
    "1 .D N... 100644 100644 000000 aaaaaaa aaaaaaa src/deleted.zig\x00" ++
    "? src/untracked.zig\x00";

test "the working tree status comes from one git invocation" {
    var harness = FakeHarness.init(&default_environment);
    harness.host.commands.response = status_porcelain;

    const model = harness.model(.{});
    const git = model.git.?;

    try std.testing.expectEqualStrings("main", git.branch);
    try std.testing.expectEqual(@as(u16, 1), git.status.modified);
    try std.testing.expectEqual(@as(u16, 1), git.status.staged);
    try std.testing.expectEqual(@as(u16, 1), git.status.deleted);
    try std.testing.expectEqual(@as(u16, 1), git.status.untracked);
    try std.testing.expectEqual(@as(u16, 2), git.status.ahead);
    try std.testing.expectEqual(@as(u16, 1), git.status.behind);
    try std.testing.expectEqual(@as(usize, 1), harness.host.commands.calls);
}

test "the porcelain branch wins over the one read from disk" {
    const sources = [_]fakes.FakeFiles.File{
        .{ .path = "/home/dev/proj/.git/HEAD", .contents = "ref: refs/heads/stale\n" },
    };
    var harness = FakeHarness.init(&default_environment);
    harness.host.files.sources = &sources;
    harness.host.commands.response = status_porcelain;

    try std.testing.expectEqualStrings("main", harness.model(.{}).git.?.branch);
}

test "a detached repository keeps the short commit from the porcelain" {
    const detached =
        "# branch.oid a1b2c3d4e5f60718293a4b5c6d7e8f9012345678\x00" ++
        "# branch.head (detached)\x00";
    var harness = FakeHarness.init(&default_environment);
    harness.host.commands.response = detached;

    const git = harness.model(.{}).git.?;
    try std.testing.expectEqualStrings("a1b2c3d", git.branch);
}

test "the status cost can be capped without losing the branch" {
    // `fast` asks git for less: no untracked walk, no commit-graph walk. The
    // branch still comes back in the same porcelain header.
    var harness = FakeHarness.init(&(default_environment ++ [_][2][]const u8{
        .{ "PROMTY_GIT", "fast" },
    }));
    harness.host.commands.response = status_porcelain;
    const model = harness.model(.{});
    try std.testing.expectEqual(@as(usize, 1), harness.host.commands.calls);
    try std.testing.expect(std.mem.indexOf(u8, harness.host.commands.lastArgv(), "--untracked-files=no") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.host.commands.lastArgv(), "--no-ahead-behind") != null);
    try std.testing.expectEqualStrings("main", model.git.?.branch);
}

test "anything else is the full status" {
    var harness = FakeHarness.init(&(default_environment ++ [_][2][]const u8{
        .{ "PROMTY_GIT", "1" },
    }));
    harness.host.commands.response = status_porcelain;
    _ = harness.model(.{});
    try std.testing.expect(std.mem.indexOf(u8, harness.host.commands.lastArgv(), "--untracked-files=normal") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.host.commands.lastArgv(), "--no-ahead-behind") == null);
}

test "status can be switched off by the caller or the environment" {
    {
        var harness = FakeHarness.init(&default_environment);
        harness.host.commands.response = status_porcelain;
        const model = harness.model(.{ .git = false });
        try std.testing.expectEqual(@as(usize, 0), harness.host.commands.calls);
        try std.testing.expect(model.git.?.status.isClean());
        // The branch still comes from the files.
        try std.testing.expectEqualStrings("main", model.git.?.branch);
    }
    {
        var harness = FakeHarness.init(&(default_environment ++ [_][2][]const u8{
            .{ "PROMTY_GIT", "0" },
        }));
        harness.host.commands.response = status_porcelain;
        try std.testing.expect(harness.model(.{}).git.?.status.isClean());
        try std.testing.expectEqual(@as(usize, 0), harness.host.commands.calls);
    }
    {
        var harness = FakeHarness.init(&(default_environment ++ [_][2][]const u8{
            .{ "PROMTY_GIT", "false" },
        }));
        harness.host.commands.response = status_porcelain;
        try std.testing.expectEqual(@as(usize, 0), harness.host.commands.calls);
    }
    {
        // Anything else leaves it on.
        var harness = FakeHarness.init(&(default_environment ++ [_][2][]const u8{
            .{ "PROMTY_GIT", "1" },
        }));
        harness.host.commands.response = status_porcelain;
        _ = harness.model(.{});
        try std.testing.expectEqual(@as(usize, 1), harness.host.commands.calls);
    }
}

test "a failing git leaves the fast path intact" {
    var harness = FakeHarness.init(&default_environment);
    harness.host.commands.response = null;

    const git = harness.model(.{}).git.?;
    try std.testing.expectEqual(@as(usize, 1), harness.host.commands.calls);
    try std.testing.expectEqualStrings("main", git.branch);
    try std.testing.expect(git.status.isClean());
}

test "garbage from git is a failure, not a wrong prompt" {
    var harness = FakeHarness.init(&default_environment);
    harness.host.commands.response = "not porcelain at all";
    const git = harness.model(.{}).git.?;
    try std.testing.expectEqualStrings("main", git.branch);
    try std.testing.expect(git.status.isClean());
}

test "a stash is visible without asking git" {
    const sources = project_sources ++ [_]fakes.FakeFiles.File{
        .{ .path = "/home/dev/proj/.git/refs/stash", .contents = "aaa\n" },
    };
    var harness = FakeHarness.init(&default_environment);
    harness.host.files.sources = &sources;
    harness.host.commands.response = null;

    try std.testing.expectEqual(@as(u16, 1), harness.model(.{}).git.?.status.stashed);
}

test "a stashed reflog alone also counts" {
    const sources = project_sources ++ [_]fakes.FakeFiles.File{
        .{ .path = "/home/dev/proj/.git/logs/refs/stash", .contents = "aaa\n" },
    };
    var harness = FakeHarness.init(&default_environment);
    harness.host.files.sources = &sources;
    harness.host.commands.response = null;

    try std.testing.expectEqual(@as(u16, 1), harness.model(.{}).git.?.status.stashed);
}

test "no repository means no git call at all" {
    var harness = FakeHarness.init(&default_environment);
    harness.host.files.sources = &.{};
    harness.host.commands.response = status_porcelain;

    try std.testing.expectEqual(@as(?prompt.Git, null), harness.model(.{}).git);
    try std.testing.expectEqual(@as(usize, 0), harness.host.commands.calls);
}
