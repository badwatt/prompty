//! Parses `git status --porcelain=v2 --branch -z` into the handful of facts a
//! prompt shows.
//!
//! This is the only place prompty depends on another program, and the parser is
//! pure so the dependency stays confined to one port call: the records can be
//! tested exhaustively without a repository.

const std = @import("std");

const git_mod = @import("git.zig");

/// The categories the status row shows, in display order.
pub const Status = struct {
    conflicted: u16 = 0,
    stashed: u16 = 0,
    deleted: u16 = 0,
    renamed: u16 = 0,
    modified: u16 = 0,
    staged: u16 = 0,
    untracked: u16 = 0,
    ahead: u16 = 0,
    behind: u16 = 0,

    pub fn isClean(self: Status) bool {
        return self.conflicted == 0 and
            self.stashed == 0 and
            self.deleted == 0 and
            self.renamed == 0 and
            self.modified == 0 and
            self.staged == 0 and
            self.untracked == 0 and
            self.ahead == 0 and
            self.behind == 0;
    }

    pub fn isDiverged(self: Status) bool {
        return self.ahead > 0 and self.behind > 0;
    }
};

pub const Report = struct {
    /// `null` when HEAD has no commit yet.
    branch: ?[]const u8 = null,
    commit: ?[]const u8 = null,
    detached: bool = false,
    status: Status = .{},
};

/// A branch name is bounded once, in `git.zig`: the same name arrives through
/// `.git/HEAD` and through the porcelain header, and both have to agree.
const max_branch_bytes = git_mod.max_head_bytes;

/// Records are NUL separated (`-z`), which is the only format that survives
/// paths containing spaces, quotes or newlines.
pub fn parse(records: []const u8) ?Report {
    if (records.len == 0) return null;

    var report = Report{};
    var fields = std.mem.splitScalar(u8, records, 0);
    var skip_path = false;
    var saw_record = false;

    while (fields.next()) |record| {
        if (record.len == 0) continue;
        // A rename record is followed by the original path as its own field.
        if (skip_path) {
            skip_path = false;
            continue;
        }
        saw_record = true;

        switch (record[0]) {
            '#' => parseHeader(&report, record),
            '1' => _ = parseChanged(&report.status, record),
            '2' => {
                // The original path follows as its own field, but only when the
                // record itself was well formed.
                if (parseChanged(&report.status, record)) {
                    report.status.renamed +|= 1;
                    skip_path = true;
                }
            },
            'u' => report.status.conflicted +|= 1,
            '?' => report.status.untracked +|= 1,
            // '!' marks ignored files, which no prompt shows.
            else => {},
        }
    }

    if (!saw_record) return null;
    return report;
}

fn parseHeader(report: *Report, record: []const u8) void {
    if (std.mem.startsWith(u8, record, "# branch.head ")) {
        const name = record["# branch.head ".len..];
        if (std.mem.eql(u8, name, "(detached)")) {
            report.detached = true;
        } else if (name.len > 0 and name.len <= max_branch_bytes) {
            report.branch = name;
        }
        return;
    }
    if (std.mem.startsWith(u8, record, "# branch.oid ")) {
        const commit = record["# branch.oid ".len..];
        // "(initial)" means the repository has no commit yet.
        if (commit.len >= 7 and !std.mem.eql(u8, commit, "(initial)")) report.commit = commit;
        return;
    }
    if (std.mem.startsWith(u8, record, "# branch.ab ")) {
        parseDivergence(&report.status, record["# branch.ab ".len..]);
    }
}

/// A record is `<type> <XY> ...`, and `X` is the index against HEAD while `Y`
/// is the worktree against the index. The records come from another program, so
/// a short one is ignored instead of indexed: reading the `XY` field of a
/// truncated record used to read whatever followed it in the buffer.
fn parseChanged(status: *Status, record: []const u8) bool {
    if (record.len < 4) return false;
    const index = record[2];
    const worktree = record[3];

    // A deletion is reported once, as a deletion, no matter which side of the
    // index records it: deleting a file is not "modifying" it.
    if (index == 'D' or worktree == 'D') {
        status.deleted +|= 1;
        return true;
    }
    if (index != '.' and index != ' ') status.staged +|= 1;
    if (worktree != '.' and worktree != ' ') status.modified +|= 1;
    // Renames are counted from the record type, not from `X`, so that a
    // renamed entry is never counted twice.
    return true;
}

