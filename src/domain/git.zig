//! Pure parsing of the git metadata prompty reads. Reading `.git/HEAD` and a
//! handful of marker files costs a few microseconds; shelling out to `git`
//! costs tens of milliseconds, so this is all the repository state prompty
//! needs.

const std = @import("std");

pub const Head = union(enum) {
    /// A branch name, already stripped of `refs/heads/`.
    named: []const u8,
    /// A commit hash when HEAD is detached; always at least `short_length` hex
    /// digits long and never longer than a full SHA-256 hash.
    detached: []const u8,
};

pub const Operation = enum {
    none,
    merge,
    rebase,
    cherry_pick,
    bisect,

    pub fn label(self: Operation) []const u8 {
        return switch (self) {
            .none => "",
            .merge => "merge",
            .rebase => "rebase",
            .cherry_pick => "pick",
            .bisect => "bisect",
        };
    }
};

pub const head_ref_prefix = "ref: ";

pub const max_head_bytes = 128;

/// Parses the contents of `.git/HEAD`.
pub fn parseHead(contents: []const u8) ?Head {
    const line = trimWhitespace(contents);
    if (line.len == 0) return null;
    if (std.mem.startsWith(u8, line, head_ref_prefix)) {
        const name = line[head_ref_prefix.len..];
        const prefix = "refs/heads/";
        if (!std.mem.startsWith(u8, name, prefix)) return null;
        const branch = name[prefix.len..];
        if (branch.len == 0 or branch.len > max_head_bytes) return null;
        return .{ .named = branch };
    }
    if (line.len < short_length) return null;
    if (line.len > 64) return null;
    for (line) |byte| {
        if (!std.ascii.isHex(byte)) return null;
    }
    return .{ .detached = line };
}

/// Parses a `.git` file, which a worktree or a submodule uses to point at the
/// real git directory.
pub fn parseGitFile(contents: []const u8) ?[]const u8 {
    const line = trimWhitespace(contents);
    const prefix = "gitdir: ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const target = line[prefix.len..];
    if (target.len == 0) return null;
    return target;
}

pub const short_length = 7;

/// The part of a detached commit hash shown in the prompt.
pub fn short(commit: []const u8) []const u8 {
    std.debug.assert(commit.len >= short_length);
    return commit[0..short_length];
}

fn trimWhitespace(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
}

test "parses a branch head" {
    const head = parseHead("ref: refs/heads/main\n").?;
    try std.testing.expectEqualStrings("main", head.named);
}

test "parses branch names with slashes and no newline" {
    const head = parseHead("ref: refs/heads/feat/prompt/perf").?;
    try std.testing.expectEqualStrings("feat/prompt/perf", head.named);
}

test "parses a detached head" {
    const head = parseHead("a1b2c3d4e5f60718293a4b5c6d7e8f9012345678\n").?;
    try std.testing.expectEqualStrings("a1b2c3d", short(head.detached));
    try std.testing.expectEqual(@as(usize, 40), head.detached.len);
}

test "rejects anything that is not a branch or a hash" {
    try std.testing.expectEqual(@as(?Head, null), parseHead(""));
    try std.testing.expectEqual(@as(?Head, null), parseHead("\n"));
    try std.testing.expectEqual(@as(?Head, null), parseHead("ref: refs/tags/v1.0.0\n"));
    try std.testing.expectEqual(@as(?Head, null), parseHead("ref: refs/heads/\n"));
    try std.testing.expectEqual(@as(?Head, null), parseHead("abc123\n"));
    try std.testing.expectEqual(@as(?Head, null), parseHead("zzzzzzzz\n"));
    var too_long_buffer: [head_ref_prefix.len + "refs/heads/".len + max_head_bytes + 1]u8 = undefined;
    @memset(&too_long_buffer, 'x');
    @memcpy(too_long_buffer[0 .. head_ref_prefix.len + "refs/heads/".len], "ref: refs/heads/");
    try std.testing.expectEqual(@as(?Head, null), parseHead(&too_long_buffer));

    const too_long_hash: [65]u8 = @splat('a');
    try std.testing.expectEqual(@as(?Head, null), parseHead(&too_long_hash));
}

test "parses a gitdir pointer" {
    try std.testing.expectEqualStrings(
        "/home/dev/repo/.git/worktrees/wt",
        parseGitFile("gitdir: /home/dev/repo/.git/worktrees/wt\n").?,
    );
    try std.testing.expectEqualStrings(
        "../.git",
        parseGitFile("gitdir: ../.git").?,
    );
}

test "rejects malformed gitdir pointers" {
    try std.testing.expectEqual(@as(?[]const u8, null), parseGitFile(""));
    try std.testing.expectEqual(@as(?[]const u8, null), parseGitFile("/some/path"));
    try std.testing.expectEqual(@as(?[]const u8, null), parseGitFile("gitdir:    "));
    try std.testing.expectEqual(@as(?[]const u8, null), parseGitFile("gitdir: \n"));
}

test "operation labels are short and stable" {
    try std.testing.expectEqualStrings("", Operation.none.label());
    try std.testing.expectEqualStrings("merge", Operation.merge.label());
    try std.testing.expectEqualStrings("rebase", Operation.rebase.label());
    try std.testing.expectEqualStrings("pick", Operation.cherry_pick.label());
    try std.testing.expectEqualStrings("bisect", Operation.bisect.label());
}
