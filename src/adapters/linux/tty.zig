//! Terminal adapter: asks the controlling terminal for its background colour
//! with an OSC 11 query, with a hard timeout so a terminal that does not answer
//! can never hang a shell.
//!
//! Tests inject an already-open file descriptor (a pipe end), which exercises
//! every line of the request/reply path without needing a pseudo-terminal.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const ports = @import("../../ports/host.zig");

pub const Tty = struct {
    /// The controlling terminal, opened lazily so that `--help` never touches
    /// the tty.
    device_path: []const u8 = "/dev/tty",

    /// Set by tests: the descriptor to use instead of opening the device.
    preset_fd: ?posix.fd_t = null,

    /// A terminal that has not answered in this long is not going to.
    pub const timeout_ms: i32 = 100;

    /// The reply is at most `ESC ] 11 ; rgb:ffff/ffff/ffff ESC \`.
    pub const reply_capacity = 128;

    pub const query = "\x1b]11;?\x1b\\";

    pub const instance: Tty = .{};

    pub fn terminal(self: *const Tty) ports.Terminal {
        return .{
            .ptr = @ptrCast(@constCast(self)),
            .vtable = &vtable,
        };
    }

    const vtable = ports.Terminal.VTable{ .background = background };

    fn background(ptr: *anyopaque, buffer: []u8) ?[]const u8 {
        const self: *const Tty = @ptrCast(@alignCast(ptr));
        std.debug.assert(buffer.len >= reply_capacity);

        const fd = self.preset_fd orelse
            (posix.openat(linux.AT.FDCWD, self.device_path, .{
                .ACCMODE = .RDWR,
                .CLOEXEC = true,
            }, 0) catch return null);
        const owned = self.preset_fd == null;
        defer if (owned) {
            _ = linux.close(fd);
        };

        const written = linux.write(fd, query.ptr, query.len);
        if (linux.errno(written) != .SUCCESS) return null;
        if (written != query.len) return null;

        var descriptors = [_]linux.pollfd{.{
            .fd = fd,
            .events = linux.POLL.IN,
            .revents = 0,
        }};
        const ready = linux.poll(&descriptors, descriptors.len, timeout_ms);
        if (linux.errno(ready) != .SUCCESS) return null;
        if (ready == 0) return null;

        const received = posix.read(fd, buffer) catch return null;
        if (received == 0) return null;
        return buffer[0..received];
    }
};

/// A socket pair behaves like a terminal: bidirectional, so the adapter can
/// both ask its question and read the answer on the same descriptor.
fn socketPair() ![2]posix.fd_t {
    var sockets: [2]posix.fd_t = undefined;
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &sockets);
    if (linux.errno(rc) != .SUCCESS) return error.SkipZigTest;
    return sockets;
}

test "reads the reply from the terminal" {
    const sockets = try socketPair();
    defer _ = linux.close(sockets[0]);
    defer _ = linux.close(sockets[1]);

    // Stand-in for the terminal: the answer is already buffered when the
    // adapter asks, exactly like a fast terminal replying mid-write.
    const reply = "\x1b]11;rgb:1e1e/1e1e/2e2e\x1b\\";
    try std.testing.expectEqual(reply.len, linux.write(sockets[1], reply.ptr, reply.len));

    const adapter = Tty{ .preset_fd = sockets[0] };
    var buffer: [Tty.reply_capacity]u8 = undefined;
    const answer = adapter.terminal().background(&buffer).?;
    try std.testing.expectEqualStrings(reply, answer);

    // And the adapter really did ask the question first.
    var question: [Tty.query.len]u8 = undefined;
    try std.testing.expectEqual(Tty.query.len, linux.read(sockets[1], &question, question.len));
    try std.testing.expectEqualStrings(Tty.query, &question);
}

test "a terminal that never answers is not waited for" {
    const sockets = try socketPair();
    defer _ = linux.close(sockets[0]);
    defer _ = linux.close(sockets[1]);

    // Nothing is ever written back, so the poll must time out.
    const adapter = Tty{ .preset_fd = sockets[0] };
    var buffer: [Tty.reply_capacity]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), adapter.terminal().background(&buffer));
}

test "an unusable descriptor yields nothing instead of crashing" {
    var pipe: [2]posix.fd_t = undefined;
    if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.SkipZigTest;
    _ = linux.close(pipe[0]);
    defer _ = linux.close(pipe[1]);

    const adapter = Tty{ .preset_fd = pipe[0] };
    var buffer: [Tty.reply_capacity]u8 = undefined;
    // The write fails immediately, so the adapter reports failure rather than
    // polling a descriptor that no longer exists.
    try std.testing.expectEqual(@as(?[]const u8, null), adapter.terminal().background(&buffer));
}

test "without a terminal the adapter reports failure" {
    const adapter = Tty{ .device_path = "/nonexistent/tty" };
    var buffer: [Tty.reply_capacity]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), adapter.terminal().background(&buffer));
}
