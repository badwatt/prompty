//! Terminal adapter: asks the controlling terminal for its background colour
//! with an OSC 11 query.
//!
//! The query is only safe if the terminal is put in a quiet mode first. A tty
//! left in its default state *echoes* the answer onto the screen and holds it
//! in canonical buffering until a newline arrives — the reply then shows up as
//! garbage, and worse, stays in the input queue where the shell will read it as
//! if the user had typed it. So the adapter:
//!
//! 1. saves the terminal state and turns off echo and canonical input,
//! 2. writes the query,
//! 3. reads until the reply's terminator or a deadline, so nothing is left
//!    behind,
//! 4. restores the terminal state on every path out.
//!
//! It never runs on the prompt path: `prompty theme detect` calls it once and
//! the answer is cached.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const ports = @import("../../ports/host.zig");
const syscall = @import("syscall.zig");

pub const Tty = struct {
    /// The controlling terminal, opened only when detection is requested.
    device_path: []const u8 = "/dev/tty",

    /// A terminal that has not answered by now is not going to.
    pub const timeout_ms: i32 = 100;

    /// A reply that needs more reads than this is not a reply.
    const max_reads = 32;

    /// The reply is at most `ESC ] 11 ; rgb:ffff/ffff/ffff ESC \`.
    pub const reply_capacity = 128;

    pub const query = "\x1b]11;?\x1b\\";

    pub const instance: Tty = .{};

    const read_write = linux.O{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true };

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

        const device = posix.openat(linux.AT.FDCWD, self.device_path, read_write, 0) catch return null;
        defer _ = linux.close(device);

        const guard = SignalGuard.install();
        defer guard.release();

        const quiet = enterQuietMode(device) orelse return null;
        defer posix.tcsetattr(device, .NOW, quiet.saved) catch {};

        const written = linux.write(device, query.ptr, query.len);
        if (linux.errno(written) != .SUCCESS) return null;
        if (written != query.len) return null;

        return readReply(device, buffer);
    }

    /// The signals a user reaches for when a shell start seems stuck.
    const terminating_signals = [_]posix.SIG{ .INT, .QUIT, .TERM, .HUP };

    const SignalGuard = struct {
        saved: posix.sigset_t,

        fn install() SignalGuard {
            var blocked = posix.sigemptyset();
            for (terminating_signals) |signal| posix.sigaddset(&blocked, signal);
            var saved: posix.sigset_t = undefined;
            posix.sigprocmask(posix.SIG.BLOCK, &blocked, &saved);
            return .{ .saved = saved };
        }

        fn release(self: SignalGuard) void {
            posix.sigprocmask(posix.SIG.SETMASK, &self.saved, null);
        }
    };

    const Quiet = struct { saved: posix.termios };

    /// Echo off, canonical off: the reply must not be shown and must not wait
    /// for a newline that will never come.
    fn enterQuietMode(device: posix.fd_t) ?Quiet {
        const saved = posix.tcgetattr(device) catch return null;
        var quiet = saved;
        quiet.lflag.ECHO = false;
        quiet.lflag.ECHONL = false;
        quiet.lflag.ICANON = false;
        quiet.iflag.ICRNL = false;
        posix.tcsetattr(device, .NOW, quiet) catch return null;
        return .{ .saved = saved };
    }

    /// Reads until the reply is complete, so that no byte of it is left in the
    /// terminal's input queue for the shell to read as typed input. Anything
    /// that arrives after the terminator is swallowed for the same reason.
    fn readReply(device: posix.fd_t, buffer: []u8) ?[]const u8 {
        var filled: usize = 0;
        var complete = false;
        var reads: u8 = 0;
        while (reads < max_reads) : (reads += 1) {
            if (!syscall.ready(device, if (complete) 0 else timeout_ms)) break;

            if (complete) {
                var discard: [32]u8 = undefined;
                if ((posix.read(device, &discard) catch 0) == 0) break;
                continue;
            }

            const received = posix.read(device, buffer[filled..]) catch 0;
            if (received == 0) break;
            filled += received;
            if (replyEnd(buffer[0..filled])) |end| {
                filled = end;
                complete = true;
            }
        }
        if (!complete) return null;
        return buffer[0..filled];
    }

    /// Where the reply ends inside `reply`, if it has arrived at all: the
    /// terminator is BEL or ST (`ESC \\`). Searching for it rather than
    /// looking at the last byte keeps a terminal that appends to its answer
    /// from hiding the end of the reply.
    fn replyEnd(reply: []const u8) ?usize {
        for (reply, 0..) |byte, index| {
            if (byte == 0x07) return index + 1;
            if (byte == 0x1b and index + 1 < reply.len and reply[index + 1] == '\\') return index + 2;
        }
        return null;
    }
};

