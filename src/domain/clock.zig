//! Unix time to the wall clock a human reads, with no libc and no allocations.

const std = @import("std");

pub const TimeOfDay = struct {
    hour: u8,
    minute: u8,
};

/// Applies a UTC offset (in seconds, as found in a TZif zone) to a Unix
/// timestamp and extracts the wall clock time.
///
/// Timestamps before the epoch are clamped to the epoch instead of failing: a
/// prompt has no business crashing over a clock that is set to 1969. The upper
/// end is clamped to what `EpochSeconds` can hold, which is the year 2106.
pub fn fromUnix(unix_seconds: i64, offset_seconds: i32) TimeOfDay {
    const shifted: i128 = @as(i128, unix_seconds) + @as(i128, offset_seconds);
    const seconds: u64 = if (shifted < 0)
        0
    else
        @intCast(@min(shifted, std.math.maxInt(u32)));

    const epoch = std.time.epoch.EpochSeconds{ .secs = seconds };
    const day_seconds = epoch.getDaySeconds();
    return .{
        .hour = @intCast(day_seconds.getHoursIntoDay()),
        .minute = @intCast(day_seconds.getMinutesIntoHour()),
    };
}

pub const max_length = 5;

pub fn format(out: []u8, time: TimeOfDay) []const u8 {
    std.debug.assert(out.len >= max_length);
    std.debug.assert(time.hour < 24);
    std.debug.assert(time.minute < 60);
    return std.fmt.bufPrint(out, "{d:0>2}:{d:0>2}", .{ time.hour, time.minute }) catch unreachable;
}

fn expectTime(expected: TimeOfDay, unix_seconds: i64, offset_seconds: i32) !void {
    try std.testing.expectEqual(expected, fromUnix(unix_seconds, offset_seconds));
}

test "converts UTC timestamps" {
    try expectTime(.{ .hour = 0, .minute = 0 }, 0, 0);
    try expectTime(.{ .hour = 12, .minute = 34 }, 45_240, 0);
    try expectTime(.{ .hour = 23, .minute = 59 }, 86_340, 0);
}

test "applies positive and negative offsets across day boundaries" {
    // 2024-01-01T00:30:00Z in Madrid (UTC+1) is 01:30, and in New York
    // (UTC-5) it is still the previous day at 19:30.
    try expectTime(.{ .hour = 1, .minute = 30 }, 1_704_069_000, 3_600);
    try expectTime(.{ .hour = 19, .minute = 30 }, 1_704_069_000, -18_000);
    // Half-hour zones exist.
    try expectTime(.{ .hour = 6, .minute = 0 }, 0, 21_600);
    try expectTime(.{ .hour = 5, .minute = 30 }, 0, 19_800);
    // Negative timestamps clamp to the epoch instead of wrapping.
    try expectTime(.{ .hour = 0, .minute = 0 }, -100, 0);
    try expectTime(.{ .hour = 0, .minute = 0 }, -100, -3_600);
}

test "formats with zero padding" {
    var buffer: [max_length]u8 = undefined;
    try std.testing.expectEqualStrings("00:00", format(&buffer, .{ .hour = 0, .minute = 0 }));
    try std.testing.expectEqualStrings("09:05", format(&buffer, .{ .hour = 9, .minute = 5 }));
    try std.testing.expectEqualStrings("23:59", format(&buffer, .{ .hour = 23, .minute = 59 }));
}
