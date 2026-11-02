//! 24-bit colour values and the two operations the prompt needs: parsing a
//! `#rrggbb` string and blending two colours.

const std = @import("std");

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    /// Parses `#rrggbb` or `rrggbb`. Returns null for anything else, because a
    /// prompt must never crash on a malformed colour from the environment.
    pub fn parse(text: []const u8) ?Rgb {
        var body = text;
        if (body.len > 0 and body[0] == '#') body = body[1..];
        if (body.len != 6) return null;
        return .{
            .r = hexPair(body[0..2]) orelse return null,
            .g = hexPair(body[2..4]) orelse return null,
            .b = hexPair(body[4..6]) orelse return null,
        };
    }

    /// Linear sRGB-space blend; `amount` is how much of `other` to take.
    pub fn blend(self: Rgb, other: Rgb, amount: f32) Rgb {
        std.debug.assert(amount >= 0.0);
        std.debug.assert(amount <= 1.0);
        return .{
            .r = blendChannel(self.r, other.r, amount),
            .g = blendChannel(self.g, other.g, amount),
            .b = blendChannel(self.b, other.b, amount),
        };
    }
};

fn blendChannel(from: u8, to: u8, amount: f32) u8 {
    const value = @as(f32, @floatFromInt(from)) +
        (@as(f32, @floatFromInt(to)) - @as(f32, @floatFromInt(from))) * amount;
    return @intFromFloat(std.math.clamp(value, 0.0, 255.0));
}

fn hexPair(pair: []const u8) ?u8 {
    std.debug.assert(pair.len == 2);
    const high = hexDigit(pair[0]) orelse return null;
    const low = hexDigit(pair[1]) orelse return null;
    return high * 16 + low;
}

fn hexDigit(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

test "parse accepts both hash-prefixed and bare values" {
    try std.testing.expectEqual(Rgb{ .r = 0x1e, .g = 0x1e, .b = 0x2e }, Rgb.parse("#1e1e2e").?);
    try std.testing.expectEqual(Rgb{ .r = 0x1e, .g = 0x1e, .b = 0x2e }, Rgb.parse("1e1e2e").?);
    try std.testing.expectEqual(Rgb{ .r = 0xaa, .g = 0xbb, .b = 0xcc }, Rgb.parse("#AABBCC").?);
}

test "parse rejects malformed colours" {
    try std.testing.expectEqual(@as(?Rgb, null), Rgb.parse(""));
    try std.testing.expectEqual(@as(?Rgb, null), Rgb.parse("#"));
    try std.testing.expectEqual(@as(?Rgb, null), Rgb.parse("#1e1e2"));
    try std.testing.expectEqual(@as(?Rgb, null), Rgb.parse("#1e1e2e0"));
    try std.testing.expectEqual(@as(?Rgb, null), Rgb.parse("#1e1e2g"));
    try std.testing.expectEqual(@as(?Rgb, null), Rgb.parse("#z11e2e"));
    try std.testing.expectEqual(@as(?Rgb, null), Rgb.parse("#1e1e2!"));
}

test "blend interpolates each channel" {
    const black = Rgb{ .r = 0, .g = 0, .b = 0 };
    const white = Rgb{ .r = 255, .g = 255, .b = 255 };
    try std.testing.expectEqual(black, black.blend(white, 0.0));
    try std.testing.expectEqual(white, black.blend(white, 1.0));
    try std.testing.expectEqual(Rgb{ .r = 127, .g = 127, .b = 127 }, black.blend(white, 0.5));
    try std.testing.expectEqual(
        Rgb{ .r = 25, .g = 25, .b = 25 },
        white.blend(black, 0.9),
    );
}
