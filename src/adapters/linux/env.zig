//! Environment adapter: a linear scan over the process environment block the
//! kernel already handed us. No hashing, no allocation, and it costs a few
//! dozen nanoseconds per lookup for a realistic environment.

const std = @import("std");

const ports = @import("../../ports/host.zig");

pub const Env = struct {
    block: [:null]const ?[*:0]const u8,

    pub fn environ(self: *const Env) ports.Environ {
        return ports.wrap(ports.Environ, self, &vtable);
    }

    const vtable = ports.Environ.VTable{ .get = lookup };

    fn lookup(ptr: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *const Env = @ptrCast(@alignCast(ptr));
        std.debug.assert(name.len > 0);
        for (self.block) |maybe_entry| {
            const entry = std.mem.span(maybe_entry orelse continue);
            if (entry.len <= name.len) continue;
            if (!std.mem.startsWith(u8, entry, name)) continue;
            if (entry[name.len] != '=') continue;
            return entry[name.len + 1 ..];
        }
        return null;
    }
};
