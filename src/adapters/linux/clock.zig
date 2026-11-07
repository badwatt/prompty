//! Clock adapter: the wall clock in two syscalls (well, one syscall plus one
//! bounded read of the zone the machine already has on disk).

const std = @import("std");
const linux = std.os.linux;

const ports = @import("../../ports/host.zig");
const tzif = @import("../tzif.zig");

/// Where distributions keep their compiled zones, in the order they are tried.
/// `/usr/share/zoneinfo` is the FHS answer; `/etc/zoneinfo` is where NixOS puts
/// them, and a machine can have the first without the second or the other way
/// round.
pub const default_roots = [_][]const u8{ "/usr/share/zoneinfo", "/etc/zoneinfo" };

pub const LocalClock = struct {
    /// Overridable so tests can point at fixtures instead of the host's
    /// database.
    roots: []const []const u8 = &default_roots,

    files: ports.Files,
    environ: ports.Environ,

    /// The longest TZif file shipped in practice is under 4 KiB; 16 KiB cannot
    /// be reached by a real zone and keeps the parse bounded.
    const zone_capacity = 16 * 1024;

    /// Static for the same reason as the git status buffer: the prompt runs on
    /// the shell's stack, and sixteen kilobytes of it for a file that is read
    /// once per render is budget spent on nothing.
    var zone_storage: [zone_capacity]u8 = undefined;

    pub fn clock(self: *const LocalClock) ports.Clock {
        return ports.wrap(ports.Clock, self, &vtable);
    }

    const vtable = ports.Clock.VTable{ .now = now, .offsetAt = offsetAt };

    fn now(_: *anyopaque) i64 {
        var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
        if (linux.errno(linux.clock_gettime(linux.CLOCK.REALTIME, &ts)) != .SUCCESS) return 0;
        return ts.sec;
    }

    fn offsetAt(ptr: *anyopaque, unix_seconds: i64) i32 {
        const self: *const LocalClock = @ptrCast(@alignCast(ptr));
        var path_buffer: [4096]u8 = undefined;
        const zone_path = self.zonePath(&path_buffer) orelse return 0;

        const data = self.files.read(zone_path, &zone_storage) orelse return 0;
        return tzif.offsetAt(data, unix_seconds) orelse 0;
    }

    /// Resolves `TZ` the way libc would, minus the POSIX rule syntax: an
    /// absolute path wins, `TZDIR` says where the zones live when it is set, a
    /// zone name is looked for under `roots`, and an empty `TZ` means UTC.
    ///
    /// `TZDIR` is not a nicety: on NixOS `/usr/share/zoneinfo` does not exist
    /// and every zone name resolved to UTC, which is a prompt that lies about
    /// the time.
    fn zonePath(self: *const LocalClock, buffer: []u8) ?[]const u8 {
        const tz_definition = self.environ.get("TZ") orelse return "/etc/localtime";
        var name = tz_definition;
        if (name.len > 0 and name[0] == ':') name = name[1..];
        if (name.len == 0) return null;
        if (name[0] == '/') return name;
        if (std.mem.indexOfScalar(u8, name, 0) != null) return null;

        if (self.environ.get("TZDIR")) |directory| {
            if (directory.len > 0) {
                return std.fmt.bufPrint(buffer, "{s}/{s}", .{ directory, name }) catch null;
            }
        }
        for (self.roots) |root| {
            const candidate = std.fmt.bufPrint(buffer, "{s}/{s}", .{ root, name }) catch continue;
            if (self.files.exists(candidate)) return candidate;
        }
        return null;
    }
};

test "TZ without a name means UTC" {
    const fixture = @import("../../test_support/fakes.zig");
    var env = fixture.FakeEnv.init(&.{.{ "TZ", "" }});
    var files = fixture.FakeFiles.init(&.{});
    const adapter = LocalClock{
        .files = files.files(),
        .environ = env.environ(),
    };
    try std.testing.expectEqual(@as(i32, 0), adapter.clock().offsetAt(0));
    try std.testing.expectEqual(@as(usize, 0), files.read_count);
}

