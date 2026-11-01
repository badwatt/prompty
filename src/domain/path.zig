//! Turns an absolute working directory into the short label shown in the
//! prompt.
//!
//! Two rules, chosen so that the label stays readable at any depth without a
//! configuration knob:
//!
//! - Inside a repository, the label is the repository name plus the directories
//!   below it, always prefixed with the truncation symbol, because the
//!   repository's ancestors were hidden. `~/Projects/code/prompty/src` reads
//!   `…/prompty/src`.
//! - Otherwise the label is the path relative to home (`~` counts as one of the
//!   kept components), or the absolute path, and the last `keep` components are
//!   kept. `~/a/b/c` reads `…/a/b/c`, `/usr/share/doc` is untouched.
//!
//! Both rules are exercised by a table of paths in the tests, including the
//! boundaries where a component is or is not dropped.

const std = @import("std");

/// The longest path a prompt will render. Deeper paths are shortened to their
/// last components, so this bound is never the thing that truncates.
pub const max_display_bytes = 512;

/// The most components that can be kept. Matches the eight-component tail
/// buffer below.
pub const max_keep: u8 = 8;

/// Scratch space for a path plus a suffix (`.git/HEAD`, a gitfile target): two
/// labels' worth, because the label is what gets shown and the rest is what gets
/// opened.
pub const scratch_bytes = max_display_bytes * 2;

pub const truncation_symbol = "…/";

pub const Input = struct {
    cwd: []const u8,
    home: []const u8 = "",
    /// The worktree root of the repository the working directory is in, if any.
    repository_root: ?[]const u8 = null,
    keep: u8 = 3,
};

pub fn display(out: []u8, input: Input) []const u8 {
    std.debug.assert(out.len >= max_display_bytes);
    std.debug.assert(input.keep > 0);
    std.debug.assert(input.keep <= max_keep);

    const cwd = trimTrailingSlashes(input.cwd);
    if (cwd.len == 0) return "/";
    if (std.mem.eql(u8, cwd, "/")) return "/";

    // Inside a repository the name of the repository is the anchor, and
    // everything above it is dropped, which is what the symbol announces.
    if (input.repository_root) |root| {
        if (below(cwd, trimTrailingSlashes(root))) |remainder| {
            const name = baseName(trimTrailingSlashes(root));
            if (name.len > 0) {
                return assemble(out, .{
                    .first = name,
                    .rest = remainder,
                    .keep = input.keep,
                    .rooted = false,
                    .always_truncated = true,
                });
            }
        }
    }

    if (input.home.len > 1) {
        if (below(cwd, trimTrailingSlashes(input.home))) |remainder| {
            return assemble(out, .{
                .first = "~",
                .rest = remainder,
                .keep = input.keep,
                .rooted = false,
                .always_truncated = false,
            });
        }
    }

    return assemble(out, .{
        .first = null,
        .rest = cwd,
        .keep = input.keep,
        .rooted = cwd[0] == '/',
        .always_truncated = false,
    });
}

const Parts = struct {
    /// A pseudo-component rendered verbatim, such as `~` or the repository name.
    first: ?[]const u8,
    /// The remaining slash-separated components, with or without a leading `/`.
    rest: []const u8,
    keep: u8,
    rooted: bool,
    always_truncated: bool,
};

fn assemble(out: []u8, parts: Parts) []const u8 {
    // Keep a rolling window of the last `keep` components: a path may be
    // arbitrarily deep but the prompt only ever shows a bounded tail.
    var tail: [max_keep][]const u8 = undefined;
    var tail_length: usize = 0;
    var total: usize = 0;

    if (parts.first) |first| {
        push(&tail, &tail_length, parts.keep, first);
        total += 1;
    }

    // Tokenising skips repeated separators, which are legal in a path.
    var components = std.mem.tokenizeScalar(u8, parts.rest, '/');
    while (components.next()) |component| {
        push(&tail, &tail_length, parts.keep, component);
        total += 1;
    }

    std.debug.assert(tail_length > 0);

    const truncated = parts.always_truncated or total > parts.keep;
    var written: usize = 0;
    if (truncated) {
        written = clip(out, written, truncation_symbol);
    } else if (parts.rooted) {
        written = clip(out, written, "/");
    }

    for (tail[0..tail_length], 0..) |component, position| {
        if (position > 0) written = clip(out, written, "/");
        if (written + component.len > out.len) {
            // The name does not fit. Take the room for the marker back instead
            // of assuming the separator left it: a component can end flush with
            // the end of the buffer, and then the marker has to replace its
            // tail.
            written = clip(out, cutBackForMarker(out, written), ellipsis);
            break;
        }
        written = clip(out, written, component);
    }

    std.debug.assert(written > 0);
    std.debug.assert(written <= out.len);
    return out[0..written];
}

