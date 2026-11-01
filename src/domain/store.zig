//! Bounded, allocation-free storage for everything the prompt borrows.
//!
//! Slices handed out by `Store` stay valid for the lifetime of the `Store`
//! itself, which is why the store must live on the caller's stack for the
//! whole render and must never be moved after the first `dupe`.

const std = @import("std");

pub const Store = struct {
    /// Eight kibibytes is far more than a prompt can ever need: a path is
    /// bounded by `max_path_bytes`, a branch name by 256 bytes and the language
    /// versions by 32 bytes each.
    pub const capacity = 8192;

    bytes: [capacity]u8 = undefined,
    used: usize = 0,

    pub fn reset(self: *Store) void {
        self.used = 0;
    }

    /// Copies text that is going to be displayed, replacing control bytes: a
    /// newline in a directory name or a branch must not be able to start what
    /// looks like a new prompt line.
    pub fn dupePrintable(self: *Store, text: []const u8) []const u8 {
        const slice = self.claim(text.len);
        for (text, 0..) |byte, index| {
            slice[index] = if (byte < 0x20 or byte == 0x7f) '?' else byte;
        }
        return slice;
    }

    pub fn dupe(self: *Store, text: []const u8) []const u8 {
        const slice = self.claim(text.len);
        @memcpy(slice, text);
        return slice;
    }

    pub fn claim(self: *Store, length: usize) []u8 {
        // Overflow is a programming error: the caller must bound its input.
        std.debug.assert(self.used + length <= capacity);
        const slice = self.bytes[self.used..][0..length];
        self.used += length;
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
    // Ordinary text is untouched, including multi-byte characters.
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

test "capacity is enough for a maximal prompt" {
    var store: Store = undefined;
    store.reset();
    // A full-size path plus every other slice a render needs, with room left.
    const long_path: [4096]u8 = @splat('x');
    const long_branch: [256]u8 = @splat('y');
    const versions: [5 * 32]u8 = @splat('z');
    _ = store.dupe(&long_path);
    _ = store.dupe(&long_branch);
    _ = store.dupe(&versions);
    try std.testing.expect(store.used < Store.capacity);
}
