//! Process adapter: fork, exec, drain the pipe, reap. No shell, no allocator,
//! and a hard deadline so a slow command can never hold a prompt hostage.
//!
//! This exists for exactly one caller — the git status query — and that is the
//! only place a prompt is allowed to spend a millisecond on someone else's
//! process.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const ports = @import("../../ports/host.zig");
const path_mod = @import("../../domain/path.zig");
const syscall = @import("syscall.zig");

pub const Runner = struct {
    /// The environment block: handed to the child unchanged and used to find
    /// `PATH`.
    block: [:null]const ?[*:0]const u8,

    /// Overrides the `PATH` search; tests and embedders use it.
    search_path: ?[]const u8 = null,

    /// A command that has not finished this many milliseconds after it started
    /// is killed and reported as failed. It is one deadline for the whole run,
    /// not a limit on each read: a program that dribbles a byte every little
    /// while would otherwise hold the prompt open for as long as it liked.
    timeout_ms: i32 = 2_000,

    /// The syscall behind `run`. Injectable because a failed fork cannot be
    /// forced on demand — it takes a process limit — and the cleanup that runs
    /// when it does is the one that must never be mistaken for a pid.
    fork: *const fn () usize = linux.fork,

    pub const max_arguments = 16;
    pub const max_path_bytes = 4096;

    pub fn command(self: *const Runner) ports.Command {
        return ports.wrap(ports.Command, self, &vtable);
    }

    const vtable = ports.Command.VTable{ .run = run };

    fn run(ptr: *anyopaque, argv: []const [:0]const u8, stdout: []u8) ?[]const u8 {
        const self: *const Runner = @ptrCast(@alignCast(ptr));
        std.debug.assert(argv.len > 0);
        std.debug.assert(argv.len <= max_arguments);

        var pointers: [max_arguments + 1]?[*:0]const u8 = undefined;
        for (argv, 0..) |argument, index| pointers[index] = argument.ptr;
        pointers[argv.len] = null;
        const arguments: [*:null]const ?[*:0]const u8 = @ptrCast(&pointers);

        var pipe: [2]posix.fd_t = undefined;
        if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) return null;
        const read_end = pipe[0];
        const write_end = pipe[1];

        const child = childPid(self.fork()) orelse {
            _ = linux.close(read_end);
            _ = linux.close(write_end);
            return null;
        };
        if (child == 0) {
            _ = linux.close(read_end);
            _ = linux.dup2(write_end, posix.STDOUT_FILENO);
            _ = linux.close(write_end);
            divert(self, argv[0], arguments);
        }

        _ = linux.close(write_end);

        var filled: usize = 0;
        const deadline = monotonicMilliseconds() + self.timeout_ms;
        while (filled < stdout.len) {
            const left = remaining(deadline, monotonicMilliseconds());
            if (left <= 0) break;
            if (!syscall.ready(read_end, left)) break;
            const received = posix.read(read_end, stdout[filled..]) catch 0;
            if (received == 0) break;
            filled += received;
        }
        _ = linux.close(read_end);

        var wait_status: i32 = 0;
        const first = linux.wait4(child, &wait_status, linux.W.NOHANG, null);
        if (linux.errno(first) != .SUCCESS) return null;
        if (first == 0) {
            _ = linux.kill(child, .KILL);
            if (linux.errno(linux.wait4(child, &wait_status, 0, null)) != .SUCCESS) return null;
        }

        if (filled == stdout.len) return null;

        const status: u32 = @bitCast(wait_status);
        if (status & 0x7f != 0) return null;
        if ((status & 0xff00) >> 8 != 0) return null;
        return stdout[0..filled];
    }

    /// What is left of the deadline, in milliseconds; zero once it has passed.
    fn remaining(deadline: i64, now: i64) i32 {
        const left = deadline - now;
        if (left <= 0) return 0;
        return @intCast(@min(left, std.math.maxInt(i32)));
    }

    fn monotonicMilliseconds() i64 {
        var timestamp: linux.timespec = .{ .sec = 0, .nsec = 0 };
        if (linux.errno(linux.clock_gettime(linux.CLOCK.MONOTONIC, &timestamp)) != .SUCCESS) return 0;
        return @as(i64, timestamp.sec) * 1000 + @divTrunc(timestamp.nsec, 1_000_000);
    }

    /// The fork result as a child pid, or null when the fork failed.
    ///
    /// A failure has to be caught here: the result is a negated errno, and a pid
    /// of -1 means "any child" to `wait4` and "every process this user owns" to
    /// `kill`. Left unchecked, one failed fork would reap a stranger's child and
    /// then signal the whole session.
    fn childPid(forked: usize) ?linux.pid_t {
        if (linux.errno(forked) != .SUCCESS) return null;
        return @bitCast(@as(u32, @truncate(forked)));
    }

    /// Points the child's stdin and stderr at `/dev/null` and then becomes the
    /// program.
    ///
    /// Both matter. A half-initialised `.git` makes git print "fatal: not a
    /// repository" on stderr, which would land on top of the prompt line, and a
    /// program on `PATH` that reads stdin would eat the user's typing.
    fn divert(
        self: *const Runner,
        program: []const u8,
        arguments: [*:null]const ?[*:0]const u8,
    ) noreturn {
        var empty = posix.sigemptyset();
        posix.sigprocmask(posix.SIG.SETMASK, &empty, null);

        const dev_null = linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
        if (linux.errno(dev_null) == .SUCCESS) {
            _ = linux.dup2(@intCast(dev_null), posix.STDIN_FILENO);
            _ = linux.dup2(@intCast(dev_null), posix.STDERR_FILENO);
            _ = linux.close(@intCast(dev_null));
        }
        exec(self, program, arguments);
    }

    /// Replaces the child process. Every failure ends the child quietly: the
    /// parent sees an empty pipe and a non-zero status.
    fn exec(
        self: *const Runner,
        program: []const u8,
        arguments: [*:null]const ?[*:0]const u8,
    ) noreturn {
        const environment: [*:null]const ?[*:0]const u8 = self.block.ptr;

        if (std.mem.indexOfScalar(u8, program, '/') != null) {
            execute(program, arguments, environment);
            linux.exit_group(127);
        }

        const path = self.searchPath();
        var buffer: [max_path_bytes]u8 = undefined;
        var directories = std.mem.splitScalar(u8, path, ':');
        while (directories.next()) |directory| {
            const candidate = path_mod.join(&buffer, directory, program) orelse continue;
            execute(candidate, arguments, environment);
        }
        linux.exit_group(127);
    }

    /// Inlined so that its tail belongs to `exec`, which never returns: the only
    /// line this body can leave behind is the one after a failed `execve`.
    inline fn execute(
        program: []const u8,
        arguments: [*:null]const ?[*:0]const u8,
        environment: [*:null]const ?[*:0]const u8,
    ) void {
        var buffer: [max_path_bytes]u8 = undefined;
        if (program.len + 1 > buffer.len) return;
        @memcpy(buffer[0..program.len], program);
        buffer[program.len] = 0;
        _ = linux.execve(buffer[0..program.len :0], arguments, environment);
    }

    fn searchPath(self: *const Runner) []const u8 {
        if (self.search_path) |path| return path;
        for (self.block) |maybe_entry| {
            const entry = std.mem.span(maybe_entry orelse continue);
            if (std.mem.startsWith(u8, entry, "PATH=")) return entry["PATH=".len..];
        }
        return "/usr/local/bin:/usr/bin:/bin";
    }

    const join = path_mod.join;
};

