//! Layer guard: the hexagon's arrows, checked rather than remembered.
//!
//! The domain is pure, so it may not import the ports, the adapters or the
//! application; the ports may not import the adapters. A prompt that reached for
//! `std.os.linux` from inside the domain would stop being testable without a
//! machine, which is the reason this shape exists at all.
//!
//! Usage: check_layers <source root>

const std = @import("std");

const Layer = struct {
    directory: []const u8,
    forbidden: []const []const u8,
};

const layers = [_]Layer{
    .{
        .directory = "domain",
        .forbidden = &.{ "../ports", "../adapters", "../application" },
    },
    .{
        .directory = "ports",
        .forbidden = &.{ "../adapters", "../application" },
    },
};

/// A guard that read nothing is worse than no guard.
const minimum_files = 12;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len != 2) {
        std.debug.print("usage: {s} <src-root>\n", .{argv[0]});
        return 2;
    }
    const root = argv[1];

    var checked: usize = 0;
    var failures: usize = 0;
    for (layers) |layer| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, layer.directory });
        const directory = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
            std.debug.print("cannot read {s}: {s}\n", .{ path, @errorName(err) });
            return 2;
        };

        var walker = try directory.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            const source = try directory.readFileAlloc(io, entry.path, arena, .limited(64 * 1024));
            checked += 1;
            for (layer.forbidden) |forbidden| {
                const needle = try std.fmt.allocPrint(arena, "@import(\"{s}", .{forbidden});
                if (std.mem.indexOf(u8, source, needle)) |_| {
                    failures += 1;
                    std.debug.print("{s}/{s} imports {s}\n", .{ path, entry.path, forbidden });
                }
            }
        }
    }

    if (checked < minimum_files) {
        std.debug.print("layers: only {d} files read; check the source root\n", .{checked});
        return 1;
    }
    if (failures > 0) {
        std.debug.print("layers: {d} forbidden imports in {d} files\n", .{ failures, checked });
        return 1;
    }
    std.debug.print("layers: {d} files, no import leaves its layer\n", .{checked});
    return 0;
}
