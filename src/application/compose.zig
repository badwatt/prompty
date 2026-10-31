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
const language_mod = @import("../domain/language.zig");
const osc_mod = @import("../domain/osc.zig");
const path_mod = @import("../domain/path.zig");
const prompt = @import("../domain/prompt.zig");
const store_mod = @import("../domain/store.zig");
const theme_mod = @import("../domain/theme.zig");
const ports = @import("../ports/host.zig");

pub const Options = struct {
    shell: canvas.Shell = .plain,
    color: bool = true,
    keep_components: u8 = 3,
};

/// The most directory levels prompty will walk looking for a repository. A
/// repository nested deeper than this is not a repository anyone wants to see
/// in a prompt.
pub const max_git_walk: u8 = 64;

pub const max_duration_ms: u64 = 24 * 60 * 60 * 1000;

pub fn build(host: ports.Host, store: *store_mod.Store, options: Options) prompt.Model {
    std.debug.assert(options.keep_components > 0);

    var model = prompt.Model{
        .theme = themeFor(host),
        .shell = options.shell,
        .color = options.color and colorAllowed(host),
        .path = "/",
    };
    model.user = host.environ.get("USER") orelse host.environ.get("LOGNAME");
    model.is_root = host.user_id == 0;

    var working_directory_buffer: [path_mod.max_display_bytes]u8 = undefined;
    const working_directory = workingDirectory(host, &working_directory_buffer);

    var display_buffer: [path_mod.max_display_bytes]u8 = undefined;
    const home = host.environ.get("HOME") orelse "";
    model.path = store.dupe(path_mod.display(
        &display_buffer,
        working_directory,
        home,
        options.keep_components,
    ));

    if (gitProbe(host, working_directory, store)) |repository| model.git = repository;
    addLanguages(host, working_directory, store, &model);

    const unix_seconds = host.clock.now();
    model.time = clock_mod.fromUnix(unix_seconds, host.clock.offsetAt(unix_seconds));
    model.duration_ms = parseDuration(host);
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

const Located = struct {
    git_dir: []const u8,
    head: git_mod.Head,
};

fn gitProbe(host: ports.Host, working_directory: []const u8, store: *store_mod.Store) ?prompt.Git {
    var git_dir_buffer: [path_mod.max_display_bytes * 2]u8 = undefined;
    var head_buffer: [git_mod.max_head_bytes]u8 = undefined;

    var directory = working_directory;
    var walked: u8 = 0;
    while (walked < max_git_walk) : (walked += 1) {
        if (locate(host, directory, &git_dir_buffer, &head_buffer)) |located| {
            const operation = operationIn(host, located.git_dir);
            const branch = switch (located.head) {
                .named => |name| store.dupe(name),
                .detached => |commit| store.dupe(git_mod.short(commit)),
            };
            return .{
                .branch = branch,
                .operation = operation,
                .detached = switch (located.head) {
                    .named => false,
                    .detached => true,
                },
            };
        }
        directory = parent(directory) orelse return null;
    }
    return null;
}

fn locate(
    host: ports.Host,
    directory: []const u8,
    git_dir_buffer: []u8,
    head_buffer: []u8,
) ?Located {
    var scratch: [path_mod.max_display_bytes * 2]u8 = undefined;

    // The common case: a real `.git` directory with a HEAD inside.
    if (join(&scratch, directory, ".git/HEAD")) |head_path| {
        if (host.files.read(head_path, head_buffer)) |contents| {
            const head = git_mod.parseHead(contents) orelse return null;
            const git_dir_path = join(&scratch, directory, ".git") orelse return null;
            const git_dir = copy(git_dir_buffer, git_dir_path) orelse return null;
            return .{ .git_dir = git_dir, .head = head };
        }
    }

    // A worktree or submodule: `.git` is a file pointing at the real directory.
    const pointer_path = join(&scratch, directory, ".git") orelse return null;
    const pointer = host.files.read(pointer_path, head_buffer) orelse return null;
    const target = git_mod.parseGitFile(pointer) orelse return null;

    var resolved_buffer: [path_mod.max_display_bytes * 2]u8 = undefined;
    const resolved = if (target[0] == '/')
        target
    else
        join(&resolved_buffer, directory, target) orelse return null;
    const git_dir = copy(git_dir_buffer, resolved) orelse return null;

    const head_path = join(&scratch, git_dir, "HEAD") orelse return null;
    const contents = host.files.read(head_path, head_buffer) orelse return null;
    const head = git_mod.parseHead(contents) orelse return null;
    return .{ .git_dir = git_dir, .head = head };
}

fn operationIn(host: ports.Host, git_dir: []const u8) git_mod.Operation {
    var scratch: [path_mod.max_display_bytes * 2]u8 = undefined;
    if (existsIn(host, git_dir, "rebase-merge", &scratch) or
        existsIn(host, git_dir, "rebase-apply", &scratch))
    {
        return .rebase;
    }
    if (existsIn(host, git_dir, "MERGE_HEAD", &scratch)) return .merge;
    if (existsIn(host, git_dir, "CHERRY_PICK_HEAD", &scratch)) return .cherry_pick;
    if (existsIn(host, git_dir, "BISECT_LOG", &scratch)) return .bisect;
    return .none;
}

fn existsIn(host: ports.Host, git_dir: []const u8, name: []const u8, scratch: []u8) bool {
    const path = join(scratch, git_dir, name) orelse return false;
    return host.files.exists(path);
}

const LanguageProbe = struct {
    set: language_mod.Set = language_mod.Set.empty(),

    fn visit(context: *anyopaque, entry: ports.Entry) void {
        const self: *LanguageProbe = @ptrCast(@alignCast(context));
        language_mod.classifyName(&self.set, entry.name, entry.is_dir);
    }
};

const detected_order = [_]language_mod.Kind{ .zig, .rust, .go, .node, .odin };

fn addLanguages(
    host: ports.Host,
    working_directory: []const u8,
    store: *store_mod.Store,
    model: *prompt.Model,
) void {
    var probe = LanguageProbe{};
    if (!host.files.scan(working_directory, &probe, LanguageProbe.visit)) return;

    for (detected_order) |kind| {
        if (!probe.set.has(kind)) continue;
        model.addLanguage(.{
            .kind = kind,
            .version = versionFor(host, working_directory, kind, store),
        });
    }
}

fn versionFor(
    host: ports.Host,
    working_directory: []const u8,
    kind: language_mod.Kind,
    store: *store_mod.Store,
) ?[]const u8 {
    var path_buffer: [path_mod.max_display_bytes * 2]u8 = undefined;
    var contents: [16 * 1024]u8 = undefined;

    switch (kind) {
        .zig => {
            if (fromPlainFile(host, working_directory, ".zigversion", &path_buffer, &contents)) |version| {
                return store.dupe(version);
            }
            if (read(host, working_directory, "build.zig.zon", &path_buffer, &contents)) |zon| {
                if (language_mod.zigVersionFromZon(zon)) |version| return store.dupe(version);
            }
            return null;
        },
        .rust => {
            if (read(host, working_directory, "rust-toolchain.toml", &path_buffer, &contents)) |toml| {
                if (language_mod.rustVersionFromToolchain(toml)) |version| return store.dupe(version);
            }
            if (fromPlainFile(host, working_directory, "rust-toolchain", &path_buffer, &contents)) |version| {
                return store.dupe(version);
            }
            return null;
        },
        .go => {
            if (read(host, working_directory, "go.mod", &path_buffer, &contents)) |mod| {
                if (language_mod.goVersionFromMod(mod)) |version| return store.dupe(version);
            }
            return null;
        },
        .node => {
            if (fromPlainFile(host, working_directory, ".nvmrc", &path_buffer, &contents)) |version| {
                return store.dupe(version);
            }
            if (fromPlainFile(host, working_directory, ".node-version", &path_buffer, &contents)) |version| {
                return store.dupe(version);
            }
            return null;
        },
        .odin => return null,
    }
}

fn fromPlainFile(
    host: ports.Host,
    working_directory: []const u8,
    name: []const u8,
    path_buffer: []u8,
    contents: []u8,
) ?[]const u8 {
    const text = read(host, working_directory, name, path_buffer, contents) orelse return null;
    return language_mod.plainVersion(text);
}

fn read(
    host: ports.Host,
    working_directory: []const u8,
    name: []const u8,
    path_buffer: []u8,
    contents: []u8,
) ?[]const u8 {
    const path = join(path_buffer, working_directory, name) orelse return null;
    return host.files.read(path, contents);
}

fn join(buffer: []u8, directory: []const u8, suffix: []const u8) ?[]u8 {
    std.debug.assert(suffix.len > 0);
    if (directory.len == 0) return copy(buffer, suffix);

    const separator = directory[directory.len - 1] != '/';
    const total = directory.len + @intFromBool(separator) + suffix.len;
    if (total > buffer.len) return null;

    @memcpy(buffer[0..directory.len], directory);
    var written = directory.len;
    if (separator) {
        buffer[written] = '/';
        written += 1;
    }
    @memcpy(buffer[written..][0..suffix.len], suffix);
    return buffer[0 .. written + suffix.len];
}

fn copy(buffer: []u8, content: []const u8) ?[]u8 {
    if (content.len > buffer.len) return null;
    @memcpy(buffer[0..content.len], content);
    return buffer[0..content.len];
}

fn parent(directory: []const u8) ?[]const u8 {
    var end = directory.len;
    while (end > 0 and directory[end - 1] == '/') end -= 1;
    if (end == 0) return null;
    var index = end;
    while (index > 0) : (index -= 1) {
        if (directory[index - 1] == '/') break;
    }
    if (index == 0) return null;
    if (index == 1) return "/";
    return directory[0 .. index - 1];
}

test "join never produces double separators" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a/b", join(&buffer, "a", "b").?);
    try std.testing.expectEqualStrings("a/b", join(&buffer, "a/", "b").?);
    try std.testing.expectEqualStrings("/b", join(&buffer, "/", "b").?);
    try std.testing.expectEqualStrings("b", join(&buffer, "", "b").?);
    var small: [3]u8 = undefined;
    try std.testing.expectEqual(@as(?[]u8, null), join(&small, "abc", "de"));
}

