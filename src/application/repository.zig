//! Finding the repository a working directory belongs to.
//!
//! This is the only part of the use case that walks: up from the working
//! directory, one `.git` at a time, until a level has one. Everything it returns
//! borrows the caller's buffers, so nothing here allocates, and the walk is
//! bounded by `max_git_walk`.

const std = @import("std");

const git_mod = @import("../domain/git.zig");
const path_mod = @import("../domain/path.zig");
const ports = @import("../ports/host.zig");
const store_mod = @import("../domain/store.zig");
const prompt = @import("../domain/prompt.zig");

/// The most directory levels prompty will walk looking for a repository. A
/// repository nested deeper than this is not a repository anyone wants to see
/// in a prompt.
pub const max_git_walk: u8 = 64;

pub const Probe = struct {
    /// The worktree root, and its git directory.
    root: []const u8,
    git_dir: []const u8,
    /// What to show: the branch, or the short commit when HEAD is detached.
    git: prompt.Git,
};

pub const Located = struct {
    /// The worktree root: the directory that holds the `.git` entry.
    root: []const u8,
    git_dir: []const u8,
    head: git_mod.Head,
};

/// The repository `working_directory` is in, if any, with the branch already
/// copied into the store so the caller can show it.
pub fn probe(
    host: ports.Host,
    working_directory: []const u8,
    store: *store_mod.Store,
    git_dir_buffer: []u8,
) ?Probe {
    std.debug.assert(git_dir_buffer.len >= path_mod.scratch_bytes);
    var head_buffer: [git_mod.max_head_bytes]u8 = undefined;

    var directory = working_directory;
    var walked: u8 = 0;
    while (true) {
        // Every iteration either finds a repository or walks one level up, so
        // the assertion is the loop's bound.
        std.debug.assert(walked < max_git_walk);
        walked += 1;
        if (locate(host, directory, git_dir_buffer, &head_buffer)) |located| {
            const branch = switch (located.head) {
                .named => |name| store.dupePrintable(name),
                .detached => |commit| store.dupePrintable(git_mod.short(commit)),
            };
            return .{
                .root = located.root,
                .git_dir = located.git_dir,
                .git = .{ .branch = branch, .operation = operationIn(host, located.git_dir) },
            };
        }
        directory = parent(directory) orelse return null;
    }
}

/// A stash survives `git stash` without a `git status` line, so it is looked for
/// on disk: a packed or reflog-only stash still counts.
pub fn hasStash(host: ports.Host, git_dir: []const u8) bool {
    var scratch: [path_mod.scratch_bytes]u8 = undefined;
    if (existsIn(host, git_dir, "refs/stash", &scratch)) return true;
    return existsIn(host, git_dir, "logs/refs/stash", &scratch);
}

fn probeRepository(
    host: ports.Host,
    working_directory: []const u8,
    store: *store_mod.Store,
    git_dir_buffer: []u8,
) ?Probe {
    std.debug.assert(git_dir_buffer.len >= path_mod.scratch_bytes);
    var head_buffer: [git_mod.max_head_bytes]u8 = undefined;

    var directory = working_directory;
    var walked: u8 = 0;
    while (true) {
        // Every iteration either finds a repository or walks one level up, so
        // the assertion is the loop's bound.
        std.debug.assert(walked < max_git_walk);
        walked += 1;
        if (locate(host, directory, git_dir_buffer, &head_buffer)) |located| {
            const operation = operationIn(host, located.git_dir);
            const branch = switch (located.head) {
                .named => |name| store.dupePrintable(name),
                .detached => |commit| store.dupePrintable(git_mod.short(commit)),
            };
            return .{
                .root = located.root,
                .git_dir = located.git_dir,
                .git = .{ .branch = branch, .operation = operation },
            };
        }
        directory = parent(directory) orelse return null;
    }
}

fn locate(
    host: ports.Host,
    directory: []const u8,
    git_dir_buffer: []u8,
    head_buffer: []u8,
) ?Located {
    var scratch: [path_mod.scratch_bytes]u8 = undefined;

    // The common case: a real `.git` directory with a HEAD inside.
    if (join(&scratch, directory, ".git/HEAD")) |head_path| {
        if (host.files.read(head_path, head_buffer)) |contents| {
            const head = git_mod.parseHead(contents) orelse return null;
            const git_dir_path = join(&scratch, directory, ".git") orelse return null;
            const git_dir = copy(git_dir_buffer, git_dir_path) orelse return null;
            return .{ .root = directory, .git_dir = git_dir, .head = head };
        }
    }

    // A worktree or submodule: `.git` is a file pointing at the real directory.
    const pointer_path = join(&scratch, directory, ".git") orelse return null;
    const pointer = host.files.read(pointer_path, head_buffer) orelse return null;
    const target = git_mod.parseGitFile(pointer) orelse return null;

    var resolved_buffer: [path_mod.scratch_bytes]u8 = undefined;
    const resolved = if (target[0] == '/')
        target
    else
        join(&resolved_buffer, directory, target) orelse return null;
    const git_dir = copy(git_dir_buffer, resolved) orelse return null;

    const head_path = join(&scratch, git_dir, "HEAD") orelse return null;
    const contents = host.files.read(head_path, head_buffer) orelse return null;
    const head = git_mod.parseHead(contents) orelse return null;
    return .{ .root = directory, .git_dir = git_dir, .head = head };
}

fn operationIn(host: ports.Host, git_dir: []const u8) git_mod.Operation {
    var scratch: [path_mod.scratch_bytes]u8 = undefined;
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

const join = path_mod.join;

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

test "copy refuses to overflow the destination" {
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqualStrings("abc", copy(&buffer, "abc").?);
    try std.testing.expectEqual(@as(?[]u8, null), copy(&buffer, "abcde"));
}

test "parent walks up to the root and stops" {
    try std.testing.expectEqualStrings("/home/dev", parent("/home/dev/src").?);
    try std.testing.expectEqualStrings("/home", parent("/home/dev").?);
    try std.testing.expectEqualStrings("/", parent("/home").?);
    try std.testing.expectEqual(@as(?[]const u8, null), parent("/"));
    try std.testing.expectEqual(@as(?[]const u8, null), parent("relative"));
    try std.testing.expectEqualStrings("/home", parent("/home/dev/").?);
}
