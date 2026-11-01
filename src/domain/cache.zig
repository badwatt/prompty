//! Where the detected terminal background is remembered between prompts.
//!
//! Detection needs to talk to the terminal, which costs a round trip. A prompt
//! cannot pay that on every command, so the answer is cached once and read back
//! with a single small file read.

const std = @import("std");

const path_mod = @import("path.zig");

pub const relative_path = "prompty/theme";

pub const max_path_bytes = 4096;

/// `$XDG_CACHE_HOME/prompty/theme`, falling back to the historical
/// `$HOME/.cache/prompty/theme`.
pub fn path(out: []u8, xdg_cache_home: ?[]const u8, home: ?[]const u8) ?[]const u8 {
    std.debug.assert(out.len >= max_path_bytes);
    if (xdg_cache_home) |cache_home| {
        if (cache_home.len > 0) return join(out, cache_home, relative_path);
    }
    if (home) |home_directory| {
        if (home_directory.len > 0) return join(out, home_directory, ".cache/" ++ relative_path);
    }
    return null;
}

const join = path_mod.join;

test "uses the XDG cache when it is set" {
    var buffer: [max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/cache/prompty/theme",
        path(&buffer, "/cache", "/home/dev").?,
    );
    try std.testing.expectEqualStrings(
        "/cache/prompty/theme",
        path(&buffer, "/cache/", "/home/dev").?,
    );
}

test "falls back to home and ignores empty variables" {
    var buffer: [max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/home/dev/.cache/prompty/theme",
        path(&buffer, null, "/home/dev").?,
    );
    try std.testing.expectEqualStrings(
        "/home/dev/.cache/prompty/theme",
        path(&buffer, "", "/home/dev").?,
    );
}

test "no cache location without either variable" {
    var buffer: [max_path_bytes]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), path(&buffer, null, null));
    try std.testing.expectEqual(@as(?[]const u8, null), path(&buffer, "", ""));
}
