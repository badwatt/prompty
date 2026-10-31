//! In-memory doubles for every port. Keeping them in one place means the
//! application layer is tested against exactly the same interfaces the real
//! adapters implement.

const std = @import("std");

const ports = @import("../ports/host.zig");

pub const FakeFiles = struct {
    pub const File = struct {
        path: []const u8,
        contents: []const u8,
    };
    pub const Directory = struct {
        path: []const u8,
        entries: []const ports.Entry,
    };

    sources: []const File,
    directories: []const Directory,
    read_count: usize = 0,
    last_path: []const u8 = "",

    pub fn init(sources: []const File) FakeFiles {
        return .{ .sources = sources, .directories = &.{} };
    }

    pub fn withDirectories(sources: []const File, directories: []const Directory) FakeFiles {
        return .{ .sources = sources, .directories = directories };
    }

    pub fn files(self: *FakeFiles) ports.Files {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = ports.Files.VTable{
        .read = read,
        .exists = exists,
        .scan = scan,
        .currentDir = currentDir,
    };

    fn read(ptr: *anyopaque, path: []const u8, buffer: []u8) ?[]u8 {
        const self: *FakeFiles = @ptrCast(@alignCast(ptr));
        self.read_count += 1;
        self.last_path = path;
        for (self.sources) |file| {
            if (!std.mem.eql(u8, file.path, path)) continue;
            const length = @min(file.contents.len, buffer.len);
            @memcpy(buffer[0..length], file.contents[0..length]);
            return buffer[0..length];
        }
        return null;
    }

    fn exists(ptr: *anyopaque, path: []const u8) bool {
        const self: *FakeFiles = @ptrCast(@alignCast(ptr));
        for (self.sources) |file| {
            if (std.mem.eql(u8, file.path, path)) return true;
        }
        for (self.directories) |directory| {
            if (std.mem.eql(u8, directory.path, path)) return true;
        }
        return false;
    }

    fn scan(ptr: *anyopaque, path: []const u8, context: *anyopaque, visitor: ports.Visitor) bool {
        const self: *FakeFiles = @ptrCast(@alignCast(ptr));
        for (self.directories) |directory| {
            if (!std.mem.eql(u8, directory.path, path)) continue;
            for (directory.entries) |entry| visitor(context, entry);
            return true;
        }
        return false;
    }

    fn currentDir(ptr: *anyopaque, buffer: []u8) ?[]const u8 {
        const self: *FakeFiles = @ptrCast(@alignCast(ptr));
        // The first directory is the working directory of the fixture.
        if (self.directories.len == 0) return null;
        const path = self.directories[0].path;
        if (path.len > buffer.len) return null;
        @memcpy(buffer[0..path.len], path);
        return buffer[0..path.len];
    }
};

pub const FakeEnv = struct {
    entries: []const [2][]const u8,

    pub fn init(entries: []const [2][]const u8) FakeEnv {
        return .{ .entries = entries };
    }

    pub fn environ(self: *FakeEnv) ports.Environ {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = ports.Environ.VTable{ .get = get };

    fn get(ptr: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *FakeEnv = @ptrCast(@alignCast(ptr));
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry[0], name)) return entry[1];
        }
        return null;
    }
};

pub const FakeClock = struct {
    unix_seconds: i64 = 1_700_000_000,
    offset_seconds: i32 = 0,

    pub fn clock(self: *FakeClock) ports.Clock {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = ports.Clock.VTable{ .now = now, .offsetAt = offsetAt };

    fn now(ptr: *anyopaque) i64 {
        const self: *FakeClock = @ptrCast(@alignCast(ptr));
        return self.unix_seconds;
    }

    fn offsetAt(ptr: *anyopaque, unix_seconds: i64) i32 {
        _ = unix_seconds;
        const self: *FakeClock = @ptrCast(@alignCast(ptr));
        return self.offset_seconds;
    }
};

pub const FakeOutput = struct {
    buffer: [4096]u8 = undefined,
    length: usize = 0,
    writes: usize = 0,

    pub fn output(self: *FakeOutput) ports.Output {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn written(self: *const FakeOutput) []const u8 {
        return self.buffer[0..self.length];
    }

    const vtable = ports.Output.VTable{ .write = write };

    fn write(ptr: *anyopaque, bytes: []const u8) void {
        const self: *FakeOutput = @ptrCast(@alignCast(ptr));
        self.writes += 1;
        const room = @min(bytes.len, self.buffer.len - self.length);
        @memcpy(self.buffer[self.length..][0..room], bytes[0..room]);
        self.length += room;
    }
};
