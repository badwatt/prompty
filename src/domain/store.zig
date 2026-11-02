//! Bounded, allocation-free storage for everything the prompt borrows.
//!
//! Slices handed out by `Store` stay valid for the lifetime of the `Store`
//! itself, which is why the store must live on the caller's stack for the
//! whole render and must never be moved after the first `dupe`.

const std = @import("std");

pub const Store = struct {
    /// Everything the prompt borrows, at the largest size the rest of the
    /// program can hand over: a user name (64), a path label (512), the branch
    /// from the porcelain (128) or from HEAD (128). The test below recomputes
    /// this sum from those constants, so growing a field fails here rather than
    /// silently clipping a name.
    pub const capacity = 1024;

    bytes: [capacity]u8 = undefined,
    used: usize = 0,

    pub fn reset(self: *Store) void {
        self.used = 0;
    }

    /// Copies text that is going to be displayed, replacing control bytes: a
    /// newline in a directory name or a branch must not be able to start what
    /// looks like a new prompt line.
    pub fn dupePrintable(self: *Store, text: []const u8) []const u8 {
        return self.dupeDisplay(text, text.len);
    }

    /// `dupePrintable`, but at most `max_bytes` of it, cut on a character
    /// boundary. A name from the environment has no length limit, and one long
    /// enough would otherwise take the whole prompt line for itself.
    pub fn dupeDisplay(self: *Store, text: []const u8, max_bytes: usize) []const u8 {
        var length = @min(text.len, max_bytes);
        while (length > 0 and length < text.len and (text[length] & 0xc0) == 0x80) {
            length -= 1;
        }
        const slice = self.claim(length);
        for (text[0..slice.len], 0..) |byte, index| {
            slice[index] = if (byte < 0x20 or byte == 0x7f) '?' else byte;
        }
        return slice;
    }

    pub fn dupe(self: *Store, text: []const u8) []const u8 {
        const slice = self.claim(text.len);
        @memcpy(slice, text[0..slice.len]);
        return slice;
    }

    /// Hands out as much of the remaining space as `length` asks for, and less
    /// when the store is full. Overflow used to be an assertion, and the release
    /// build compiles assertions away: an over-long environment variable then
    /// wrote past the end of the store. Clamping keeps the prompt whole, and
    /// every caller renders whatever slice it is given.
    pub fn claim(self: *Store, length: usize) []u8 {
        const granted = @min(length, capacity - self.used);
        const slice = self.bytes[self.used..][0..granted];
        self.used += granted;
        return slice;
    }
};

test "dupe copies by value" {
    var store: Store = undefined;
    store.reset();

    var original = [_]u8{ 'h', 'i' };
    const copy = store.dupe(&original);
    original[0] = 'X';

    try std.testing.expectEqualStrings("hi", copy);
    try std.testing.expect(copy.ptr != &original);
}

test "control bytes become visible question marks" {
    var store: Store = undefined;
    store.reset();
    const printable = store.dupePrintable("a\nb\tc\x7f");
    try std.testing.expectEqualStrings("a?b?c?", printable);
    try std.testing.expectEqualStrings("ñandú/日本語", store.dupePrintable("ñandú/日本語"));
}

test "claim hands out distinct, adjacent slices" {
    var store: Store = undefined;
    store.reset();

    const first = store.claim(3);
    const second = store.claim(2);
    first[0] = 'a';
    second[0] = 'b';

    try std.testing.expect(first.ptr != second.ptr);
    try std.testing.expectEqual(@as(usize, 5), store.used);
}

test "reset recycles the whole buffer" {
    var store: Store = undefined;
    store.reset();
    _ = store.dupe("one");
    _ = store.dupe("two");
    store.reset();
    try std.testing.expectEqual(@as(usize, 0), store.used);
    try std.testing.expectEqualStrings("three", store.dupe("three"));
}

test "a maximal prompt really fits, with room to spare" {
    const prompt = @import("prompt.zig");
    const path = @import("path.zig");
    const git = @import("git.zig");

    var store: Store = undefined;
    store.reset();
    const user: [prompt.max_user_bytes]u8 = @splat('u');
    const label: [path.max_display_bytes]u8 = @splat('x');
    const branch: [git.max_head_bytes]u8 = @splat('y');

    try std.testing.expectEqual(@as(usize, prompt.max_user_bytes), store.dupeDisplay(&user, prompt.max_user_bytes).len);
    try std.testing.expectEqual(@as(usize, path.max_display_bytes), store.dupePrintable(&label).len);
    try std.testing.expectEqual(@as(usize, git.max_head_bytes), store.dupePrintable(&branch).len);
    try std.testing.expectEqual(@as(usize, git.max_head_bytes), store.dupePrintable(&branch).len);
}

test "a claim larger than the store is clipped, not written past it" {
    var store: Store = undefined;
    store.reset();
    const granted = store.claim(Store.capacity + 100);
    try std.testing.expectEqual(@as(usize, Store.capacity), granted.len);
    try std.testing.expectEqual(@as(usize, Store.capacity), store.used);
    try std.testing.expectEqual(@as(usize, 0), store.claim(1).len);
    try std.testing.expectEqual(@as(usize, 0), store.dupe("x").len);
}

test "a display name is cut short on a character boundary" {
    var store: Store = undefined;
    store.reset();
    try std.testing.expectEqualStrings("", store.dupeDisplay("ñandú", 1));
    try std.testing.expectEqualStrings("ñ", store.dupeDisplay("ñandú", 2));
    try std.testing.expectEqualStrings("ña", store.dupeDisplay("ñandú", 3));
    try std.testing.expectEqualStrings("ñandú", store.dupeDisplay("ñandú", 64));
    try std.testing.expectEqualStrings("a?b", store.dupeDisplay("a\nb", 64));
}

test "property: a display name is always bounded and stays valid" {
    var prng = std.Random.DefaultPrng.init(0x5702e);
    const random = prng.random();
    var store: Store = undefined;
    var buffer: [256]u8 = undefined;
    const pieces = [_][]const u8{ "a", "ñ", "日", "\n", "\x7f", "Z" };

    for (0..2000) |_| {
        store.reset();
        var length: usize = 0;
        const count = random.intRangeAtMost(usize, 0, 30);
        for (0..count) |_| {
            const piece = pieces[random.uintLessThan(usize, pieces.len)];
            if (length + piece.len > buffer.len) break;
            @memcpy(buffer[length..][0..piece.len], piece);
            length += piece.len;
        }
        const limit = random.intRangeAtMost(usize, 0, buffer.len);
        const shown = store.dupeDisplay(buffer[0..length], limit);
        try std.testing.expect(shown.len <= limit);
        for (shown) |byte| try std.testing.expect(byte >= 0x20 and byte != 0x7f);
        if (std.unicode.utf8ValidateSlice(buffer[0..length])) {
            try std.testing.expect(std.unicode.utf8ValidateSlice(shown));
        }
    }
}

test "the store is at least as large as the largest prompt it can be handed" {
    const prompt = @import("prompt.zig");
    const path = @import("path.zig");
    const git = @import("git.zig");

    const worst_case = prompt.max_user_bytes + path.max_display_bytes + 2 * git.max_head_bytes;
    try std.testing.expect(worst_case <= Store.capacity);
}