const TIOCSPTLCK = 0x40045431;
const TIOCGPTN = 0x80045430;

const Pty = struct {
    master: posix.fd_t,
    slave: posix.fd_t,
    number: u32,

    fn open() Pty {
        const master = posix.openat(linux.AT.FDCWD, "/dev/ptmx", Tty.read_write, 0) catch unreachable;

        var unlock: i32 = 0;
        std.debug.assert(linux.errno(linux.ioctl(master, TIOCSPTLCK, @intFromPtr(&unlock))) == .SUCCESS);
        var number: u32 = 0;
        std.debug.assert(linux.errno(linux.ioctl(master, TIOCGPTN, @intFromPtr(&number))) == .SUCCESS);

        var name: [32]u8 = undefined;
        const device_path = std.fmt.bufPrint(&name, "/dev/pts/{d}", .{number}) catch unreachable;
        const slave = posix.openat(linux.AT.FDCWD, device_path, Tty.read_write, 0) catch unreachable;
        return .{ .master = master, .slave = slave, .number = number };
    }

    /// The device path, formatted into the caller's buffer so that the caller
    /// controls the lifetime.
    fn path(self: Pty, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(buffer, "/dev/pts/{d}", .{self.number}) catch unreachable;
    }

    fn close(self: Pty) void {
        _ = linux.close(self.slave);
        _ = linux.close(self.master);
    }

    fn answer(self: Pty, reply: []const u8) void {
        std.debug.assert(linux.write(self.master, reply.ptr, reply.len) == reply.len);
    }
};

const reply_text = "\x1b]11;rgb:1e1e/1e1e/2e2e\x1b\\";

test "asks the terminal in a quiet mode and reads the whole reply" {
    const pty = Pty.open();
    defer pty.close();

    pty.answer(reply_text);

    var path_buffer: [32]u8 = undefined;
    const adapter = Tty{ .device_path = pty.path(&path_buffer) };
    var buffer: [Tty.reply_capacity]u8 = undefined;
    try std.testing.expectEqualStrings(reply_text, adapter.terminal().background(&buffer).?);
}

test "the terminal is left exactly as it was found" {
    const pty = Pty.open();
    defer pty.close();
    pty.answer(reply_text);

    const before = try posix.tcgetattr(pty.slave);
    var path_buffer: [32]u8 = undefined;
    const adapter = Tty{ .device_path = pty.path(&path_buffer) };
    var buffer: [Tty.reply_capacity]u8 = undefined;
    _ = adapter.terminal().background(&buffer);
    const after = try posix.tcgetattr(pty.slave);

    try std.testing.expectEqual(before.lflag.ECHO, after.lflag.ECHO);
    try std.testing.expectEqual(before.lflag.ICANON, after.lflag.ICANON);
    try std.testing.expectEqual(before.lflag.ISIG, after.lflag.ISIG);
    try std.testing.expect(after.lflag.ECHO);
}

test "nothing is left in the queue for the shell to read" {
    const pty = Pty.open();
    defer pty.close();
    pty.answer(reply_text);

    var path_buffer: [32]u8 = undefined;
    const adapter = Tty{ .device_path = pty.path(&path_buffer) };
    var buffer: [Tty.reply_capacity]u8 = undefined;
    _ = adapter.terminal().background(&buffer);

    var descriptors = [_]linux.pollfd{.{
        .fd = pty.slave,
        .events = linux.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), linux.poll(&descriptors, descriptors.len, 50));

    var reply: [64]u8 = undefined;
    const echoed = try posix.read(pty.master, &reply);
    try std.testing.expect(std.mem.indexOf(u8, reply[0..echoed], Tty.query) != null);
}

