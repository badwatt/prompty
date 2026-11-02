//! Human-readable command durations, tuned for a prompt: the ladder is
//! milliseconds, seconds, minutes, hours, days; the tail unit is written only
//! while the leading one is a single digit; and a unit worth zero is never
//! written at all. Realistic durations come out at five characters or fewer.

const std = @import("std");

pub fn format(out: []u8, milliseconds: u64) []const u8 {
    std.debug.assert(out.len >= max_length);
    if (milliseconds < 1_000) return print(out, "{d}ms", .{milliseconds});
    if (milliseconds < 10_000) {
        const tenths = milliseconds / 100;
        return print(out, "{d}.{d}s", .{ tenths / 10, tenths % 10 });
    }
    if (milliseconds < 60_000) return print(out, "{d}s", .{milliseconds / 1_000});

    const seconds = milliseconds / 1_000;
    if (seconds < 3_600) {
        const minutes = seconds / 60;
        const rest = seconds % 60;
        if (minutes < 10 and rest != 0) return print(out, "{d}m{d}s", .{ minutes, rest });
        return print(out, "{d}m", .{minutes});
    }
    if (seconds < 86_400) {
        const hours = seconds / 3_600;
        const rest = (seconds % 3_600) / 60;
        if (hours < 10 and rest != 0) return print(out, "{d}h{d}m", .{ hours, rest });
        return print(out, "{d}h", .{hours});
    }
    const days = seconds / 86_400;
    const rest = (seconds % 86_400) / 3_600;
    if (days < 10 and rest != 0) return print(out, "{d}d{d}h", .{ days, rest });
    return print(out, "{d}d", .{days});
}

fn print(out: []u8, comptime template: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(out, template, args) catch unreachable;
}

/// The longest form any `u64` of milliseconds produces: `213503982334d`, the
/// days in a hundred and eighty-four quadrillion milliseconds. The formatter
/// must not be able to overrun its buffer on a value it was handed.
pub const max_length = 13;

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
    try expectFormat("1m", 60_000);
    try expectFormat("1m5s", 65_000);
    try expectFormat("2m3s", 123_456);
    try expectFormat("9m59s", 599_000);
    try expectFormat("10m", 600_000);
    try expectFormat("11m", 719_000);
    try expectFormat("59m", 3_599_000);
    try expectFormat("1h", 3_600_000);
    try expectFormat("2h5m", 7_500_000);
    try expectFormat("9h59m", 35_940_000);
    try expectFormat("10h", 36_000_000);
    try expectFormat("23h", 82_800_000);
}

test "days appear at the twenty-fourth hour, and then stop at two digits" {
    try expectFormat("1d", 86_400_000);
    try expectFormat("1d3h", 97_200_000);
    try expectFormat("9d23h", 860_400_000);
    try expectFormat("10d", 864_000_000);
    try expectFormat("41d", 3_542_400_000);
    try expectFormat("999d", 86_313_600_000);
}

test "no unit that is worth zero is ever written" {
    try expectFormat("5m", 300_000);
    try expectFormat("5h", 18_000_000);
    try expectFormat("5d", 432_000_000);
}

test "the absurd end of the range is exactly as long as the buffer" {
    var buffer: [max_length]u8 = undefined;
    const formatted = format(&buffer, std.math.maxInt(u64));
    try std.testing.expectEqualStrings("213503982334d", formatted);
    try std.testing.expectEqual(@as(usize, max_length), formatted.len);
}
