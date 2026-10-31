//! Wall-clock measurement of a real render, including the fork and exec that a
//! shell pays on every command. This is the number prompty exists to keep small.
//!
//! Usage: bench [iterations] [binary] [arguments...]

const std = @import("std");

const default_iterations = 300;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);

    const iterations = if (argv.len > 1)
        try std.fmt.parseInt(u32, argv[1], 10)
    else
        default_iterations;
    const binary = if (argv.len > 2) argv[2] else "zig-out/bin/prompty";
    const default_arguments = [_][]const u8{"render"};
    const arguments: []const []const u8 = if (argv.len > 3) argv[3..] else &default_arguments;

    const samples = try arena.alloc(u64, iterations);
    var command = try arena.alloc([]const u8, arguments.len + 1);
    command[0] = binary;
    @memcpy(command[1..], arguments);

    for (samples) |*sample| {
        const start = std.Io.Clock.real.now(io);
        const result = try std.process.run(init.gpa, io, .{
            .argv = command,
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(64 * 1024),
        });
        const elapsed = std.Io.Clock.Timestamp{
            .raw = start,
            .clock = .real,
        };
        sample.* = @intCast(@max(elapsed.untilNow(io).raw.nanoseconds, 0));
        init.gpa.free(result.stdout);
        init.gpa.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("failed: {s} exited with {any}\n", .{ binary, result.term });
            return error.CommandFailed;
        }
    }

    std.mem.sort(u64, samples, {}, std.sort.asc(u64));

    var total: u128 = 0;
    for (samples) |sample| total += sample;

    const minimum = samples[0];
    const median = samples[samples.len / 2];
    const p95 = samples[(samples.len * 95) / 100];
    const maximum = samples[samples.len - 1];
    const mean = total / samples.len;

    var buffer: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buffer);

    try out.interface.print(
        "{s} {s}  \u{00d7}{d}\n" ++
            "  min    {d:>8.3} ms\n" ++
            "  median {d:>8.3} ms\n" ++
            "  mean   {d:>8.3} ms\n" ++
            "  p95    {d:>8.3} ms\n" ++
            "  max    {d:>8.3} ms\n",
        .{
            binary,
            try std.mem.join(arena, " ", arguments),
            iterations,
            milliseconds(minimum),
            milliseconds(median),
            milliseconds(mean),
            milliseconds(p95),
            milliseconds(maximum),
        },
    );
    try out.interface.flush();
}

fn milliseconds(nanoseconds: anytype) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / 1_000_000.0;
}
