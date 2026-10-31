//! The compose use case: gather facts through the ports, then hand a view model
//! to the domain renderer.
//!
//! Everything here is bounded. There is no allocation, no subprocess and no
//! unbounded loop, so the cost of a render depends only on how many files the
//! prompt has to look at, never on how big they are.

const std = @import("std");

const canvas = @import("../domain/canvas.zig");
const clock_mod = @import("../domain/clock.zig");
const git_mod = @import("../domain/git.zig");
const language_mod = @import("../domain/language.zig");
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
    const configured = host.environ.get("PROMTY_BACKGROUND") orelse
        return theme_mod.Theme.derive(theme_mod.Theme.default_background);
    const background = theme_mod.Rgb.parse(configured) orelse
        return theme_mod.Theme.derive(theme_mod.Theme.default_background);
    return theme_mod.Theme.derive(background);
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
