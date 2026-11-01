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

    pub fn terminal(self: *const Tty) ports.Terminal {
        return .{
            .ptr = @ptrCast(@constCast(self)),
            .vtable = &vtable,
        };
    }

    const vtable = ports.Terminal.VTable{ .background = background, .columns = columns };

    /// `struct winsize`, which ioctl TIOCGWINSZ fills in.
    const Winsize = extern struct {
        rows: u16,
        cols: u16,
        x_pixels: u16,
        y_pixels: u16,
    };

    fn columns(ptr: *anyopaque) ?u16 {
        const self: *const Tty = @ptrCast(@alignCast(ptr));
        const device = posix.openat(linux.AT.FDCWD, self.device_path, .{
            .ACCMODE = .RDONLY,
            .NOCTTY = true,
            .CLOEXEC = true,
        }, 0) catch return null;
        defer _ = linux.close(device);

        var size: Winsize = std.mem.zeroes(Winsize);
        const result = linux.ioctl(device, TIOCGWINSZ, @intFromPtr(&size));
        if (linux.errno(result) != .SUCCESS) return null;
        if (size.cols == 0) return null;
        return size.cols;
    }

    fn background(ptr: *anyopaque, buffer: []u8) ?[]const u8 {
        const self: *const Tty = @ptrCast(@alignCast(ptr));
        std.debug.assert(buffer.len >= reply_capacity);

        const device = posix.openat(linux.AT.FDCWD, self.device_path, .{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
            .CLOEXEC = true,
        }, 0) catch return null;
        defer _ = linux.close(device);

        // A signal that arrives between changing the terminal state and
        // restoring it would leave the terminal damaged: echo and canonical
        // input off, carriage returns no longer translated. Block the signals
        // that would kill the process for the length of the query, and let any
        // pending one be delivered once the terminal is whole again.
        const guard = SignalGuard.install();
        defer guard.release();

        // Without a terminal there is nothing to ask, and pretending otherwise
        // would write a query into whatever the descriptor happens to be.
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
        // A reply arrives in one piece in practice; the bound exists so that a
        // talkative terminal cannot spin here.
        while (reads < max_reads) : (reads += 1) {
            // Once the reply is whole there is nothing left to wait for: look
            // for stragglers and leave immediately if there are none.
            if (!syscall.ready(device, if (complete) 0 else timeout_ms)) break;

            if (complete) {
                // Stragglers: read them and throw them away, or the shell will.
                var discard: [32]u8 = undefined;
                if ((posix.read(device, &discard) catch 0) == 0) break;
                continue;
            }

            const received = posix.read(device, buffer[filled..]) catch 0;
            if (received == 0) break;
            filled += received;
            if (replyEnd(buffer[0..filled])) |end| {
                // Whatever the terminal appended arrived in the same read, so it
                // is already consumed: the answer ends at the terminator.
                filled = end;
                complete = true;
            }
        }
        // A partial reply cannot be trusted, and leaving it in the queue is
        // exactly the failure this function exists to avoid.
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

// ---------------------------------------------------------------------------
// Tests. A real pseudo-terminal is used rather than a pipe: the whole point of
// this adapter is how it drives the terminal, and a pipe has no terminal state
// to get wrong.
// ---------------------------------------------------------------------------

const TIOCGWINSZ = 0x5413;
const TIOCSWINSZ = 0x5414;
const TIOCSPTLCK = 0x40045431;
const TIOCGPTN = 0x80045430;

const Pty = struct {
    master: posix.fd_t,
    slave: posix.fd_t,
    number: u32,

    fn open() Pty {
        // A pseudo-terminal is a hard requirement of these tests: skipping
        // instead would silently drop the coverage of the quiet-mode code,
        // which is the part that must not break.
        const master = posix.openat(linux.AT.FDCWD, "/dev/ptmx", .{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
            .CLOEXEC = true,
        }, 0) catch unreachable;

        var unlock: i32 = 0;
        std.debug.assert(linux.errno(linux.ioctl(master, TIOCSPTLCK, @intFromPtr(&unlock))) == .SUCCESS);
        var number: u32 = 0;
        std.debug.assert(linux.errno(linux.ioctl(master, TIOCGPTN, @intFromPtr(&number))) == .SUCCESS);

        var name: [32]u8 = undefined;
        const device_path = std.fmt.bufPrint(&name, "/dev/pts/{d}", .{number}) catch unreachable;
        const slave = posix.openat(linux.AT.FDCWD, device_path, .{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
            .CLOEXEC = true,
        }, 0) catch unreachable;
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

    fn resize(self: Pty, cols: u16, rows: u16) void {
        var size: Tty.Winsize = .{ .rows = rows, .cols = cols, .x_pixels = 0, .y_pixels = 0 };
        std.debug.assert(linux.errno(linux.ioctl(self.master, TIOCSWINSZ, @intFromPtr(&size))) == .SUCCESS);
    }

    fn answer(self: Pty, reply: []const u8) void {
        std.debug.assert(linux.write(self.master, reply.ptr, reply.len) == reply.len);
    }
};

const reply_text = "\x1b]11;rgb:1e1e/1e1e/2e2e\x1b\\";

test "asks the terminal in a quiet mode and reads the whole reply" {
    const pty = Pty.open();
    defer pty.close();

    // The terminal answers before the question is asked, exactly like a fast
    // terminal replying mid-write.
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
    // Echo was on before the query and is on again after it.
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

    // Nothing remains on the input side for the shell to mistake for typed
    // input: the whole answer was consumed.
    var descriptors = [_]linux.pollfd{.{
        .fd = pty.slave,
        .events = linux.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), linux.poll(&descriptors, descriptors.len, 50));

    // And the question did reach the terminal, unterminated by any echo.
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
    // The reply fills the buffer exactly, so the bytes behind it are still in
    // the queue when the terminator is recognised: they have to be read and
    // thrown away, not left for the shell to read as typing.
    const pty = Pty.open();
    defer pty.close();
    // Quiet mode, as `background` leaves the terminal: in canonical mode a read
    // waits for a newline that an escape sequence never contains.
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
    // Some terminals append to the answer. Whatever follows the terminator is
    // not the reply, and leaving it queued means the shell reads it as typing.
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
    // A pipe has no terminal state, so no query is attempted on it.
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
    // A signal that is not fatal for this window is left alone.
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
    // A terminal that keeps talking does not hide the terminator.
    try std.testing.expectEqual(@as(?usize, reply_text.len), Tty.replyEnd(reply_text ++ "straggler"));
    try std.testing.expectEqual(@as(?usize, 1), Tty.replyEnd("\x07"));
}

test "the terminal reports its width, and a pipe does not" {
    const pty = Pty.open();
    defer pty.close();

    var path_buffer: [32]u8 = undefined;
    // A pseudo-terminal starts with no window size at all: the width has to be
    // set before it can be read back, exactly as a real terminal would.
    const empty = Tty{ .device_path = pty.path(&path_buffer) };
    try std.testing.expectEqual(@as(?u16, null), empty.terminal().columns());
    pty.resize(100, 30);

    const adapter = Tty{ .device_path = pty.path(&path_buffer) };
    try std.testing.expectEqual(@as(u16, 100), adapter.terminal().columns().?);

    // A pipe has no window size to report.
    var pipe: [2]posix.fd_t = undefined;
    std.debug.assert(linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) == .SUCCESS);
    defer _ = linux.close(pipe[0]);
    defer _ = linux.close(pipe[1]);
    var pipe_path: [32]u8 = undefined;
    const from_pipe = Tty{
        .device_path = std.fmt.bufPrint(&pipe_path, "/proc/self/fd/{d}", .{pipe[0]}) catch unreachable,
    };
    try std.testing.expectEqual(@as(?u16, null), from_pipe.terminal().columns());
}
