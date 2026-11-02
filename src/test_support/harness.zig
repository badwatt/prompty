//! The fake host a use-case test drives: a small tree with a repository in it,
//! an environment, a clock and a terminal, all answering from memory.
//!
//! It lives here rather than in the module under test so that the shipping file
//! contains the use case and nothing else, and so that the two callers that need
//! it share one definition instead of two that drift.

const std = @import("std");

const prompt = @import("../domain/prompt.zig");
const store_mod = @import("../domain/store.zig");
const compose = @import("../application/compose.zig");
const cli = @import("../application/cli.zig");
const fakes = @import("fakes.zig");

pub const project_directories = [_][]const u8{"/home/dev/proj"};

pub const project_sources = [_]fakes.FakeFiles.File{
    .{ .path = "/home/dev/proj/.git/HEAD", .contents = "ref: refs/heads/main\n" },
};

pub const default_environment = [_][2][]const u8{
    .{ "USER", "dev" },
    .{ "HOME", "/home/dev" },
    .{ "PWD", "/home/dev/proj" },
};

pub const base_environment = [_][2][]const u8{
    .{ "USER", "dev" },
    .{ "HOME", "/home/dev" },
    .{ "PWD", "/home/dev" },
};

/// A porcelain report with one of everything, as git would print it.
pub const status_porcelain =
    "# branch.oid 1cec0eae51f1f82b5bb5290d9309f73728b04aba\x00" ++
    "# branch.head main\x00" ++
    "# branch.upstream origin/main\x00" ++
    "# branch.ab +2 -1\x00" ++
    "1 .M N... 100644 100644 100644 aaaaaaa aaaaaaa src/modified.zig\x00" ++
    "1 M. N... 100644 100644 100644 aaaaaaa aaaaaaa src/staged.zig\x00" ++
    "1 .D N... 100644 100644 000000 aaaaaaa aaaaaaa src/deleted.zig\x00" ++
    "? src/untracked.zig\x00";

pub const Harness = struct {
    files: fakes.FakeFiles,
    environment: fakes.FakeEnv,
    clock: fakes.FakeClock = .{},
    terminal: fakes.FakeTerminal = .{},
    host: fakes.FakeHost,
    store: store_mod.Store = undefined,

    /// A harness in the fake project, with a repository at `/home/dev/proj`.
    pub fn init(environment: []const [2][]const u8) Harness {
        return onTree(&project_sources, environment, &project_directories);
    }

    /// A harness on any tree, for the tests that need a different one.
    pub fn initWith(sources: []const fakes.FakeFiles.File, environment: []const [2][]const u8) Harness {
        return onTree(sources, environment, &.{});
    }

    fn onTree(
        sources: []const fakes.FakeFiles.File,
        environment: []const [2][]const u8,
        directories: []const []const u8,
    ) Harness {
        var harness = Harness{
            .files = fakes.FakeFiles.withDirectories(sources, directories),
            .environment = fakes.FakeEnv.init(environment),
            .host = undefined,
        };
        harness.host = .{
            .files = harness.files,
            .environment = harness.environment,
            .clock = harness.clock,
            .terminal = harness.terminal,
        };
        harness.store.reset();
        return harness;
    }

    pub fn model(self: *Harness, options: compose.Options) prompt.Model {
        return compose.build(self.host.host(), &self.store, options);
    }

    pub fn dispatch(self: *Harness, argv: []const []const u8) u8 {
        return cli.run(cli.parse(argv), self.host.host(), &self.store);
    }
};
