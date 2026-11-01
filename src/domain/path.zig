//! Turns an absolute working directory into the short label shown in the
//! prompt: `~` for the home directory, and only the last `keep` components when
//! the path goes deeper than the prompt can afford.
//!
//! `keep` counts display components, and the `~` marker is one of them: three
//! levels below home do not fit in three, because `~` already took a slot. That
//! is the rule starship's `truncation_length` follows, and matching it means a
//! prompt swap does not change how the path reads.

const std = @import("std");

/// The longest path a prompt will render. Deeper paths are shortened to their
/// last components, so this bound is never the thing that truncates.
pub const max_display_bytes = 512;

/// The most components that can be kept. Matches the eight-component tail
/// buffer below.
pub const max_keep: u8 = 8;

pub fn display(out: []u8, cwd: []const u8, home: []const u8, keep: u8) []const u8 {
    std.debug.assert(out.len >= max_display_bytes);
    std.debug.assert(keep > 0);
    std.debug.assert(keep <= max_keep);

    const path = trimTrailingSlashes(cwd);
    if (path.len == 0) return "/";

    var rest = path;
    var shortened_prefix: []const u8 = "";
    if (home.len > 1 and std.mem.startsWith(u8, path, home)) {
        const after_home = path[home.len..];
        if (after_home.len == 0) return "~";
        if (after_home[0] == '/') {
            shortened_prefix = "~";
            rest = trimTrailingSlashes(after_home[1..]);
            if (rest.len == 0) return "~";
        }
    }

    const rooted = rest.len > 0 and rest[0] == '/' and shortened_prefix.len == 0;
    // `~` occupies a slot exactly like a directory name does.
    const home_marker: usize = @intFromBool(shortened_prefix.len > 0);

    // Keep the last `keep` components: a path may be arbitrarily deep but the
    // prompt only ever shows a bounded tail.
    var tail: [max_keep][]const u8 = undefined;
    var tail_length: usize = 0;
    var total: usize = 0;
    var index: usize = 0;
    while (index < rest.len) {
        while (index < rest.len and rest[index] == '/') index += 1;
        const start = index;
        while (index < rest.len and rest[index] != '/') index += 1;
        if (index == start) break;
        if (tail_length < keep) {
            tail[tail_length] = rest[start..index];
            tail_length += 1;
        } else {
            std.mem.copyForwards([]const u8, tail[0 .. keep - 1], tail[1..keep]);
            tail[keep - 1] = rest[start..index];
        }
        total += 1;
    }

    var written: usize = 0;
    for (tail[0..tail_length], 0..) |component, position| {
        if (position == 0) {
            if (total + home_marker > keep) {
                written = append(out, written, "…/");
            } else if (shortened_prefix.len > 0) {
                written = append(out, written, "~/");
            } else if (rooted) {
                written = append(out, written, "/");
            }
        } else {
            written = append(out, written, "/");
        }
        written = append(out, written, component);
    }
    std.debug.assert(written > 0);
    return out[0..written];
}

fn append(out: []u8, at: usize, content: []const u8) usize {
    std.debug.assert(at + content.len <= out.len);
    @memcpy(out[at..][0..content.len], content);
    return at + content.len;
}

fn trimTrailingSlashes(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

fn expectDisplay(expected: []const u8, cwd: []const u8, keep: u8) !void {
    var buffer: [max_display_bytes]u8 = undefined;
    const actual = display(&buffer, cwd, "/home/dev", keep);
    try std.testing.expectEqualStrings(expected, actual);
}

test "home itself collapses to a tilde" {
    try expectDisplay("~", "/home/dev", 3);
}

test "paths under home keep the tilde" {
    try expectDisplay("~", "/home/dev/", 3);
    try expectDisplay("~/src", "/home/dev/src", 3);
    try expectDisplay("~/src/prompty", "/home/dev/src/prompty", 3);
}

test "the tilde counts as one of the kept components" {
    // Three levels below home do not fit in three slots, because `~` takes one.
    try expectDisplay("~/a/b", "/home/dev/a/b", 3);
    try expectDisplay("…/a/b/c", "/home/dev/a/b/c", 3);
    try expectDisplay("…/b/c/d", "/home/dev/a/b/c/d", 3);
    // And with a single slot the marker is the first thing to go.
    try expectDisplay("…/a", "/home/dev/a", 1);
    try expectDisplay("~", "/home/dev", 1);
}

test "absolute paths count only their components" {
    // The root slash is not a component, so three names still fit.
    try expectDisplay("/usr/share/doc", "/usr/share/doc", 3);
    try expectDisplay("…/share/doc/x", "/usr/share/doc/x", 3);
}

test "keep eight is enough for seven components under home" {
    var buffer: [max_display_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "~/1/2/3/4/5/6/7",
        display(&buffer, "/home/dev/1/2/3/4/5/6/7", "/home/dev", max_keep),
    );
    try std.testing.expectEqualStrings(
        "…/1/2/3/4/5/6/7/8",
        display(&buffer, "/home/dev/1/2/3/4/5/6/7/8", "/home/dev", max_keep),
    );
}

test "deep paths keep only the last components" {
    try expectDisplay("…/c/d", "/home/dev/a/b/c/d", 2);
    try expectDisplay("…/b/c/d", "/home/dev/a/b/c/d", 3);
    try expectDisplay("…/d", "/home/dev/a/b/d", 1);
}

test "paths outside home keep their root" {
    try expectDisplay("/", "/", 3);
    try expectDisplay("/usr", "/usr", 3);
    try expectDisplay("/usr/share", "/usr/share", 3);
    try expectDisplay("…/share/doc", "/usr/share/doc", 2);
}

test "paths that merely look like home are not shortened" {
    try expectDisplay("/home/developer", "/home/developer", 3);
    try expectDisplay("/home/dev2/src", "/home/dev2/src", 3);
}

test "relative and odd paths never produce an empty label" {
    try expectDisplay("/", "", 3);
    try expectDisplay("a/b", "a/b", 2);
    try expectDisplay("~", "/home/dev///", 3);
}

test "unicode component names are preserved" {
    try expectDisplay("~/ñandú/日本語", "/home/dev/ñandú/日本語", 3);
}

test "keeping the maximum number of components works" {
    var buffer: [max_display_bytes]u8 = undefined;
    const deep = "/home/dev/1/2/3/4/5/6/7/8/9";
    try std.testing.expectEqualStrings(
        "…/2/3/4/5/6/7/8/9",
        display(&buffer, deep, "/home/dev", max_keep),
    );
}

test "home equal to root is not treated as home" {
    var buffer: [max_display_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("/usr/bin", display(&buffer, "/usr/bin", "/", 3));
}
