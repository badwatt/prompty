//! Parses the terminal's answer to the OSC 11 question ("what is your
//! background colour?").
//!
//! Terminals reply in one of two dialects, both handled here:
//!
//!     ESC ] 11 ; rgb:1e1e/1e1e/2e2e ST   (xterm, kitty, ghostty, ...)
//!     ESC ] 11 ; #1e1e2e BEL             (a few others)
//!
//! Parsing is pure so that the tty adapter stays a thin, boring pipe.

const std = @import("std");

const rgb = @import("rgb.zig");

pub const Rgb = rgb.Rgb;

pub const prefix = "\x1b]11;";

pub fn parseBackground(response: []const u8) ?Rgb {
    if (response.len == 0) return null;
    const payload = stripTerminator(response);
    if (payload.len == 0) return null;

    const colors = if (std.mem.startsWith(u8, payload, "rgb:"))
        payload["rgb:".len..]
    else
        payload;

    if (colors.len > 0 and colors[0] == '#') return Rgb.parse(colors);

    var parts = std.mem.splitScalar(u8, colors, '/');
    const red = scaleComponent(parts.next() orelse return null) orelse return null;
    const green = scaleComponent(parts.next() orelse return null) orelse return null;
    const blue = scaleComponent(parts.next() orelse return null) orelse return null;
    if (parts.next() != null) return null;

    return .{ .r = red, .g = green, .b = blue };
}

/// Strips the OSC introducer (when present) and any trailing BEL or ST.
fn stripTerminator(response: []const u8) []const u8 {
    var content = response;
    if (std.mem.startsWith(u8, content, prefix)) {
        content = content[prefix.len..];
    } else if (std.mem.indexOf(u8, content, ";")) |semicolon| {
        content = content[semicolon + 1 ..];
    }
    while (content.len > 0) {
        const last = content[content.len - 1];
        if (last == 0x07 or last == 0x1b or last == '\\' or last == '\r' or last == '\n') {
            content = content[0 .. content.len - 1];
            continue;
        }
        break;
    }
    return content;
}

/// A component is one to four hex digits; the value is scaled to eight bits.
fn scaleComponent(text: []const u8) ?u8 {
    if (text.len == 0 or text.len > 4) return null;
    var value: u32 = 0;
    for (text) |byte| {
        const digit = std.fmt.charToDigit(byte, 16) catch return null;
        value = value * 16 + digit;
    }
    const maximum: u32 = (@as(u32, 1) << @intCast(text.len * 4)) - 1;
    return @intCast(value * 255 / maximum);
}

test "parses the xterm rgb dialect" {
    try std.testing.expectEqual(
        Rgb{ .r = 0x1e, .g = 0x1e, .b = 0x2e },
        parseBackground("\x1b]11;rgb:1e1e/1e1e/2e2e\x1b\\").?,
    );
    try std.testing.expectEqual(
        Rgb{ .r = 0x1e, .g = 0x1e, .b = 0x2e },
        parseBackground("\x1b]11;rgb:1e1e/1e1e/2e2e\x07").?,
    );
    try std.testing.expectEqual(
        Rgb{ .r = 0xab, .g = 0xcd, .b = 0xef },
        parseBackground("rgb:ab/cd/ef").?,
    );
    try std.testing.expectEqual(
        Rgb{ .r = 0xff, .g = 0x00, .b = 0x88 },
        parseBackground("rgb:f/0/8").?,
    );
}

test "parses the hash dialect" {
    try std.testing.expectEqual(
        Rgb{ .r = 0xf5, .g = 0xf5, .b = 0xf5 },
        parseBackground("\x1b]11;#f5f5f5\x07").?,
    );
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, parseBackground("#000000").?);
}

test "rejects anything that is not a colour" {
    try std.testing.expectEqual(@as(?Rgb, null), parseBackground(""));
    try std.testing.expectEqual(@as(?Rgb, null), parseBackground("\x1b]11;"));
    try std.testing.expectEqual(@as(?Rgb, null), parseBackground("rgb:"));
    try std.testing.expectEqual(@as(?Rgb, null), parseBackground("rgb:1e1e/1e1e"));
    try std.testing.expectEqual(@as(?Rgb, null), parseBackground("rgb:1e1e/1e1e/2e2e/00"));
    try std.testing.expectEqual(@as(?Rgb, null), parseBackground("rgb:zz/1e1e/2e2e"));
    try std.testing.expectEqual(@as(?Rgb, null), parseBackground("rgb:12345/0/0"));
    try std.testing.expectEqual(@as(?Rgb, null), parseBackground("#12345"));
}

test "a bare value with a semicolon keeps only what follows it" {
    try std.testing.expectEqual(
        Rgb{ .r = 0x10, .g = 0x20, .b = 0x30 },
        parseBackground("11;rgb:1010/2020/3030").?,
    );
}

test "property: any reply is a colour or nothing" {
    var prng = std.Random.DefaultPrng.init(0x05c);
    const random = prng.random();
    var buffer: [64]u8 = undefined;
    const pieces = [_][]const u8{ "\x1b]11;", "rgb:", "#", "1e", "ff", "/", "\x07", "\x1b\\", "zz", "00" };

    for (0..3000) |_| {
        var length: usize = 0;
        const count = random.intRangeAtMost(usize, 0, 8);
        for (0..count) |_| {
            const piece = pieces[random.uintLessThan(usize, pieces.len)];
            if (length + piece.len > buffer.len) break;
            @memcpy(buffer[length..][0..piece.len], piece);
            length += piece.len;
        }
        if (parseBackground(buffer[0..length])) |color| {
            try std.testing.expect(color.r <= 0xff);
            try std.testing.expect(color.g <= 0xff);
            try std.testing.expect(color.b <= 0xff);
        }
    }
}
