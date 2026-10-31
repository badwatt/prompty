//! Composition root: the only file that knows about both the domain and the
//! Linux adapters. Everything below it takes its dependencies as ports.

const std = @import("std");
const linux = std.os.linux;

const args_mod = @import("application/args.zig");
const cli = @import("application/cli.zig");
const store_mod = @import("domain/store.zig");
const ports = @import("ports/host.zig");

const clock_adapter = @import("adapters/linux/clock.zig");
const env_adapter = @import("adapters/linux/env.zig");
const fs_adapter = @import("adapters/linux/fs.zig");
const out_adapter = @import("adapters/linux/out.zig");

pub fn main(minimal: std.process.Init.Minimal) u8 {
    return entry(minimal);
}

pub fn entry(minimal: std.process.Init.Minimal) u8 {
    // Statically allocated, never moved: see `domain/store.zig`.
    var store: store_mod.Store = undefined;
    store.reset();

    var environment = env_adapter.Env{ .block = minimal.environ.block.slice };
    const files = fs_adapter.Fs.instance.files();
    var wall_clock = clock_adapter.LocalClock{
        .files = files,
        .environ = environment.environ(),
    };

    const host: ports.Host = .{
        .files = files,
        .environ = environment.environ(),
        .clock = wall_clock.clock(),
        .stdout = out_adapter.Out.stdout.output(),
        .stderr = out_adapter.Out.stderr.output(),
        .user_id = linux.getuid(),
    };

    var argument_buffer: [args_mod.max_arguments][]const u8 = undefined;
    const argv = args_mod.collect(minimal.args, &argument_buffer);
    return cli.run(cli.parse(argv), host, &store);
}

test "main dispatches the generated name and version" {
    const argv = [_][*:0]const u8{ "prompty", "version" };
    const environment = [_:null]?[*:0]const u8{ "USER=test", "HOME=/home/test", null };
    const minimal = std.process.Init.Minimal{
        .args = .{ .vector = &argv },
        .environ = .{ .block = .{ .slice = &environment } },
    };
    try std.testing.expectEqual(@as(u8, 0), main(minimal));
}

test "main reports a usage error through the exit code" {
    const argv = [_][*:0]const u8{ "prompty", "nonsense" };
    const environment = [_:null]?[*:0]const u8{ null };
    const minimal = std.process.Init.Minimal{
        .args = .{ .vector = &argv },
        .environ = .{ .block = .{ .slice = &environment } },
    };
    try std.testing.expectEqual(cli.exit_usage, main(minimal));
}

test "entry survives an empty environment and no arguments" {
    const argv = [_][*:0]const u8{"prompty"};
    const environment = [_:null]?[*:0]const u8{null};
    const minimal = std.process.Init.Minimal{
        .args = .{ .vector = &argv },
        .environ = .{ .block = .{ .slice = &environment } },
    };
    // No command means help, which must not depend on HOME or PWD.
    try std.testing.expectEqual(@as(u8, 0), entry(minimal));
}