/// `+<ahead> -<behind>`
fn parseDivergence(status: *Status, field: []const u8) void {
    var tokens = std.mem.tokenizeScalar(u8, field, ' ');
    while (tokens.next()) |token| {
        if (token.len < 2) continue;
        const amount = std.fmt.parseInt(u16, token[1..], 10) catch continue;
        switch (token[0]) {
            '+' => status.ahead = amount,
            '-' => status.behind = amount,
            else => {},
        }
    }
}

test "a clean repository reports a branch and nothing else" {
    const records =
        "# branch.oid 1cec0eae51f1f82b5bb5290d9309f73728b04aba\x00" ++
        "# branch.head main\x00";
    const report = parse(records).?;

    try std.testing.expectEqualStrings("main", report.branch.?);
    try std.testing.expect(!report.detached);
    try std.testing.expect(report.status.isClean());
}

test "every kind of change is counted once" {
    // One modified, one staged, one deleted, one renamed (plus its original
    // path), one conflicted and two untracked.
    const records =
        "# branch.head main\x00" ++
        "1 .M N... 100644 100644 100644 aaaaaaa aaaaaaa src/modified.zig\x00" ++
        "1 M. N... 100644 100644 100644 aaaaaaa aaaaaaa src/staged.zig\x00" ++
        "1 .D N... 100644 100644 000000 aaaaaaa aaaaaaa src/deleted.zig\x00" ++
        "2 R. N... 100644 100644 100644 aaaaaaa aaaaaaa R100 src/new.zig\x00src/old.zig\x00" ++
        "u UU N... 100644 100644 100644 100644 aaaaaaa aaaaaaa aaaaaaa src/conflict.zig\x00" ++
        "? src/untracked.zig\x00" ++
        "? src/also-untracked.zig\x00";
    const status = parse(records).?.status;

    try std.testing.expectEqual(@as(u16, 1), status.modified);
    // The staged rename counts as staged as well as renamed.
    try std.testing.expectEqual(@as(u16, 2), status.staged);
    try std.testing.expectEqual(@as(u16, 1), status.deleted);
    try std.testing.expectEqual(@as(u16, 1), status.renamed);
    try std.testing.expectEqual(@as(u16, 1), status.conflicted);
    try std.testing.expectEqual(@as(u16, 2), status.untracked);
    try std.testing.expect(!status.isClean());
}

test "a file changed in both index and worktree counts twice" {
    const status = parse("1 MM N... 100644 100644 100644 a a src/both.zig\x00").?.status;
    try std.testing.expectEqual(@as(u16, 1), status.staged);
    try std.testing.expectEqual(@as(u16, 1), status.modified);
}

test "a renamed and modified file reports all three facts" {
    const records = "2 RM N... 100644 100644 100644 a a R100 src/new.zig\x00src/old.zig\x00";
    const status = parse(records).?.status;
    try std.testing.expectEqual(@as(u16, 1), status.renamed);
    try std.testing.expectEqual(@as(u16, 1), status.staged);
    try std.testing.expectEqual(@as(u16, 1), status.modified);
}

test "ignored files are not shown" {
    const status = parse("! node_modules/\x00? real.txt\x00").?.status;
    try std.testing.expectEqual(@as(u16, 1), status.untracked);
    try std.testing.expectEqual(@as(u16, 0), status.staged);
}

test "upstream divergence is read from the branch header" {
    const behind = parse("# branch.head main\x00# branch.ab +0 -3\x00").?.status;
    try std.testing.expectEqual(@as(u16, 0), behind.ahead);
    try std.testing.expectEqual(@as(u16, 3), behind.behind);
    try std.testing.expect(!behind.isDiverged());

    const ahead = parse("# branch.head main\x00# branch.ab +2 -0\x00").?.status;
    try std.testing.expectEqual(@as(u16, 2), ahead.ahead);
    try std.testing.expect(!ahead.isDiverged());

    const diverged = parse("# branch.head main\x00# branch.ab +2 -3\x00").?.status;
    try std.testing.expect(diverged.isDiverged());
    try std.testing.expect(!diverged.isClean());
}

test "a detached head is reported as detached and keeps its commit" {
    const records =
        "# branch.oid a1b2c3d4e5f60718293a4b5c6d7e8f9012345678\x00" ++
        "# branch.head (detached)\x00";
    const report = parse(records).?;
    try std.testing.expect(report.detached);
    try std.testing.expectEqual(@as(?[]const u8, null), report.branch);
    try std.testing.expectEqualStrings("a1b2c3d4e5f60718293a4b5c6d7e8f9012345678", report.commit.?);
}

