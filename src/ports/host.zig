//! The ports. Everything the prompt needs from the outside world goes through
//! one of these four interfaces, which is what makes the whole renderer
//! testable without touching a filesystem, a clock or a terminal.

const std = @import("std");

pub const Files = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (ptr: *anyopaque, path: []const u8, buffer: []u8) ?[]u8,
        write: *const fn (ptr: *anyopaque, path: []const u8, bytes: []const u8) bool,
        exists: *const fn (ptr: *anyopaque, path: []const u8) bool,
        currentDir: *const fn (ptr: *anyopaque, buffer: []u8) ?[]const u8,
    };

    /// Reads at most `buffer.len` bytes. Null means "cannot be read", which for
    /// a prompt is a fact of life, not an error to propagate.
    pub fn read(self: Files, path: []const u8, buffer: []u8) ?[]u8 {
        return self.vtable.read(self.ptr, path, buffer);
    }

    /// Writes a small file, creating its parent directories when needed.
    /// Failure is not an error: a prompt still renders with the default theme.
    pub fn write(self: Files, path: []const u8, bytes: []const u8) bool {
        return self.vtable.write(self.ptr, path, bytes);
    }

    pub fn exists(self: Files, path: []const u8) bool {
        return self.vtable.exists(self.ptr, path);
    }

    pub fn currentDir(self: Files, buffer: []u8) ?[]const u8 {
        return self.vtable.currentDir(self.ptr, buffer);
    }
};

pub const Environ = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (ptr: *anyopaque, name: []const u8) ?[]const u8,
    };

    pub fn get(self: Environ, name: []const u8) ?[]const u8 {
        return self.vtable.get(self.ptr, name);
    }
};

pub const Clock = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        now: *const fn (ptr: *anyopaque) i64,
        offsetAt: *const fn (ptr: *anyopaque, unix_seconds: i64) i32,
    };

    pub fn now(self: Clock) i64 {
        return self.vtable.now(self.ptr);
    }

    pub fn offsetAt(self: Clock, unix_seconds: i64) i32 {
        return self.vtable.offsetAt(self.ptr, unix_seconds);
    }
};

pub const Output = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        write: *const fn (ptr: *anyopaque, bytes: []const u8) void,
    };

    pub fn write(self: Output, bytes: []const u8) void {
        self.vtable.write(self.ptr, bytes);
    }
};

/// Runs an external command as an argument vector — never through a shell —
/// and hands back its standard output. Null means "could not run, or it
/// failed": for a prompt that is a dead end, not an error.
pub const Command = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        run: *const fn (ptr: *anyopaque, argv: []const [:0]const u8, stdout: []u8) ?[]const u8,
    };

    pub fn run(self: Command, argv: []const [:0]const u8, stdout: []u8) ?[]const u8 {
        std.debug.assert(argv.len > 0);
        std.debug.assert(stdout.len > 0);
        return self.vtable.run(self.ptr, argv, stdout);
    }
};

/// The terminal itself, questioned only when the user asks for it: an OSC
/// round trip is far too expensive for a prompt, but perfectly fine once.
pub const Terminal = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        background: *const fn (ptr: *anyopaque, buffer: []u8) ?[]const u8,
    };

    pub fn background(self: Terminal, buffer: []u8) ?[]const u8 {
        return self.vtable.background(self.ptr, buffer);
    }
};

pub const Host = struct {
    files: Files,
    environ: Environ,
    clock: Clock,
    commands: Command,
    terminal: Terminal,
    stdout: Output,
    stderr: Output,
    user_id: u32,
    /// This machine's name, when it could be read. A prompt reached over SSH
    /// says which machine it is instead of who you are there.
    hostname: ?[]const u8 = null,
};
