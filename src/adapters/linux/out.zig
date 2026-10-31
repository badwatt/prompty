//! Output adapter. One buffer, one write syscall, and never a broken pipe
//! complaint: if the terminal went away there is nobody left to care.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const ports = @import("../../ports/host.zig");

pub const Out = struct {
    fd: posix.fd_t,

    pub const stdout: Out = .{ .fd = posix.STDOUT_FILENO };
    pub const stderr: Out = .{ .fd = posix.STDERR_FILENO };

    pub fn output(self: *const Out) ports.Output {
        return .{
            .ptr = @constCast(@ptrCast(self)),
            .vtable = &vtable,
        };
    }

    const vtable = ports.Output.VTable{ .write = writeAll };

    fn writeAll(ptr: *anyopaque, bytes: []const u8) void {
        const self: *const Out = @ptrCast(@alignCast(ptr));
        var written: usize = 0;
        while (written < bytes.len) {
            const rc = linux.write(self.fd, bytes[written..].ptr, bytes.len - written);
            if (linux.errno(rc) != .SUCCESS) return;
            if (rc == 0) return;
            written += rc;
        }
    }
};
