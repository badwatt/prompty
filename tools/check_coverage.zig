//! Coverage gate: fails unless kcov reports 100% line coverage for every
//! source file it saw.
//!
//! Usage: check_coverage <merged coverage.json> <src root>

const std = @import("std");

/// A prompt has far more than this many source lines; a report with fewer files
/// than this means the include pattern broke, not that the code is covered.
const minimum_files = 10;

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

    var failures: usize = 0;
    var measured: usize = 0;
    var total_lines: u64 = 0;
    for (files) |item| {
        const object = item.object;
        const path = object.get("file").?.string;
        if (!std.mem.startsWith(u8, path, source_root)) continue;
        measured += 1;
        total_lines += asInteger(object.get("total_lines"));
        const percent = asNumber(object.get("percent_covered"));
        if (percent < 100.0) {
            failures += 1;
            std.debug.print("uncovered: {s} ({d:.2}%)\n", .{ path, percent });
        }
    }

    if (measured < minimum_files) {
        std.debug.print("coverage: only {d} source files reported; check the include pattern\n", .{measured});
        return 1;
    }
    if (failures > 0) {
        std.debug.print("coverage: {d} of {d} files are below 100%\n", .{ failures, measured });
        return 1;
    }

    std.debug.print("coverage: 100.00% of {d} source files ({d} lines)\n", .{ measured, total_lines });
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

fn asInteger(value: ?std.json.Value) u64 {
    const actual = value orelse return 0;
    return switch (actual) {
        .string => |text| std.fmt.parseInt(u64, text, 10) catch 0,
        .integer => |number| @intCast(@max(number, 0)),
        .float => |number| @intFromFloat(@max(number, 0.0)),
        else => 0,
    };
}
