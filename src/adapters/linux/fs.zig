//! Linux file adapter: plain syscalls, no heap, no libc.
//!
//! Every read is bounded by the caller's buffer. Nothing in a prompt is worth
//! growing the heap for, and a fixed buffer means the cost of a render is
//! independent of the size of the files it happens to touch.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const ports = @import("../../ports/host.zig");

pub const Fs = struct {
    pub const instance: Fs = .{};

    pub fn files(self: *const Fs) ports.Files {
        return .{
            .ptr = @ptrCast(@constCast(self)),
            .vtable = &vtable,
        };
    }

    const vtable = ports.Files.VTable{
        .read = readFile,
        .write = writeFile,
        .exists = exists,
        .scan = scanDir,
        .currentDir = currentDir,
    };

    fn readFile(_: *anyopaque, path: []const u8, buffer: []u8) ?[]u8 {
        std.debug.assert(buffer.len > 0);
        const fd = openPath(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) orelse return null;
        defer _ = linux.close(fd);
        return readAll(fd, buffer);
    }

    fn writeFile(_: *anyopaque, path: []const u8, bytes: []const u8) bool {
        std.debug.assert(path.len > 0);
        makeParentDirectories(path);

        // Write a sibling and rename it over the target: two shells starting at
        // once must never leave a reader looking at half a file.
        var temporary: [4096]u8 = undefined;
        const temporary_path = std.fmt.bufPrint(&temporary, "{s}.tmp", .{path}) catch return false;
        if (!writeDirect(temporary_path, bytes)) return false;
        return rename(temporary_path, path);
    }

    fn writeDirect(path: []const u8, bytes: []const u8) bool {
        const options = linux.O{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .TRUNC = true,
            .CLOEXEC = true,
        };
        const fd = openPath(path, options, 0o644) orelse return false;
        defer _ = linux.close(fd);
        var written: usize = 0;
        while (written < bytes.len) {
            const rc = linux.write(fd, bytes[written..].ptr, bytes.len - written);
            if (linux.errno(rc) != .SUCCESS) return false;
            written += rc;
        }
        return true;
    }

    fn rename(from: []const u8, to: []const u8) bool {
        var from_buffer: [4096]u8 = undefined;
        var to_buffer: [4096]u8 = undefined;
        if (from.len + 1 > from_buffer.len) return false;
        if (to.len + 1 > to_buffer.len) return false;
        @memcpy(from_buffer[0..from.len], from);
        from_buffer[from.len] = 0;
        @memcpy(to_buffer[0..to.len], to);
        to_buffer[to.len] = 0;
        const rc = linux.renameat(linux.AT.FDCWD, from_buffer[0..from.len :0], linux.AT.FDCWD, to_buffer[0..to.len :0]);
        return linux.errno(rc) == .SUCCESS;
    }

    fn exists(_: *anyopaque, path: []const u8) bool {
        const fd = openPath(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) orelse return false;
        _ = linux.close(fd);
        return true;
    }

    /// Creates every missing ancestor of `path`, ignoring failures: if the
    /// directory cannot be created the following open will fail cleanly.
    fn makeParentDirectories(path: []const u8) void {
        var buffer: [4096]u8 = undefined;
        if (path.len + 1 > buffer.len) return;
        @memcpy(buffer[0..path.len], path);
        buffer[path.len] = 0;

        var index: usize = 1;
        while (index < path.len) : (index += 1) {
            if (buffer[index] != '/') continue;
            buffer[index] = 0;
            _ = linux.mkdirat(linux.AT.FDCWD, @ptrCast(&buffer), 0o755);
            buffer[index] = '/';
        }
    }

    fn scanDir(_: *anyopaque, path: []const u8, context: *anyopaque, visitor: ports.Visitor) bool {
        const options = linux.O{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
        const fd = openPath(path, options, 0) orelse return false;
        defer _ = linux.close(fd);

        var buffer: [4096]u8 align(@alignOf(linux.dirent64)) = undefined;
        while (true) {
            // A directory is read with getdents64, never with read(2): the
            // latter always fails with EISDIR.
            const rc = linux.getdents64(fd, &buffer, buffer.len);
            if (linux.errno(rc) != .SUCCESS) return false;
            const filled: usize = rc;
            if (filled == 0) return true;
            var offset: usize = 0;
            while (offset < filled) {
                const record: *const linux.dirent64 = @ptrCast(@alignCast(&buffer[offset]));
                // A zero-length record would spin forever, and the release
                // build is the one that ships: check it, do not assert it.
                if (record.reclen == 0 or offset + record.reclen > filled) return false;
                const name = entryName(buffer[offset..filled]);
                if (name) |valid| {
                    visitor(context, .{
                        .name = valid,
                        .is_dir = record.type == linux.DT.DIR,
                    });
                }
                offset += record.reclen;
            }
        }
    }

    fn currentDir(_: *anyopaque, buffer: []u8) ?[]const u8 {
        const rc = linux.getcwd(buffer.ptr, buffer.len);
        if (linux.errno(rc) != .SUCCESS) return null;
        // The kernel returns the length including the trailing NUL.
        if (rc == 0 or rc > buffer.len) return null;
        return buffer[0 .. rc - 1];
    }

    fn entryName(available: []const u8) ?[]const u8 {
        const name_offset = @offsetOf(linux.dirent64, "name");
        if (available.len <= name_offset) return null;
        const name_field = available[name_offset..];
        const end = std.mem.indexOfScalar(u8, name_field, 0) orelse return null;
        const name = name_field[0..end];
        if (name.len == 0) return null;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return null;
        return name;
    }

    fn openPath(path: []const u8, options: linux.O, mode: linux.mode_t) ?linux.fd_t {
        std.debug.assert(path.len > 0);
        return posix.openat(linux.AT.FDCWD, path, options, mode) catch null;
    }

    fn readAll(fd: linux.fd_t, buffer: []u8) ?[]u8 {
        var filled: usize = 0;
        while (filled < buffer.len) {
            const chunk = posix.read(fd, buffer[filled..]) catch return null;
            if (chunk == 0) break;
            filled += chunk;
        }
        return buffer[0..filled];
    }
};

test "the real adapter reads, lists, writes and reports the working directory" {
    const files = Fs.instance.files();

    var cwd_buffer: [4096]u8 = undefined;
    const cwd = files.currentDir(&cwd_buffer).?;
    try std.testing.expect(cwd.len > 0);
    try std.testing.expect(cwd[0] == '/');

    var content_buffer: [8192]u8 = undefined;
    const content = files.read("src/adapters/linux/fs.zig", &content_buffer).?;
    try std.testing.expect(std.mem.indexOf(u8, content, "Linux file adapter") != null);

    try std.testing.expect(files.read("src/definitely/missing", &content_buffer) == null);
    try std.testing.expect(!files.exists("src/definitely/missing"));
    try std.testing.expect(files.exists("src/adapters/linux/fs.zig"));

    const Counter = struct {
        seen: usize = 0,
        seen_directory: bool = false,

        fn visit(context: *anyopaque, entry: ports.Entry) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.seen += 1;
            if (entry.is_dir and std.mem.eql(u8, entry.name, "domain")) self.seen_directory = true;
        }
    };

    var counter = Counter{};
    try std.testing.expect(files.scan("src", &counter, Counter.visit));
    try std.testing.expect(counter.seen > 3);
    try std.testing.expect(counter.seen_directory);
    try std.testing.expect(!files.scan("src/definitely/missing", &counter, Counter.visit));

    // Writing creates every missing ancestor.
    var path_buffer: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, ".zig-cache/prompty-adapter-test/nested/theme", .{}) catch unreachable;
    try std.testing.expect(files.write(path, "#123456\n"));

    var read_back: [16]u8 = undefined;
    try std.testing.expectEqualStrings("#123456\n", files.read(path, &read_back).?);

    // Clean up the scratch tree so the test is repeatable.
    var zero_terminated: [129]u8 = undefined;
    @memcpy(zero_terminated[0..path.len], path);
    zero_terminated[path.len] = 0;
    _ = linux.unlinkat(linux.AT.FDCWD, zero_terminated[0..path.len :0], 0);
    _ = linux.unlinkat(linux.AT.FDCWD, ".zig-cache/prompty-adapter-test/nested", linux.AT.REMOVEDIR);
    _ = linux.unlinkat(linux.AT.FDCWD, ".zig-cache/prompty-adapter-test", linux.AT.REMOVEDIR);
}
