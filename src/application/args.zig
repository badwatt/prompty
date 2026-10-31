//! Command line collection. The fixed buffer is the point: a prompt never
//! allocates, so arguments are counted, not owned.

const std = @import("std");

pub const max_arguments = 16;

pub fn collect(args: std.process.Args, buffer: [][]const u8) []const []const u8 {
    var iterator = std.process.Args.Iterator.init(args);
    var count: usize = 0;
    while (count < buffer.len) {
        buffer[count] = iterator.next() orelse break;
        count += 1;
    }
    return buffer[0..count];
}

test "collects every argument in order" {
    const argv = [_][*:0]const u8{ "prompty", "render", "--shell=zsh" };
    var buffer: [max_arguments][]const u8 = undefined;
    const collected = collect(.{ .vector = &argv }, &buffer);

    try std.testing.expectEqual(@as(usize, 3), collected.len);
    try std.testing.expectEqualStrings("prompty", collected[0]);
    try std.testing.expectEqualStrings("render", collected[1]);
    try std.testing.expectEqualStrings("--shell=zsh", collected[2]);
}

test "stops at the end of the argument list" {
    const argv = [_][*:0]const u8{"prompty"};
    var buffer: [max_arguments][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), collect(.{ .vector = &argv }, &buffer).len);
}

test "never overflows the caller's buffer" {
    const argv = [_][*:0]const u8{ "a", "b", "c", "d" };
    var buffer: [2][]const u8 = undefined;
    const collected = collect(.{ .vector = &argv }, &buffer);
    try std.testing.expectEqual(@as(usize, 2), collected.len);
    try std.testing.expectEqualStrings("b", collected[1]);
}