const ellipsis = "\u{2026}";

fn push(tail: *[max_keep][]const u8, length: *usize, keep: u8, component: []const u8) void {
    if (length.* < keep) {
        tail[length.*] = component;
        length.* += 1;
        return;
    }
    std.mem.copyForwards([]const u8, tail[0 .. keep - 1], tail[1..keep]);
    tail[keep - 1] = component;
}

/// If `path` is `root` or lives inside it, returns the remainder (starting with
/// `/`, or empty). Null when `root` is not a proper ancestor, which also rejects
/// `/home/developer` for the root `/home/dev`.
fn below(path: []const u8, root: []const u8) ?[]const u8 {
    if (root.len == 0) return null;
    if (!std.mem.startsWith(u8, path, root)) return null;
    if (path.len == root.len) return "";
    if (path[root.len] != '/') return null;
    return path[root.len..];
}

fn baseName(path: []const u8) []const u8 {
    std.debug.assert(path.len > 0);
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| return path[slash + 1 ..];
    return path;
}

/// The largest offset at or before `at` that leaves room for the truncation
/// marker and does not split a UTF-8 character.
fn cutBackForMarker(out: []const u8, at: usize) usize {
    var cut = @min(at, out.len - ellipsis.len);
    while (cut > 0 and (out[cut] & 0xc0) == 0x80) cut -= 1;
    return cut;
}

/// Copies as much of `content` as fits, never past the end of `out` and never
/// through the middle of a UTF-8 character, and returns the new length.
///
/// The prompt has a fixed budget: a directory name is not allowed to overflow
/// it. This is not a defensive nicety — with the safety checks off, an
/// over-long path wrote past the buffer and corrupted the stack.
fn clip(out: []u8, at: usize, content: []const u8) usize {
    const start = @min(at, out.len);
    const room = out.len - start;
    var length = @min(content.len, room);
    if (length < content.len) {
        while (length > 0 and (content[length] & 0xc0) == 0x80) length -= 1;
    }
    @memcpy(out[start..][0..length], content[0..length]);
    return start + length;
}

/// Appends `suffix` to `directory` with exactly one separator, or returns null
/// when the result does not fit. An empty directory means the suffix alone,
/// which is what a `PATH` entry for the current directory means.
///
/// Three adapters and the use case each grew their own copy of this, with three
/// slightly different ideas of what to do with a trailing slash and an empty
/// directory. One of them is enough.
pub fn join(out: []u8, directory: []const u8, suffix: []const u8) ?[]u8 {
    if (directory.len == 0) {
        if (suffix.len > out.len) return null;
        @memcpy(out[0..suffix.len], suffix);
        return out[0..suffix.len];
    }
    const separator: usize = @intFromBool(directory[directory.len - 1] != '/');
    const total = directory.len + separator + suffix.len;
    if (total > out.len) return null;
    @memcpy(out[0..directory.len], directory);
    var written = directory.len;
    if (separator == 1) {
        out[written] = '/';
        written += 1;
    }
    @memcpy(out[written..][0..suffix.len], suffix);
    return out[0 .. written + suffix.len];
}

