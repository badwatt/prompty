//! How the adapters read a raw syscall's result.
//!
//! The decision lives here, as a pure function, for two reasons: it is the same
//! in every adapter that writes, and a branch that only a signal can reach would
//! otherwise be untestable — and therefore invisible to the coverage gate.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

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

/// Waits for `fd` to have something to read. False means nothing arrived in
/// time or the wait failed: either way there is nothing more to read.
///
/// A signal that interrupts the wait is not an answer. Treating it as one — a
/// window resize during `git status` — turned a whole render into "no status".
pub fn ready(fd: posix.fd_t, timeout_ms: i32) bool {
    var descriptors = [_]linux.pollfd{.{
        .fd = fd,
        .events = linux.POLL.IN,
        .revents = 0,
    }};
    var step: Result = .interrupted;
    while (step == .interrupted) {
        step = classify(linux.poll(&descriptors, descriptors.len, timeout_ms));
    }
    return step == .readable;
}

const Result = enum { readable, empty, interrupted };

fn classify(result: usize) Result {
    return switch (linux.errno(result)) {
        .SUCCESS => if (result > 0) .readable else .empty,
        .INTR => .interrupted,
        else => .empty,
    };
}

test "a poll result says whether to read, stop, or wait again" {
    try std.testing.expectEqual(Result.readable, classify(2));
    try std.testing.expectEqual(Result.empty, classify(0));
    const interrupted: usize = @bitCast(-@as(isize, @backingInt(linux.E.INTR)));
    try std.testing.expectEqual(Result.interrupted, classify(interrupted));
    const failed: usize = @bitCast(-@as(isize, @backingInt(linux.E.BADF)));
    try std.testing.expectEqual(Result.empty, classify(failed));
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