/// `/bin/sh` is the one program every Linux system has, so the process
/// machinery is tested through it. The application never uses a shell.
/// A fork that failed the way one does when the user is out of processes.
fn exhaustedFork() usize {
    return @bitCast(-@as(isize, @backingInt(linux.E.AGAIN)));
}

fn testRunner(search_path: ?[]const u8) Runner {
    return .{
        .block = &.{},
        .search_path = search_path,
        .timeout_ms = 5_000,
    };
}

test "a failed fork is a failure, never a pid of minus one" {
    try std.testing.expectEqual(@as(?linux.pid_t, null), Runner.childPid(@bitCast(@as(isize, -1))));
    try std.testing.expectEqual(@as(?linux.pid_t, null), Runner.childPid(@bitCast(@as(isize, -12))));
    try std.testing.expectEqual(@as(?linux.pid_t, 4242), Runner.childPid(4242));
}

test "a child does not inherit a blocked signal" {
    var blocked = posix.sigemptyset();
    posix.sigaddset(&blocked, .USR1);
    var saved: posix.sigset_t = undefined;
    posix.sigprocmask(posix.SIG.BLOCK, &blocked, &saved);
    defer posix.sigprocmask(posix.SIG.SETMASK, &saved, null);

    var runner = testRunner(null);
    var output: [128]u8 = undefined;
    const result = runner.command().run(
        &.{ "/bin/sh", "-c", "while read -r key value; do case $key in SigBlk:) echo \"$value\";; esac; done < /proc/self/status" },
        &output,
    ).?;
    try std.testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, result, "\n"), "0000000000000000"));
}

