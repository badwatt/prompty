//! How the adapters read a raw syscall's result.
//!
//! The decision lives here, as a pure function, for two reasons: it is the same
//! in every adapter that writes, and a branch that only a signal can reach would
//! otherwise be untestable — and therefore invisible to the coverage gate.

const std = @import("std");
const linux = std.os.linux;

/// How far a write got. Zero means a signal interrupted it before it wrote
/// anything and it has to be tried again; null means it failed, and a prompt has
/// nobody left to complain to.
pub fn progress(result: usize) ?usize {
    switch (linux.errno(result)) {
        .SUCCESS => return if (result == 0) null else result,
        // A window resize can arrive in the middle of the prompt. Retrying is
        // what keeps the line whole instead of printing half of it.
        .INTR => return 0,
        else => return null,
    }
}

test "a complete write is progress" {
    try std.testing.expectEqual(@as(?usize, 5), progress(5));
    try std.testing.expectEqual(@as(?usize, 1), progress(1));
}

test "an interrupted write is retried, not counted" {
    const interrupted: usize = @bitCast(-@as(isize, @backingInt(linux.E.INTR)));
    try std.testing.expectEqual(@as(?usize, 0), progress(interrupted));
}

test "a failed write stops, and so does a zero-length one" {
    const broken_pipe: usize = @bitCast(-@as(isize, @backingInt(linux.E.PIPE)));
    try std.testing.expectEqual(@as(?usize, null), progress(broken_pipe));
    const bad_descriptor: usize = @bitCast(-@as(isize, @backingInt(linux.E.BADF)));
    try std.testing.expectEqual(@as(?usize, null), progress(bad_descriptor));
    try std.testing.expectEqual(@as(?usize, null), progress(0));
}