test "parent walks up to the root and stops" {
    try std.testing.expectEqualStrings("/home/dev", parent("/home/dev/src").?);
    try std.testing.expectEqualStrings("/home", parent("/home/dev").?);
    try std.testing.expectEqualStrings("/", parent("/home").?);
    try std.testing.expectEqual(@as(?[]const u8, null), parent("/"));
    try std.testing.expectEqual(@as(?[]const u8, null), parent("relative"));
    try std.testing.expectEqualStrings("/home", parent("/home/dev/").?);
}

test "copy refuses to overflow the destination" {
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqualStrings("abc", copy(&buffer, "abc").?);
    try std.testing.expectEqual(@as(?[]u8, null), copy(&buffer, "abcde"));
}

// ---------------------------------------------------------------------------
// Integration tests: the whole use case, driven through the ports with a fake
// filesystem, clock, terminal and environment.
// ---------------------------------------------------------------------------

const fakes = @import("../test_support/fakes.zig");

const project_entries = [_]ports.Entry{
    .{ .name = "build.zig", .is_dir = false },
    .{ .name = "build.zig.zon", .is_dir = false },
    .{ .name = "go.mod", .is_dir = false },
    .{ .name = ".zigversion", .is_dir = false },
    .{ .name = "src", .is_dir = true },
    .{ .name = "README.md", .is_dir = false },
};

