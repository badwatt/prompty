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
    sources: []const File,
    /// Paths the fake filesystem reports as "the working directory" candidates,
    /// in the order `currentDir` should hand them out.
    directories: []const []const u8,
    read_count: usize = 0,
    last_path: []const u8 = "",
    written: [4]Write = undefined,
    write_storage: [256]u8 = undefined,
    write_storage_used: usize = 0,
    write_count: usize = 0,

    pub const Write = struct { path: []const u8, bytes: []const u8 };

    pub fn init(sources: []const File) FakeFiles {
        return .{ .sources = sources, .directories = &.{} };
    }

    pub fn withDirectories(sources: []const File, directories: []const []const u8) FakeFiles {
        return .{ .sources = sources, .directories = directories };
    }

    pub fn files(self: *FakeFiles) ports.Files {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = ports.Files.VTable{
        .read = read,
        .write = write,
        .exists = exists,
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

    fn write(ptr: *anyopaque, path: []const u8, bytes: []const u8) bool {
        const self: *FakeFiles = @ptrCast(@alignCast(ptr));
        self.write_count += 1;
        if (bytes.len > self.write_storage.len - self.write_storage_used) return false;
        if (self.write_count > self.written.len) return false;
        @memcpy(self.write_storage[self.write_storage_used..][0..bytes.len], bytes);
        self.written[self.write_count - 1] = .{
            .path = path,
            .bytes = self.write_storage[self.write_storage_used..][0..bytes.len],
        };
        self.write_storage_used += bytes.len;
        return true;
    }

    fn exists(ptr: *anyopaque, path: []const u8) bool {
        const self: *FakeFiles = @ptrCast(@alignCast(ptr));
        for (self.sources) |file| {
            if (std.mem.eql(u8, file.path, path)) return true;
        }
        for (self.directories) |directory| {
            if (std.mem.eql(u8, directory, path)) return true;
        }
        return false;
    }

    fn currentDir(ptr: *anyopaque, buffer: []u8) ?[]const u8 {
        const self: *FakeFiles = @ptrCast(@alignCast(ptr));
        if (self.directories.len == 0) return null;
        const path = self.directories[0];
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

pub const FakeCommand = struct {
    response: ?[]const u8 = null,
    /// The last argument vector, joined with spaces, so a test can ask what the
    /// program was actually run with.
    argv_buffer: [256]u8 = undefined,
    argv_length: usize = 0,
    calls: usize = 0,

    pub fn lastArgv(self: *const FakeCommand) []const u8 {
        return self.argv_buffer[0..self.argv_length];
    }

    pub fn command(self: *FakeCommand) ports.Command {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = ports.Command.VTable{ .run = run };

    fn run(ptr: *anyopaque, arguments: []const [:0]const u8, stdout: []u8) ?[]const u8 {
        const self: *FakeCommand = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        self.argv_length = 0;
        for (arguments, 0..) |argument, index| {
            if (self.argv_length + argument.len + 1 > self.argv_buffer.len) break;
            if (index > 0) {
                self.argv_buffer[self.argv_length] = ' ';
                self.argv_length += 1;
            }
            @memcpy(self.argv_buffer[self.argv_length..][0..argument.len], argument);
            self.argv_length += argument.len;
        }
        const response = self.response orelse return null;
        const length = @min(response.len, stdout.len);
        @memcpy(stdout[0..length], response[0..length]);
        return stdout[0..length];
    }
};

pub const FakeTerminal = struct {
    response: ?[]const u8 = null,

    pub fn terminal(self: *FakeTerminal) ports.Terminal {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = ports.Terminal.VTable{ .background = background };

    fn background(ptr: *anyopaque, buffer: []u8) ?[]const u8 {
        const self: *FakeTerminal = @ptrCast(@alignCast(ptr));
        const response = self.response orelse return null;
        const length = @min(response.len, buffer.len);
        @memcpy(buffer[0..length], response[0..length]);
        return buffer[0..length];
    }
};

/// A whole fake host: the unit under test sees exactly the ports the real
/// process wires together.
pub const FakeHost = struct {
    files: FakeFiles,
    environment: FakeEnv,
    clock: FakeClock,
    terminal: FakeTerminal,
    commands: FakeCommand = .{},
    out: FakeOutput = .{},
    diagnostics: FakeOutput = .{},
    user_id: u32 = 1000,
    hostname: ?[]const u8 = null,

    pub fn host(self: *FakeHost) ports.Host {
        return .{
            .files = self.files.files(),
            .environ = self.environment.environ(),
            .clock = self.clock.clock(),
            .commands = self.commands.command(),
            .terminal = self.terminal.terminal(),
            .stdout = self.out.output(),
            .stderr = self.diagnostics.output(),
            .user_id = self.user_id,
            .hostname = self.hostname,
        };
    }

    pub fn stdout(self: *FakeHost) []const u8 {
        return self.out.written();
    }

    pub fn stderr(self: *FakeHost) []const u8 {
        return self.diagnostics.written();
    }
};