test "a repository without commits has no branch head value to show" {
    const report = parse("# branch.oid (initial)\x00# branch.head main\x00").?;
    try std.testing.expectEqual(@as(?[]const u8, null), report.commit);
    try std.testing.expectEqualStrings("main", report.branch.?);
}

test "an over-long branch name is rejected rather than truncated" {
    var buffer: [max_branch_bytes + 64]u8 = undefined;
    const prefix = "# branch.head ";
    @memcpy(buffer[0..prefix.len], prefix);
    @memset(buffer[prefix.len .. prefix.len + max_branch_bytes + 1], 'y');
    buffer[prefix.len + max_branch_bytes + 1] = 0;
    const records = buffer[0 .. prefix.len + max_branch_bytes + 2];
    try std.testing.expectEqual(@as(?[]const u8, null), parse(records).?.branch);
}

test "a truncated changed record is ignored rather than read past" {
    // The records come from another program. A record too short to carry its
    // XY field is not a change, and indexing it anyway read whatever followed
    // in the read buffer.
    const report = parse("1\x00# branch.head main\x00").?;
    try std.testing.expect(report.status.isClean());
    try std.testing.expectEqualStrings("main", report.branch.?);
    // The same for a rename, which reads the field and then counts itself.
    try std.testing.expect(parse("2\x00").?.status.isClean());
    try std.testing.expect(parse("1 M\x00").?.status.isClean());
}

test "garbage and empty input are rejected" {
    try std.testing.expectEqual(@as(?Report, null), parse(""));
    try std.testing.expectEqual(@as(?Report, null), parse("\x00\x00\x00"));
    // Unknown record types are ignored, but their presence still counts as a
    // report: git is free to add record types in the future.
    const report = parse("# branch.head main\x00X unknown\x00").?;
    try std.testing.expectEqualStrings("main", report.branch.?);
}

test "malformed divergence values do not become counts" {
    const status = parse("# branch.ab +x -y\x00").?.status;
    try std.testing.expectEqual(@as(u16, 0), status.ahead);
    try std.testing.expectEqual(@as(u16, 0), status.behind);
    const truncated = parse("# branch.ab +\x00").?.status;
    try std.testing.expectEqual(@as(u16, 0), truncated.ahead);
    const unknown = parse("# branch.ab ?1 ~2\x00").?.status;
    try std.testing.expectEqual(@as(u16, 0), unknown.ahead);
    try std.testing.expectEqual(@as(u16, 0), unknown.behind);
}

test "counts saturate instead of wrapping" {
    var records: [64 * 96]u8 = undefined;
    var written: usize = 0;
    var index: usize = 0;
    while (index < 64) : (index += 1) {
        const record = "? file\x00";
        @memcpy(records[written..][0..record.len], record);
        written += record.len;
    }
    const status = parse(records[0..written]).?.status;
    try std.testing.expectEqual(@as(u16, 64), status.untracked);
}

test "property: any bytes are parsed, never indexed past" {
    // The records come from another program. Whatever it prints, the parser
    // reports something bounded or nothing at all.
    var prng = std.Random.DefaultPrng.init(0xbadc0de);
    const random = prng.random();
    var buffer: [512]u8 = undefined;
    const pieces = [_][]const u8{
        "# branch.head ",    "main",          "\x00",       "1 M. N... ", "2 R. ",                                    "? f",                      "u UU ",
        "# branch.ab +1 -2", "# branch.oid ", "(detached)", "\x00\x00",   "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", "# branch.head (detached)", "\xff\xfe",
    };

    for (0..4000) |_| {
        var length: usize = 0;
        const count = random.intRangeAtMost(usize, 0, 12);
        for (0..count) |_| {
            const piece = pieces[random.uintLessThan(usize, pieces.len)];
            if (length + piece.len > buffer.len) break;
            @memcpy(buffer[length..][0..piece.len], piece);
            length += piece.len;
        }
        const records = buffer[0..length];
        if (parse(records)) |report| {
            if (report.branch) |branch| {
                try std.testing.expect(branch.len > 0);
                try std.testing.expect(branch.len <= max_branch_bytes);
            }
            if (report.commit) |commit| try std.testing.expect(commit.len >= 7);
        }
    }
}