fn trimTrailingSlashes(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

fn expectDisplay(expected: []const u8, input: Input) !void {
    var buffer: [max_display_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(expected, display(&buffer, input));
}

test "home itself collapses to a tilde" {
    try expectDisplay("~", .{ .cwd = "/home/dev", .home = "/home/dev" });
    try expectDisplay("~", .{ .cwd = "/home/dev/", .home = "/home/dev" });
    try expectDisplay("~", .{ .cwd = "/home/dev///", .home = "/home/dev" });
}

test "paths under home keep the tilde until it stops fitting" {
    try expectDisplay("~/src", .{ .cwd = "/home/dev/src", .home = "/home/dev" });
    try expectDisplay("~/a/b", .{ .cwd = "/home/dev/a/b", .home = "/home/dev" });
    // Three levels below home no longer fit in three slots: `~` takes one.
    try expectDisplay("…/a/b/c", .{ .cwd = "/home/dev/a/b/c", .home = "/home/dev" });
    try expectDisplay("…/b/c/d", .{ .cwd = "/home/dev/a/b/c/d", .home = "/home/dev" });
    try expectDisplay("…/a", .{ .cwd = "/home/dev/a", .home = "/home/dev", .keep = 1 });
}

test "absolute paths count only their components" {
    try expectDisplay("/usr/share/doc", .{ .cwd = "/usr/share/doc" });
    try expectDisplay("…/share/doc/x", .{ .cwd = "/usr/share/doc/x" });
    try expectDisplay("/usr", .{ .cwd = "/usr" });
    try expectDisplay("/", .{ .cwd = "/" });
    try expectDisplay("/", .{ .cwd = "" });
}

test "paths that merely look like home are not shortened" {
    try expectDisplay("/home/developer", .{ .cwd = "/home/developer", .home = "/home/dev" });
    try expectDisplay("/home/dev2/src", .{ .cwd = "/home/dev2/src", .home = "/home/dev" });
    try expectDisplay("/usr/bin", .{ .cwd = "/usr/bin", .home = "/" });
}

test "inside a repository the label is anchored on the repository name" {
    // The ancestors of the repository are hidden, so the symbol always shows.
    try expectDisplay("…/prompty", .{
        .cwd = "/home/dev/Projects/code/prompty",
        .home = "/home/dev",
        .repository_root = "/home/dev/Projects/code/prompty",
    });
    try expectDisplay("…/prompty/src", .{
        .cwd = "/home/dev/Projects/code/prompty/src",
        .home = "/home/dev",
        .repository_root = "/home/dev/Projects/code/prompty",
    });
    try expectDisplay("…/prompty/src/domain", .{
        .cwd = "/home/dev/Projects/code/prompty/src/domain",
        .home = "/home/dev",
        .repository_root = "/home/dev/Projects/code/prompty",
    });
    // Deeper than the window: the oldest components go, the symbol stays.
    try expectDisplay("…/domain/and/deeper", .{
        .cwd = "/home/dev/Projects/code/prompty/src/domain/and/deeper",
        .home = "/home/dev",
        .repository_root = "/home/dev/Projects/code/prompty",
    });
}

test "repositories outside home are anchored the same way" {
    try expectDisplay("…/prompty/src", .{
        .cwd = "/srv/build/prompty/src",
        .home = "/home/dev",
        .repository_root = "/srv/build/prompty",
    });
}

test "a repository root that is not an ancestor is ignored" {
    try expectDisplay("~/src", .{
        .cwd = "/home/dev/src",
        .home = "/home/dev",
        .repository_root = "/srv/build/prompty",
    });
    // A repository at the filesystem root has no name to anchor on.
    try expectDisplay("/tmp", .{
        .cwd = "/tmp",
        .home = "/home/dev",
        .repository_root = "/",
    });
}

test "keep eight is enough for seven components under home" {
    var buffer: [max_display_bytes]u8 = undefined;
    const home = "/home/dev";
    try std.testing.expectEqualStrings(
        "~/1/2/3/4/5/6/7",
        display(&buffer, .{ .cwd = home ++ "/1/2/3/4/5/6/7", .home = home, .keep = max_keep }),
    );
    try std.testing.expectEqualStrings(
        "…/1/2/3/4/5/6/7/8",
        display(&buffer, .{ .cwd = home ++ "/1/2/3/4/5/6/7/8", .home = home, .keep = max_keep }),
    );
}

test "unicode component names are preserved" {
    try expectDisplay("~/ñandú/日本語", .{
        .cwd = "/home/dev/ñandú/日本語",
        .home = "/home/dev",
    });
}

test "relative paths never produce an empty label" {
    try expectDisplay("a/b", .{ .cwd = "a/b" });
    try expectDisplay("…/b/c", .{ .cwd = "a/b/c", .keep = 2 });
}

test "repeated separators are not components" {
    try expectDisplay("/usr/bin", .{ .cwd = "//usr///bin" });
    try expectDisplay("~/a/b", .{ .cwd = "/home/dev//a///b", .home = "/home/dev" });
}

test "the anchor name is the last component of the repository root" {
    try std.testing.expectEqualStrings("prompty", baseName("/home/dev/prompty"));
    try std.testing.expectEqualStrings("x", baseName("/x"));
    // A root without a separator still has a name.
    try std.testing.expectEqualStrings("prompty", baseName("prompty"));
}

/// Whatever the input, the label fits, is valid UTF-8 and says when it was cut.
fn expectBounded(input: Input) !void {
    var buffer: [max_display_bytes]u8 = undefined;
    const label = display(&buffer, input);
    try std.testing.expect(label.len <= max_display_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(label));
    try std.testing.expect(label.len > 0);
}

test "a name longer than the whole budget is cut, not overflowed" {
    var name: [4000]u8 = @splat('a');
    var cwd_buffer: [4100]u8 = undefined;
    @memcpy(cwd_buffer[0..5], "/tmp/");
    @memcpy(cwd_buffer[5..][0..name.len], &name);
    const cwd = cwd_buffer[0 .. 5 + name.len];

    var out: [max_display_bytes]u8 = undefined;
    const label = display(&out, .{ .cwd = cwd, .home = "/tmp" });
    try std.testing.expect(label.len <= max_display_bytes);
    try std.testing.expect(std.mem.endsWith(u8, label, ellipsis));
    try std.testing.expect(std.unicode.utf8ValidateSlice(label));
}

test "cutting never splits a multi-byte character" {
    // Multi-byte names that straddle the boundary, at every offset.
    const pieces = "ñ日本語🚀";
    var cwd: [2048]u8 = undefined;
    var length: usize = 0;
    length += (try std.fmt.bufPrint(cwd[length..], "/home/dev/", .{})).len;
    while (length + 3 * pieces.len < cwd.len) {
        @memcpy(cwd[length..][0 .. 3 * pieces.len], (pieces ++ pieces ++ pieces));
        length += 3 * pieces.len;
    }
    var out: [max_display_bytes]u8 = undefined;
    const label = display(&out, .{ .cwd = cwd[0..length], .home = "/home/dev" });
    try std.testing.expect(label.len <= max_display_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(label));
}

test "three long components are all bounded" {
    var long: [300]u8 = @splat('x');
    var cwd: [1024]u8 = undefined;
    const path = try std.fmt.bufPrint(&cwd, "/home/dev/{s}/{s}/{s}", .{ &long, &long, &long });
    try expectBounded(.{ .cwd = path, .home = "/home/dev" });
}

test "a component that ends flush with the buffer still leaves room for the mark" {
    // The first name fills the budget exactly, so the second one has nowhere to
    // go and the marker has to take its place. Assuming there was room for it
    // ran the copy past the end of the buffer.
    var cwd: [max_display_bytes + 8]u8 = undefined;
    cwd[0] = '/';
    @memset(cwd[1..max_display_bytes], 'a');
    cwd[max_display_bytes] = '/';
    cwd[max_display_bytes + 1] = 'b';

    var out: [max_display_bytes]u8 = undefined;
    const label = display(&out, .{ .cwd = cwd[0 .. max_display_bytes + 2] });
    try std.testing.expectEqual(@as(usize, max_display_bytes), label.len);
    try std.testing.expect(std.mem.endsWith(u8, label, ellipsis));
    try std.testing.expect(std.unicode.utf8ValidateSlice(label));
}

test "the room for the mark is taken back to a character boundary" {
    var out: [max_display_bytes]u8 = undefined;
    @memset(&out, 'a');
    // A two-byte character straddling the limit: its continuation byte sits
    // where the marker would start, so the cut has to step back one more byte.
    const limit = out.len - ellipsis.len;
    out[limit - 1] = 0xc3;
    out[limit] = 0xb1;
    try std.testing.expectEqual(limit - 1, cutBackForMarker(&out, out.len));
}

test "a label that fills the budget exactly is not marked as cut" {
    var out: [max_display_bytes]u8 = undefined;
    var cwd: [max_display_bytes]u8 = undefined;
    @memset(&cwd, 'y');
    cwd[0] = '/';
    const label = display(&out, .{ .cwd = &cwd });
    try std.testing.expectEqual(@as(usize, max_display_bytes), label.len);
    try std.testing.expect(!std.mem.endsWith(u8, label, ellipsis));
}

/// Fills `buffer` with random bytes drawn from `alphabet`.
fn randomSlice(random: std.Random, buffer: []u8, alphabet: []const u8) []const u8 {
    const length = random.intRangeAtMost(usize, 0, buffer.len);
    for (buffer[0..length]) |*byte| {
        byte.* = alphabet[random.uintLessThan(usize, alphabet.len)];
    }
    return buffer[0..length];
}

test "property: any bytes produce a bounded, non-empty label" {
    // The path comes from the environment, so the property is about *any* byte
    // sequence: the label must stay inside its budget and never be empty.
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    var cwd_buffer: [1024]u8 = undefined;
    var home_buffer: [128]u8 = undefined;
    var root_buffer: [128]u8 = undefined;
    var out: [max_display_bytes]u8 = undefined;

    for (0..3000) |_| {
        const cwd = randomSlice(random, &cwd_buffer, "/abZ09\t\x00\xff.\xf1-");
        const home = randomSlice(random, &home_buffer, "/abZ0.");
        const root = randomSlice(random, &root_buffer, "/abZ0.");
        const label = display(&out, .{
            .cwd = cwd,
            .home = home,
            .repository_root = root,
            .keep = random.intRangeAtMost(u8, 1, max_keep),
        });
        try std.testing.expect(label.len > 0);
        try std.testing.expect(label.len <= max_display_bytes);
        try std.testing.expect(label.ptr == &out or label.len == 1);
    }
}

test "property: valid UTF-8 in, valid UTF-8 out" {
    // Component names are bytes the filesystem accepts; when they are well
    // formed the label has to be as well, however it gets cut.
    var prng = std.Random.DefaultPrng.init(0xc0ffee);
    const random = prng.random();
    const pieces = [_][]const u8{ "a", "ñ", "日", "🚀", "Z", "9", ".", "-" };
    var cwd_buffer: [512]u8 = undefined;
    var out: [max_display_bytes]u8 = undefined;

    for (0..1500) |_| {
        var length: usize = 0;
        const count = random.intRangeAtMost(usize, 1, 40);
        for (0..count) |_| {
            const piece = pieces[random.uintLessThan(usize, pieces.len)];
            if (length + piece.len > cwd_buffer.len) break;
            @memcpy(cwd_buffer[length..][0..piece.len], piece);
            length += piece.len;
        }
        const label = display(&out, .{ .cwd = cwd_buffer[0..length], .home = "/home/dev" });
        try std.testing.expect(std.unicode.utf8ValidateSlice(label));
        try std.testing.expect(label.len > 0);
    }
}

test "join adds one separator and refuses what does not fit" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a/b", join(&buffer, "a", "b").?);
    try std.testing.expectEqualStrings("a/b", join(&buffer, "a/", "b").?);
    try std.testing.expectEqualStrings("/b", join(&buffer, "/", "b").?);
    // An empty directory is the current directory: no separator, just the name.
    try std.testing.expectEqualStrings("b", join(&buffer, "", "b").?);
    var small: [4]u8 = undefined;
    try std.testing.expectEqual(@as(?[]u8, null), join(&small, "abc", "de"));
    try std.testing.expectEqual(@as(?[]u8, null), join(&small, "", "abcde"));
}