test "a child cannot talk over the prompt or read the keyboard" {
    var runner = testRunner(null);
    var output: [64]u8 = undefined;
    const result = runner.command().run(
        &.{ "/bin/sh", "-c", "if [ /proc/self/fd/0 -ef /dev/null ] && [ /proc/self/fd/2 -ef /dev/null ]; then printf diverted; else printf inherited; fi" },
        &output,
    ).?;
    try std.testing.expectEqualStrings("diverted", result);
}

test "a failed fork closes the pipe and signals nothing" {
    var runner = testRunner(null);
    runner.fork = exhaustedFork;
    var output: [64]u8 = undefined;
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        runner.command().run(&.{"/bin/true"}, &output),
    );
    var pipe: [2]posix.fd_t = undefined;
    std.debug.assert(linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) == .SUCCESS);
    _ = linux.close(pipe[0]);
    _ = linux.close(pipe[1]);
}

test "captures the output of a real program" {
    var runner = testRunner(null);
    var output: [256]u8 = undefined;
    const result = runner.command().run(&.{ "/bin/sh", "-c", "printf hello" }, &output).?;
    try std.testing.expectEqualStrings("hello", result);
}

test "resolves a program through the search path" {
    var runner = testRunner("/bin");
    var output: [256]u8 = undefined;
    const result = runner.command().run(&.{ "sh", "-c", "printf resolved" }, &output).?;
    try std.testing.expectEqualStrings("resolved", result);
}

test "a non-zero exit is a failure" {
    var runner = testRunner(null);
    var output: [256]u8 = undefined;
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        runner.command().run(&.{ "/bin/sh", "-c", "printf partial; exit 3" }, &output),
    );
}

test "a command that does not exist is a failure" {
    var runner = testRunner(null);
    var output: [256]u8 = undefined;
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        runner.command().run(&.{ "prompty-no-such-command", "--version" }, &output),
    );
}

test "an explicit search path is honoured" {
    var runner = testRunner("/nonexistent-directory");
    var output: [256]u8 = undefined;
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        runner.command().run(&.{ "sh", "-c", "printf nope" }, &output),
    );
}

test "a command that never answers is killed" {
    var runner = testRunner(null);
    runner.timeout_ms = 20;
    var output: [256]u8 = undefined;
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        runner.command().run(&.{ "/bin/sh", "-c", "while :; do :; done" }, &output),
    );
}

test "an endless writer cannot fill the prompt or hang it" {
    var runner = testRunner(null);
    var output: [8]u8 = undefined;
    const result = runner.command().run(
        &.{ "/bin/sh", "-c", "while :; do printf 0123456789; done" },
        &output,
    );
    try std.testing.expectEqual(@as(?[]const u8, null), result);
}

test "what is left of the deadline is a countdown, never negative" {
    try std.testing.expectEqual(@as(i32, 0), Runner.remaining(1_000, 1_500));
    try std.testing.expectEqual(@as(i32, 0), Runner.remaining(1_000, 1_000));
    try std.testing.expectEqual(@as(i32, 250), Runner.remaining(1_000, 750));
    try std.testing.expectEqual(std.math.maxInt(i32), Runner.remaining(std.math.maxInt(i64), 0));
}

test "a command that dribbles is cut off at the deadline, not at the next byte" {
    var runner = testRunner(null);
    runner.timeout_ms = 120;
    var output: [256]u8 = undefined;
    const dribble = "i=0; while [ $i -lt 20 ]; do printf a; i=$((i+1)); sleep 0.04; done";
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        runner.command().run(&.{ "/bin/sh", "-c", dribble }, &output),
    );
}

test "a search path entry that does not fit is skipped, not truncated" {
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        Runner.join(&buffer, "/very/long/directory", "program"),
    );
    try std.testing.expectEqualStrings("/bin/sh", Runner.join(&buffer, "/bin", "sh").?);
    try std.testing.expectEqualStrings("sh", Runner.join(&buffer, "", "sh").?);
}