const project_sources = [_]fakes.FakeFiles.File{
    .{ .path = "/home/dev/proj/.git/HEAD", .contents = "ref: refs/heads/main\n" },
    .{ .path = "/home/dev/proj/.zigversion", .contents = "0.17.0\n" },
    .{ .path = "/home/dev/proj/go.mod", .contents = "module example.com/proj\n\ngo 1.22.3\n" },
};

const project_directories = [_]fakes.FakeFiles.Directory{
    .{ .path = "/home/dev/proj", .entries = &project_entries },
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
    try std.testing.expectEqualStrings("~/proj", model.path);
    try std.testing.expectEqualStrings("main", model.git.?.branch);
    try std.testing.expectEqual(git_mod.Operation.none, model.git.?.operation);
    try std.testing.expect(!model.git.?.detached);

    // The order is fixed so the prompt never flickers between renders.
    const languages = model.detectedLanguages();
    try std.testing.expectEqual(@as(usize, 2), languages.len);
    try std.testing.expectEqual(language_mod.Kind.zig, languages[0].kind);
    try std.testing.expectEqualStrings("0.17.0", languages[0].version.?);
    try std.testing.expectEqual(language_mod.Kind.go, languages[1].kind);
    try std.testing.expectEqualStrings("1.22.3", languages[1].version.?);
}

