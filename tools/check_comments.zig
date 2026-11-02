//! Comment guard: only documentation may live in the source.
//!
//! `//!` documents a module and `///` documents a declaration. Anything else
//! that starts with `//` — a note, a rationale, a trailing remark — is a comment,
//! and this project does not keep them. Reasoning belongs in DESIGN.md, where it
//! can be found again.
//!
//! Usage: check_comments <source root> [more roots...]

const std = @import("std");

/// A guard that read nothing is worse than no guard.
const minimum_files = 12;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len < 2) {
        std.debug.print("usage: {s} <source root> [more roots...]\n", .{argv[0]});
        return 2;
    }

    var checked: usize = 0;
    var failures: usize = 0;
    for (argv[1..]) |root| {
        if (std.mem.endsWith(u8, root, ".zig")) {
            const source = std.Io.Dir.cwd().readFileAlloc(io, root, arena, .limited(256 * 1024)) catch |err| {
                std.debug.print("cannot read {s}: {s}\n", .{ root, @errorName(err) });
                return 2;
            };
            checked += 1;
            failures += report(arena, root, source);
            continue;
        }

        var directory = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| {
            std.debug.print("cannot read {s}: {s}\n", .{ root, @errorName(err) });
            return 2;
        };
        var walker = try directory.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            const source = try directory.readFileAlloc(io, entry.path, arena, .limited(256 * 1024));
            checked += 1;
            const label = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, entry.path });
            failures += report(arena, label, source);
        }
    }

    if (checked < minimum_files) {
        std.debug.print("comments: only {d} files read; check the source roots\n", .{checked});
        return 1;
    }
    if (failures > 0) {
        std.debug.print("comments: {d} plain comments in {d} files\n", .{ failures, checked });
        return 1;
    }
    std.debug.print("comments: {d} files, documentation only\n", .{checked});
    return 0;
}

/// Prints every plain comment in `source` and returns how many there were.
fn report(arena: std.mem.Allocator, label: []const u8, source: []const u8) usize {
    _ = arena;
    var found: usize = 0;
    var line_number: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        line_number += 1;
        if (plainComment(line)) |comment| {
            found += 1;
            std.debug.print("{s}:{d}: {s}\n", .{ label, line_number, comment });
        }
    }
    return found;
}

/// The comment on this line when it is a plain one, or null when the line has
/// none, only documentation, or a `//` that belongs to a string literal.
fn plainComment(line: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "\\\\")) return null;

    var in_string = false;
    var index: usize = 0;
    while (index + 1 < line.len) : (index += 1) {
        const byte = line[index];
        if (in_string) {
            if (byte == '\\') {
                index += 1;
                continue;
            }
            if (byte == '"') in_string = false;
            continue;
        }
        if (byte == '"') {
            in_string = true;
            continue;
        }
        if (byte != '/' or line[index + 1] != '/') continue;

        const comment = std.mem.trimEnd(u8, line[index..], " \t");
        const body = comment[2..];
        if (body.len == 0 or body[0] == '/' or body[0] == '!') return null;
        return comment;
    }
    return null;
}

test "documentation is not a comment" {
    try std.testing.expectEqual(@as(?[]const u8, null), plainComment("//! module"));
    try std.testing.expectEqual(@as(?[]const u8, null), plainComment("/// declaration"));
    try std.testing.expectEqual(@as(?[]const u8, null), plainComment("    /// indented"));
    try std.testing.expectEqual(@as(?[]const u8, null), plainComment(""));
}

test "a plain comment is found wherever it starts" {
    try std.testing.expectEqualStrings("// note", plainComment("// note").?);
    try std.testing.expectEqualStrings("// note", plainComment("    // note").?);
    try std.testing.expectEqualStrings("// trailing", plainComment("const x = 1; // trailing").?);
    try std.testing.expectEqualStrings("//// banner", plainComment("//// banner").?);
}

test "a // inside a string is not a comment" {
    try std.testing.expectEqual(@as(?[]const u8, null), plainComment(
        "    \"  local now=${EPOCHREALTIME//[.,]/}\\n\" ++",
    ));
    try std.testing.expectEqual(@as(?[]const u8, null), plainComment("    const url = \"https://example.com\";"));
    try std.testing.expectEqual(@as(?[]const u8, null), plainComment("    const quote = \"a \\\" // b\";"));
    try std.testing.expectEqual(@as(?[]const u8, null), plainComment("\\\\ // inside a multiline string"));
}
