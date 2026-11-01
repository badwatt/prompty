//! Test root. Every module is imported here so the test binary exercises the
//! whole tree rather than just what `main` happens to reach.

test {
    _ = @import("main.zig");

    _ = @import("application/args.zig");
    _ = @import("application/cli.zig");
    _ = @import("application/compose.zig");
    _ = @import("application/metadata.zig");
    _ = @import("application/shell_init.zig");

    _ = @import("domain/cache.zig");
    _ = @import("domain/canvas.zig");
    _ = @import("domain/clock.zig");
    _ = @import("domain/duration.zig");
    _ = @import("domain/git.zig");
    _ = @import("domain/git_status.zig");
    _ = @import("domain/osc.zig");
    _ = @import("domain/path.zig");
    _ = @import("domain/prompt.zig");
    _ = @import("domain/rgb.zig");
    _ = @import("domain/store.zig");
    _ = @import("domain/theme.zig");
    _ = @import("domain/width.zig");

    _ = @import("ports/host.zig");

    _ = @import("adapters/linux/clock.zig");
    _ = @import("adapters/linux/command.zig");
    _ = @import("adapters/linux/env.zig");
    _ = @import("adapters/linux/fs.zig");
    _ = @import("adapters/linux/out.zig");
    _ = @import("adapters/linux/syscall.zig");
    _ = @import("adapters/linux/tty.zig");
    _ = @import("adapters/tzif.zig");

    _ = @import("test_support/fakes.zig");
}
