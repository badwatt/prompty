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

pub const Runner = struct {
    /// The environment block: handed to the child unchanged and used to find
    /// `PATH`.
    block: [:null]const ?[*:0]const u8,

    /// Overrides the `PATH` search; tests and embedders use it.
    search_path: ?[]const u8 = null,

    /// A command that has not finished by now is killed and reported as failed.
    timeout_ms: i32 = 2_000,

    pub const max_arguments = 16;
    pub const max_path_bytes = 4096;

    pub fn command(self: *const Runner) ports.Command {
        return .{
            .ptr = @ptrCast(@constCast(self)),
            .vtable = &vtable,
        };
    }

    const vtable = ports.Command.VTable{ .run = run };

    fn run(ptr: *anyopaque, argv: []const [:0]const u8, stdout: []u8) ?[]const u8 {
        const self: *const Runner = @ptrCast(@alignCast(ptr));
        std.debug.assert(argv.len > 0);
        std.debug.assert(argv.len <= max_arguments);

        // Prepared before the fork so that the child does nothing but exec.
        var pointers: [max_arguments + 1]?[*:0]const u8 = undefined;
        for (argv, 0..) |argument, index| pointers[index] = argument.ptr;
        pointers[argv.len] = null;
        const arguments: [*:null]const ?[*:0]const u8 = @ptrCast(&pointers);

        var pipe: [2]posix.fd_t = undefined;
        if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) return null;
        const read_end = pipe[0];
        const write_end = pipe[1];

        // A failed fork reports a negative error in the low bits; the child
        // check below simply never matches, and the wait at the end turns the
        // whole attempt into a clean failure.
        const child: linux.pid_t = @bitCast(@as(u32, @truncate(linux.fork())));
        if (child == 0) {
            _ = linux.close(read_end);
            _ = linux.dup2(write_end, posix.STDOUT_FILENO);
            _ = linux.close(write_end);
            exec(self, argv[0], arguments);
        }

        _ = linux.close(write_end);

        var filled: usize = 0;
        while (filled < stdout.len) {
            var descriptors = [_]linux.pollfd{.{
                .fd = read_end,
                .events = linux.POLL.IN,
                .revents = 0,
            }};
            // Zero means the deadline expired and an error means the wait is
            // hopeless; either way there is nothing more to read.
            const ready = linux.poll(&descriptors, descriptors.len, self.timeout_ms);
            if (linux.errno(ready) != .SUCCESS or ready == 0) break;
            // A read error is indistinguishable from the end of the output for
            // our purposes: both mean "nothing more to parse".
            const received = posix.read(read_end, stdout[filled..]) catch 0;
            if (received == 0) break;
            filled += received;
        }
        _ = linux.close(read_end);

        // Reap without blocking. A child that is still alive overran the
        // deadline (or could not finish writing because the buffer was full),
        // so it is killed and reaped again.
        var wait_status: i32 = 0;
        const first = linux.wait4(child, &wait_status, linux.W.NOHANG, null);
        if (linux.errno(first) != .SUCCESS) return null;
        if (first == 0) {
            _ = linux.kill(child, .KILL);
            if (linux.errno(linux.wait4(child, &wait_status, 0, null)) != .SUCCESS) return null;
        }

        // Output that did not fit cannot be parsed, so it is not a result.
        if (filled == stdout.len) return null;

        const status: u32 = @bitCast(wait_status);
        if (status & 0x7f != 0) return null; // killed by a signal
        if ((status & 0xff00) >> 8 != 0) return null; // non-zero exit
        return stdout[0..filled];
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
        }

        const path = self.searchPath();
        var buffer: [max_path_bytes]u8 = undefined;
        var directories = std.mem.splitScalar(u8, path, ':');
        while (directories.next()) |directory| {
            const candidate = join(&buffer, directory, program) orelse continue;
            execute(candidate, arguments, environment);
        }
        linux.exit_group(127);
    }

    fn execute(
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

    fn join(buffer: []u8, directory: []const u8, program: []const u8) ?[]const u8 {
        const separator: usize = @intFromBool(directory.len > 0);
        const total = directory.len + separator + program.len;
        if (total > buffer.len) return null;
        @memcpy(buffer[0..directory.len], directory);
        var written = directory.len;
        if (separator == 1) {
            buffer[written] = '/';
            written += 1;
        }
        @memcpy(buffer[written..][0..program.len], program);
        return buffer[0 .. written + program.len];
    }
};

/// `/bin/sh` is the one program every Linux system has, so the process
/// machinery is tested through it. The application never uses a shell.
fn testRunner(search_path: ?[]const u8) Runner {
    return .{
        .block = &.{},
        .search_path = search_path,
        .timeout_ms = 5_000,
    };
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
    // No search path given: the runner falls back to the usual directories.
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
        runner.command().run(&.{ "/bin/sh", "-c", "sleep 5" }, &output),
    );
}

test "output larger than the buffer is truncated, not hung on" {
    var runner = testRunner(null);
    var output: [8]u8 = undefined;
    // The writer blocks once the pipe fills; closing the read end unblocks it.
    const result = runner.command().run(&.{ "/bin/sh", "-c", "yes 0123456789" }, &output);
    try std.testing.expectEqual(@as(?[]const u8, null), result);
}

test "a search path entry that does not fit is skipped, not truncated" {
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        Runner.join(&buffer, "/very/long/directory", "program"),
    );
    try std.testing.expectEqualStrings("/bin/sh", Runner.join(&buffer, "/bin", "sh").?);
    // An empty PATH entry means the current directory, so no separator is added.
    try std.testing.expectEqualStrings("sh", Runner.join(&buffer, "", "sh").?);
}