test "a root shell is marked and can be rendered" {
    var harness = FakeHarness.init(&default_environment);
    harness.host.user_id = 0;
    const model = harness.model(.{ .color = false, .shell = .plain });
    try std.testing.expect(model.is_root);

    var buffer: [canvas.Canvas.capacity]u8 = undefined;
    const rendered = prompt.render(&model, &buffer);
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
        const entries = [_]ports.Entry{.{ .name = "go.mod", .is_dir = false }};
        const directories = [_]fakes.FakeFiles.Directory{
            .{ .path = "/home/dev/scratch", .entries = &entries },
        };
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
    const directories = [_]fakes.FakeFiles.Directory{
        .{ .path = "/home/dev/proj", .entries = &project_entries },
        .{ .path = "/home/dev/proj/.git/rebase-merge", .entries = &.{} },
    };
    var harness = FakeHarness.init(&default_environment);
    harness.host.files.sources = &sources;
    harness.host.files.directories = &directories;

    const model = harness.model(.{});
    try std.testing.expect(model.git.?.detached);
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

test "language versions come from the files the project already has" {
    const entries = [_]ports.Entry{
        .{ .name = "Cargo.toml", .is_dir = false },
        .{ .name = "package.json", .is_dir = false },
    };
    const directories = [_]fakes.FakeFiles.Directory{
        .{ .path = "/home/dev/proj", .entries = &entries },
    };
    const sources = [_]fakes.FakeFiles.File{
        .{ .path = "/home/dev/proj/rust-toolchain.toml", .contents = "[toolchain]\nchannel = \"1.80.0\"\n" },
        .{ .path = "/home/dev/proj/.nvmrc", .contents = "v20.11.0\n" },
    };
    var harness = FakeHarness.init(&default_environment);
    harness.host.files.sources = &sources;
    harness.host.files.directories = &directories;

    const languages = harness.model(.{}).detectedLanguages();
    try std.testing.expectEqual(@as(usize, 2), languages.len);
    try std.testing.expectEqual(language_mod.Kind.rust, languages[0].kind);
    try std.testing.expectEqualStrings("1.80.0", languages[0].version.?);
    try std.testing.expectEqual(language_mod.Kind.node, languages[1].kind);
    try std.testing.expectEqualStrings("20.11.0", languages[1].version.?);
}

test "languages without a pinned version still show their icon" {
    const entries = [_]ports.Entry{.{ .name = "main.odin", .is_dir = false }};
    const directories = [_]fakes.FakeFiles.Directory{
        .{ .path = "/home/dev/proj", .entries = &entries },
    };
    var harness = FakeHarness.init(&default_environment);
    harness.host.files.sources = &.{};
    harness.host.files.directories = &directories;

    const languages = harness.model(.{}).detectedLanguages();
    try std.testing.expectEqual(@as(usize, 1), languages.len);
    try std.testing.expectEqual(language_mod.Kind.odin, languages[0].kind);
    try std.testing.expectEqual(@as(?[]const u8, null), languages[0].version);
}

test "an unreadable project root simply has no languages" {
    var harness = FakeHarness.init(&default_environment);
    harness.host.files.directories = &.{};
    try std.testing.expectEqual(@as(usize, 0), harness.model(.{}).detectedLanguages().len);
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
    var plain = FakeHarness.init(&(default_environment ++ [_][2][]const u8{.{"NO_COLOR", "1"}}));
    try std.testing.expect(!plain.model(.{}).color);

    var dumb = FakeHarness.init(&(default_environment ++ [_][2][]const u8{.{"TERM", "dumb"}}));
    try std.testing.expect(!dumb.model(.{}).color);

    var colourful = FakeHarness.init(&(default_environment ++ [_][2][]const u8{.{"TERM", "xterm-256color"}}));
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