test "TZ with an absolute path is used as is" {
    const fixture = @import("../../test_support/fakes.zig");
    var env = fixture.FakeEnv.init(&.{.{ "TZ", ":/tmp/somewhere/tz" }});
    var files = fixture.FakeFiles.init(&.{
        .{ .path = "/tmp/somewhere/tz", .contents = "not a zone" },
    });
    const adapter = LocalClock{
        .files = files.files(),
        .environ = env.environ(),
    };
    try std.testing.expectEqual(@as(i32, 0), adapter.clock().offsetAt(0));
    try std.testing.expectEqualStrings("/tmp/somewhere/tz", files.last_path);
}

test "TZ with a zone name resolves under the zoneinfo roots" {
    const fixture = @import("../../test_support/fakes.zig");
    var env = fixture.FakeEnv.init(&.{.{ "TZ", "Europe/Madrid" }});
    var files = fixture.FakeFiles.withDirectories(&.{}, &.{"/zoneinfo/Europe/Madrid"});
    const adapter = LocalClock{
        .roots = &.{"/zoneinfo"},
        .files = files.files(),
        .environ = env.environ(),
    };
    try std.testing.expectEqual(@as(i32, 0), adapter.clock().offsetAt(0));
    try std.testing.expectEqualStrings("/zoneinfo/Europe/Madrid", files.last_path);
}

test "TZDIR is where libc looks, so it is where prompty looks first" {
    const fixture = @import("../../test_support/fakes.zig");
    var env = fixture.FakeEnv.init(&.{
        .{ "TZ", "Europe/Madrid" },
        .{ "TZDIR", "/tzdir" },
    });
    var files = fixture.FakeFiles.init(&.{});
    const adapter = LocalClock{
        .roots = &.{"/nothing/here"},
        .files = files.files(),
        .environ = env.environ(),
    };
    _ = adapter.clock().offsetAt(0);
    try std.testing.expectEqualStrings("/tzdir/Europe/Madrid", files.last_path);
}

test "a zone is found under whichever root actually has it" {
    const fixture = @import("../../test_support/fakes.zig");
    {
        var env = fixture.FakeEnv.init(&.{.{ "TZ", "Europe/Madrid" }});
        var files = fixture.FakeFiles.withDirectories(&.{}, &.{"/second/Europe/Madrid"});
        const adapter = LocalClock{
            .roots = &.{ "/first", "/second" },
            .files = files.files(),
            .environ = env.environ(),
        };
        _ = adapter.clock().offsetAt(0);
        try std.testing.expectEqualStrings("/second/Europe/Madrid", files.last_path);
    }
    {
        var env = fixture.FakeEnv.init(&.{.{ "TZ", "Europe/Madrid" }});
        var files = fixture.FakeFiles.init(&.{});
        const adapter = LocalClock{
            .roots = &.{ "/first", "/second" },
            .files = files.files(),
            .environ = env.environ(),
        };
        try std.testing.expectEqual(@as(i32, 0), adapter.clock().offsetAt(0));
        try std.testing.expectEqualStrings("", files.last_path);
    }
}

test "without TZ the system zone is read" {
    const fixture = @import("../../test_support/fakes.zig");
    var env = fixture.FakeEnv.init(&.{});
    var files = fixture.FakeFiles.init(&.{});
    const adapter = LocalClock{
        .files = files.files(),
        .environ = env.environ(),
    };
    try std.testing.expectEqual(@as(i32, 0), adapter.clock().offsetAt(0));
    try std.testing.expectEqualStrings("/etc/localtime", files.last_path);
}

test "the wall clock is plausible" {
    const fixture = @import("../../test_support/fakes.zig");
    var env = fixture.FakeEnv.init(&.{});
    var files = fixture.FakeFiles.init(&.{});
    const adapter = LocalClock{
        .files = files.files(),
        .environ = env.environ(),
    };
    const now = adapter.clock().now();
    try std.testing.expect(now > 1_577_836_800);
    try std.testing.expect(now < 4_102_444_800);
}
