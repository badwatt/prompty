//! Coverage gate: fails unless kcov reports 100% line coverage for every
//! source file, and every source file actually appears in the report.
//!
//! Usage: check_coverage <merged coverage.json> <src root> <project root>

const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len != 3) {
        std.debug.print("usage: {s} <coverage.json> <src-root>\n", .{argv[0]});
        return 2;
    }
    const report_path = argv[1];
    const source_root = argv[2];

    const text = std.Io.Dir.cwd().readFileAlloc(io, report_path, arena, .limited(8 << 20)) catch |err| {
        std.debug.print("cannot read {s}: {s}\n", .{ report_path, @errorName(err) });
        return 2;
    };

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, text, .{});
    const files = parsed.value.object.get("files").?.array.items;

    // Collect what kcov measured, keyed by absolute path.
    var failures: usize = 0;
    var measured: usize = 0;
    for (files) |item| {
        const object = item.object;
        const path = object.get("file").?.string;
        if (!std.mem.startsWith(u8, path, source_root)) continue;
        measured += 1;
        const percent = asNumber(object.get("percent_covered"));
        if (percent < 100.0) {
            failures += 1;
            std.debug.print("uncovered: {s} ({d:.2}%)\n", .{ path, percent });
        }
    }

    // Every source file must appear; a file nobody referenced would otherwise
    // be silently missing from a "100%" report.
    var missing: usize = 0;
    var walker = try std.Io.Dir.cwd().walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.path, "src/")) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        if (std.mem.endsWith(u8, entry.path, "tests.zig")) continue;
        if (!appearsIn(files, source_root, entry.path)) {
            missing += 1;
            std.debug.print("never executed: {s}\n", .{entry.path});
        }
    }

    if (failures > 0 or missing > 0) {
        std.debug.print("coverage: {d} file(s) below 100%, {d} file(s) missing\n", .{
            failures,
            missing,
        });
        return 1;
    }

    std.debug.print("coverage: 100.00% of {d} source files\n", .{measured});
    return 0;
}

fn asNumber(value: ?std.json.Value) f64 {
    const actual = value orelse return 0.0;
    return switch (actual) {
        .string => |text| std.fmt.parseFloat(f64, text) catch 0.0,
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        else => 0.0,
    };
}

fn appearsIn(files: []const std.json.Value, source_root: []const u8, relative_path: []const u8) bool {
    for (files) |item| {
        const path = item.object.get("file") orelse continue;
        if (path != .string) continue;
        if (!std.mem.startsWith(u8, path.string, source_root)) continue;
        if (std.mem.endsWith(u8, path.string, relative_path)) return true;
    }
    return false;
}
