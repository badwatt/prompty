//! How many terminal columns a string occupies.
//!
//! A right-aligned segment has to know the width of everything before it, and
//! "number of bytes" is not that number: a Nerd Font glyph is one column but
//! four bytes, and a directory called `日本語` is two columns per character.
//! This is the small part of `wcwidth` a prompt needs, with no allocation and
//! no dependency.

const std = @import("std");

/// Columns taken by `text`. Invalid UTF-8 counts one column per byte: the
/// prompt already replaces control bytes, and a broken name must still be
/// measured rather than ignored.
pub fn utf8(text: []const u8) usize {
    var total: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch {
            total += 1;
            index += 1;
            continue;
        };
        if (index + length > text.len) {
            total += 1;
            index += 1;
            continue;
        }
        const value = std.unicode.utf8Decode(text[index..][0..length]) catch {
            total += 1;
            index += 1;
            continue;
        };
        total += codepoint(value);
        index += length;
    }
    return total;
}

/// Columns taken by one code point.
pub fn codepoint(value: u21) usize {
    // Control characters move the cursor or do nothing: the newline that starts
    // every prompt is the one that matters here, and it takes no column of the
    // line that follows it.
    if (value < 0x20 or (value >= 0x7f and value <= 0x9f)) return 0;
    if (inRanges(&zero_width, value)) return 0;
    if (inRanges(&wide, value)) return 2;
    return 1;
}

fn inRanges(ranges: []const [2]u21, value: u21) bool {
    for (ranges) |range| {
        if (value >= range[0] and value <= range[1]) return true;
    }
    return false;
}

/// Combining marks, variation selectors and joiners: they decorate the
/// character before them and take no column of their own.
const zero_width = [_][2]u21{
    .{ 0x0300, 0x036f },   .{ 0x0483, 0x0489 }, .{ 0x0591, 0x05bd },
    .{ 0x0610, 0x061a },   .{ 0x064b, 0x065f }, .{ 0x0e31, 0x0e31 },
    .{ 0x0e34, 0x0e3a },   .{ 0x0e47, 0x0e4e }, .{ 0x1ab0, 0x1aff },
    .{ 0x1dc0, 0x1dff },   .{ 0x200b, 0x200f }, .{ 0x20d0, 0x20f0 },
    .{ 0xfe00, 0xfe0f },   .{ 0xfe20, 0xfe2f }, .{ 0xfeff, 0xfeff },
    .{ 0xe0100, 0xe01ef },
};

/// East Asian wide and fullwidth, plus the emoji blocks. A prompt shows names
/// and not prose, so this is the whole of what it needs to get right.
const wide = [_][2]u21{
    .{ 0x1100, 0x115f },   .{ 0x2e80, 0x303e },   .{ 0x3041, 0x33ff },
    .{ 0x3400, 0x4dbf },   .{ 0x4e00, 0x9fff },   .{ 0xa000, 0xa4cf },
    .{ 0xa960, 0xa97f },   .{ 0xac00, 0xd7a3 },   .{ 0xf900, 0xfaff },
    .{ 0xfe10, 0xfe19 },   .{ 0xfe30, 0xfe6f },   .{ 0xff00, 0xff60 },
    .{ 0xffe0, 0xffe6 },   .{ 0x16fe0, 0x16fe4 }, .{ 0x17000, 0x187f7 },
    .{ 0x18800, 0x18cd5 }, .{ 0x1b000, 0x1b2fb }, .{ 0x1f004, 0x1f004 },
    .{ 0x1f0cf, 0x1f0cf }, .{ 0x1f18e, 0x1f18e }, .{ 0x1f191, 0x1f19a },
    .{ 0x1f200, 0x1f320 }, .{ 0x1f32d, 0x1f335 }, .{ 0x1f337, 0x1f37c },
    .{ 0x1f37e, 0x1f393 }, .{ 0x1f3a0, 0x1f3ca }, .{ 0x1f3cf, 0x1f3d3 },
    .{ 0x1f3e0, 0x1f3f0 }, .{ 0x1f3f4, 0x1f3f4 }, .{ 0x1f3f8, 0x1f43e },
    .{ 0x1f440, 0x1f440 }, .{ 0x1f442, 0x1f4fc }, .{ 0x1f4ff, 0x1f53d },
    .{ 0x1f54b, 0x1f54e }, .{ 0x1f550, 0x1f567 }, .{ 0x1f57a, 0x1f57a },
    .{ 0x1f595, 0x1f596 }, .{ 0x1f5a4, 0x1f5a4 }, .{ 0x1f5fb, 0x1f64f },
    .{ 0x1f680, 0x1f6c5 }, .{ 0x1f6cc, 0x1f6cc }, .{ 0x1f6d0, 0x1f6d2 },
    .{ 0x1f6eb, 0x1f6ec }, .{ 0x1f6f4, 0x1f6fa }, .{ 0x1f7e0, 0x1f7eb },
    .{ 0x1f90d, 0x1f9ff }, .{ 0x1fa70, 0x1fa7a }, .{ 0x20000, 0x3fffd },
};

test "ascii is one column per byte" {
    try std.testing.expectEqual(@as(usize, 0), utf8(""));
    try std.testing.expectEqual(@as(usize, 11), utf8("hello world"));
    try std.testing.expectEqual(@as(usize, 1), utf8("%"));
    try std.testing.expectEqual(@as(usize, 1), utf8("ñ")); // two bytes, one column
}

test "wide characters take two columns" {
    try std.testing.expectEqual(@as(usize, 6), utf8("日本語"));
    try std.testing.expectEqual(@as(usize, 2), utf8("🚀"));
    try std.testing.expectEqual(@as(usize, 4), utf8("한글"));
    try std.testing.expectEqual(@as(usize, 2), utf8("Ａ")); // fullwidth latin
}

test "combining marks take none" {
    // e + combining acute: one column, not two.
    try std.testing.expectEqual(@as(usize, 1), utf8("e\u{0301}"));
    // A variation selector after a narrow glyph changes nothing.
    try std.testing.expectEqual(@as(usize, 1), utf8("\u{2764}\u{fe0f}"));
}

test "the prompt's own glyphs are one column each" {
    // Powerline separators, the chevron and the Nerd Font icons are all in the
    // private use area, which is one column wide.
    try std.testing.expectEqual(@as(usize, 1), utf8("\u{e0b6}"));
    try std.testing.expectEqual(@as(usize, 1), utf8("\u{e0b0}"));
    try std.testing.expectEqual(@as(usize, 1), utf8("\u{276f}"));
    try std.testing.expectEqual(@as(usize, 1), utf8("\u{f113}"));
    try std.testing.expectEqual(@as(usize, 1), utf8("\u{f051a}"));
    try std.testing.expectEqual(@as(usize, 1), utf8("\u{2026}"));
    try std.testing.expectEqual(@as(usize, 1), utf8("\u{00d7}"));
}

test "broken bytes are measured, not dropped" {
    try std.testing.expectEqual(@as(usize, 1), utf8("\xff"));
    try std.testing.expectEqual(@as(usize, 2), utf8("\xff\xfe"));
    // A truncated sequence still counts once.
    try std.testing.expectEqual(@as(usize, 1), utf8("\xc3"));
    try std.testing.expectEqual(@as(usize, 3), utf8("a\xc3b"));
}

test "control characters take no column" {
    try std.testing.expectEqual(@as(usize, 0), utf8("\n"));
    try std.testing.expectEqual(@as(usize, 2), utf8("a\tb"));
    try std.testing.expectEqual(@as(usize, 1), utf8("ab\n") - 1);
}
