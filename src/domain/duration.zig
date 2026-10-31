//! Human-readable command durations, tuned for a prompt: milliseconds never
//! take more than five characters, and nothing after a minute is ever shown in
//! tenths.

const std = @import("std");

pub fn format(out: []u8, milliseconds: u64) []const u8 {
    std.debug.assert(out.len >= max_length);
    if (milliseconds < 1_000) {
        return std.fmt.bufPrint(out, "{d}ms", .{milliseconds}) catch unreachable;
    }
    if (milliseconds < 10_000) {
        const tenths = milliseconds / 100;
        return std.fmt.bufPrint(out, "{d}.{d}s", .{ tenths / 10, tenths % 10 }) catch unreachable;
    }
    if (milliseconds < 60_000) {
        return std.fmt.bufPrint(out, "{d}s", .{milliseconds / 1_000}) catch unreachable;
    }
    const seconds = milliseconds / 1_000;
    if (seconds < 3_600) {
        return std.fmt.bufPrint(out, "{d}m{d}s", .{ seconds / 60, seconds % 60 }) catch unreachable;
    }
    return std.fmt.bufPrint(out, "{d}h{d}m", .{ seconds / 3_600, (seconds % 3_600) / 60 }) catch unreachable;
}

/// The longest form is `1h59m`; four bytes plus a guard byte.
pub const max_length = 8;

fn expectFormat(expected: []const u8, milliseconds: u64) !void {
    var buffer: [max_length]u8 = undefined;
    try std.testing.expectEqualStrings(expected, format(&buffer, milliseconds));
}

test "sub-second durations are shown in milliseconds" {
    try expectFormat("0ms", 0);
    try expectFormat("7ms", 7);
    try expectFormat("999ms", 999);
}

test "tenths of a second up to ten seconds" {
    try expectFormat("1.0s", 1_000);
    try expectFormat("1.2s", 1_234);
    try expectFormat("9.9s", 9_999);
}

test "whole seconds up to a minute" {
    try expectFormat("10s", 10_000);
    try expectFormat("42s", 42_500);
    try expectFormat("59s", 59_999);
}

test "minutes and hours" {
    try expectFormat("1m0s", 60_000);
    try expectFormat("2m3s", 123_456);
    try expectFormat("59m59s", 3_599_000);
    try expectFormat("1h0m", 3_600_000);
    try expectFormat("2h5m", 7_500_000);
}