test "a terminal that never answers is not waited for" {
    const pty = Pty.open();
    defer pty.close();

    var path_buffer: [32]u8 = undefined;
    const adapter = Tty{ .device_path = pty.path(&path_buffer) };
    var buffer: [Tty.reply_capacity]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), adapter.terminal().background(&buffer));
}

test "without a controlling terminal nothing is written anywhere" {
    const adapter = Tty{ .device_path = "/nonexistent/tty" };
    var buffer: [Tty.reply_capacity]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), adapter.terminal().background(&buffer));
}

test "stragglers that arrive after the reply are drained" {
    const pty = Pty.open();
    defer pty.close();
    const quiet = Tty.enterQuietMode(pty.slave).?;
    defer posix.tcsetattr(pty.slave, .NOW, quiet.saved) catch {};
    pty.answer(reply_text ++ "straggler");

    var buffer: [reply_text.len]u8 = undefined;
    try std.testing.expectEqualStrings(reply_text, Tty.readReply(pty.slave, &buffer).?);

    var descriptors = [_]linux.pollfd{.{
        .fd = pty.slave,
        .events = linux.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), linux.poll(&descriptors, descriptors.len, 50));
}

test "bytes that arrive with the reply are not left for the shell" {
    const pty = Pty.open();
    defer pty.close();
    pty.answer(reply_text ++ "straggler");

    var path_buffer: [32]u8 = undefined;
    const adapter = Tty{ .device_path = pty.path(&path_buffer) };
    var buffer: [Tty.reply_capacity]u8 = undefined;
    try std.testing.expectEqualStrings(reply_text, adapter.terminal().background(&buffer).?);

    var descriptors = [_]linux.pollfd{.{
        .fd = pty.slave,
        .events = linux.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), linux.poll(&descriptors, descriptors.len, 50));
}

test "a descriptor that is not a terminal is refused" {
    var pipe: [2]posix.fd_t = undefined;
    std.debug.assert(linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) == .SUCCESS);
    defer _ = linux.close(pipe[0]);
    defer _ = linux.close(pipe[1]);

    var buffer: [Tty.reply_capacity]u8 = undefined;
    try std.testing.expect(Tty.enterQuietMode(pipe[0]) == null);
    try std.testing.expectEqual(@as(?[]const u8, null), Tty.readReply(pipe[0], &buffer));
}

test "terminating signals are held only while the terminal is changed" {
    const guard = Tty.SignalGuard.install();
    var current: posix.sigset_t = undefined;
    posix.sigprocmask(posix.SIG.BLOCK, null, &current);
    for (Tty.terminating_signals) |signal| {
        try std.testing.expect(posix.sigismember(&current, signal));
    }
    try std.testing.expect(!posix.sigismember(&current, .USR1));

    guard.release();
    posix.sigprocmask(posix.SIG.BLOCK, null, &current);
    for (Tty.terminating_signals) |signal| {
        try std.testing.expect(!posix.sigismember(&current, signal));
    }
}

test "the terminator is found wherever it lands" {
    try std.testing.expectEqual(@as(?usize, null), Tty.replyEnd(""));
    try std.testing.expectEqual(@as(?usize, null), Tty.replyEnd("\x1b]11;rgb:1e1e"));
    try std.testing.expectEqual(@as(?usize, null), Tty.replyEnd("\x1b"));
    try std.testing.expectEqual(@as(?usize, reply_text.len), Tty.replyEnd(reply_text));
    try std.testing.expectEqual(@as(?usize, reply_text.len), Tty.replyEnd(reply_text ++ "straggler"));
    try std.testing.expectEqual(@as(?usize, 1), Tty.replyEnd("\x07"));
}
