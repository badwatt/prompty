//! Command line parsing and dispatch. Pure parsing, so every flag combination is
//! unit tested; `run` is the only part that touches the host.

const std = @import("std");

const canvas = @import("../domain/canvas.zig");
const prompt = @import("../domain/prompt.zig");
const store_mod = @import("../domain/store.zig");
const theme_mod = @import("../domain/theme.zig");
const ports = @import("../ports/host.zig");
const compose = @import("compose.zig");
const metadata = @import("metadata.zig");
const shell_init = @import("shell_init.zig");

pub const RenderOptions = struct {
    shell: canvas.Shell = .plain,
    color: bool = true,
    /// Ask git for the working tree status. On by default: `--git=false` turns
    /// it off, and the branch still comes from `.git/HEAD`.
    git: bool = true,
    duration: bool = false,
};

pub const ThemeOptions = struct {
    detect: bool = false,
    force: bool = false,
};

pub const InitOptions = struct {
    shell: canvas.Shell,
    duration: bool = false,
};

pub const Action = union(enum) {
    render: RenderOptions,
    init: InitOptions,
    version,
    theme: ThemeOptions,
    help,
    invalid: []const u8,
};

pub const exit_ok = 0;
pub const exit_usage = 2;

/// `argv[0]` is the program name, as usual.
pub fn parse(argv: []const []const u8) Action {
    if (argv.len < 2) return .help;
    const command = argv[1];
    const rest = argv[2..];

    if (std.mem.eql(u8, command, "render")) return parseRender(rest);
    if (std.mem.eql(u8, command, "init")) return parseInit(rest);
    if (std.mem.eql(u8, command, "version")) return .version;
    if (std.mem.eql(u8, command, "theme")) return parseTheme(rest);
    if (std.mem.eql(u8, command, "help")) return .help;
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) return .help;
    if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-V")) return .version;
    return .{ .invalid = command };
}

/// What a boolean flag said.
const Boolean = enum {
    /// Not this flag: keep looking.
    no,
    on,
    off,
    /// This flag, with something other than true or false after it.
    invalid,
};

/// A boolean flag, in every spelling it has: `-d`, `--duration`, `-d=false`,
/// `--duration=false`, and the same with `true`.
///
/// A flag on its own means true, which is what a bare `-d` should obviously
/// mean; the `=false` form exists because a flag that defaults to true (`--git`)
/// needs a way to be turned off without a second, negative name.
fn boolean(flag: []const u8, short: u8, long: []const u8) Boolean {
    var name = flag;
    var explicit: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, flag, '=')) |equals| {
        name = flag[0..equals];
        explicit = flag[equals + 1 ..];
    }

    const is_short = name.len == 2 and name[0] == '-' and name[1] == short;
    if (!is_short and !std.mem.eql(u8, name, long)) return .no;

    const value = explicit orelse return .on;
    if (std.mem.eql(u8, value, "true")) return .on;
    if (std.mem.eql(u8, value, "false")) return .off;
    return .invalid;
}

/// Applies a boolean flag to `field`. True when the flag was this one.
fn applyBoolean(field: *bool, flag: []const u8, short: u8, long: []const u8) ?bool {
    const matched = boolean(flag, short, long);
    if (matched == .no) return null;
    if (matched == .invalid) return false;
    field.* = matched == .on;
    return true;
}

fn parseRender(flags: []const []const u8) Action {
    var options = RenderOptions{};
    for (flags) |flag| {
        if (std.mem.eql(u8, flag, "--no-color")) {
            options.color = false;
            continue;
        }
        if (applyBoolean(&options.git, flag, 'g', "--git")) |matched| {
            if (!matched) return .{ .invalid = flag };
            continue;
        }
        if (applyBoolean(&options.duration, flag, 'd', "--duration")) |matched| {
            if (!matched) return .{ .invalid = flag };
            continue;
        }
        if (applyBoolean(&options.color, flag, 'c', "--color")) |matched| {
            if (!matched) return .{ .invalid = flag };
            continue;
        }
        const prefix = "--shell=";
        if (std.mem.startsWith(u8, flag, prefix)) {
            options.shell = canvas.Shell.parse(flag[prefix.len..]) orelse
                return .{ .invalid = flag };
            continue;
        }
        return .{ .invalid = flag };
    }
    return .{ .render = options };
}

fn parseTheme(arguments: []const []const u8) Action {
    if (arguments.len == 0) return .{ .theme = .{} };
    if (!std.mem.eql(u8, arguments[0], "detect")) return .{ .invalid = arguments[0] };
    var options = ThemeOptions{ .detect = true };
    for (arguments[1..]) |flag| {
        if (std.mem.eql(u8, flag, "--force")) {
            options.force = true;
            continue;
        }
        return .{ .invalid = flag };
    }
    return .{ .theme = options };
}

fn parseInit(arguments: []const []const u8) Action {
    if (arguments.len == 0) return .{ .invalid = "init" };
    const shell = canvas.Shell.parse(arguments[0]) orelse return .{ .invalid = arguments[0] };
    if (shell == .plain) return .{ .invalid = arguments[0] };
    var options = InitOptions{ .shell = shell };
    for (arguments[1..]) |flag| {
        if (applyBoolean(&options.duration, flag, 'd', "--duration")) |matched| {
            if (!matched) return .{ .invalid = flag };
            continue;
        }
        return .{ .invalid = flag };
    }
    return .{ .init = options };
}

pub fn run(action: Action, host: ports.Host, store: *store_mod.Store) u8 {
    switch (action) {
        .render => |options| {
            var buffer: [canvas.Canvas.capacity]u8 = undefined;
            const model = compose.build(host, store, .{
                .shell = options.shell,
                .color = options.color,
                .git = options.git,
                .duration = options.duration,
            });
            host.stdout.write(prompt.render(&model, &buffer));
            return exit_ok;
        },
        .init => |init| {
            host.stdout.write(shell_init.script(init.shell, init.duration));
            return exit_ok;
        },
        .version => {
            var buffer: [64]u8 = undefined;
            const line = std.fmt.bufPrint(&buffer, "{s} {s}\n", .{ metadata.name, metadata.version }) catch
                return exit_ok;
            host.stdout.write(line);
            return exit_ok;
        },
        .theme => |options| {
            if (options.detect) return detectTheme(host, options.force);
            writeTheme(host);
            return exit_ok;
        },
        .help => {
            host.stdout.write(usage);
            return exit_ok;
        },
        .invalid => |offender| {
            var buffer: [256]u8 = undefined;
            const message = std.fmt.bufPrint(&buffer, "{s}: unknown argument '{s}'\n", .{
                metadata.name,
                offender,
            }) catch usage;
            host.stderr.write(message);
            host.stderr.write(usage);
            return exit_usage;
        },
    }
}

const usage =
    "usage: " ++ metadata.name ++ " <command>\n" ++
    "\n" ++
    "  render [--shell=zsh|bash|plain] [--no-color]   print the prompt\n" ++
    "         [-g|--git] [-d|--duration]               git status / the time\n" ++
    "  init zsh|bash [-d|--duration]                  print the shell integration\n" ++
    "  theme [detect [--force]]                       print (or redetect) the palette\n" ++
    "  version                                        print name and version\n" ++
    "\n" ++
    "A boolean flag on its own means true: --git=false turns one off.\n" ++
    "\n" ++
    "Set PROMTY_BACKGROUND=#rrggbb to match your terminal background,\n" ++
    "and NO_COLOR=1 to disable colours entirely.\n";

/// Detects the terminal background once and remembers it, so that every later
/// prompt is a single file read away from a theme that matches the terminal.
fn detectTheme(host: ports.Host, force: bool) u8 {
    if (!force and compose.cachedBackground(host) != null) {
        writeTheme(host);
        return exit_ok;
    }
    const detected = compose.detectBackground(host) orelse {
        host.stderr.write(
            "prompty: the terminal did not report a background colour; " ++
                "set PROMTY_BACKGROUND=#rrggbb instead\n",
        );
        writeTheme(host);
        return exit_ok;
    };
    _ = compose.rememberBackground(host, detected);
    writeTheme(host);
    return exit_ok;
}

fn writeTheme(host: ports.Host) void {
    const theme = compose.themeFor(host);
    const entries = [_]struct { label: []const u8, color: theme_mod.Rgb }{
        .{ .label = "background", .color = theme.background },
        .{ .label = "user", .color = theme.user_surface },
        .{ .label = "path", .color = theme.path_surface },
        .{ .label = "git", .color = theme.git_surface },
        .{ .label = "text", .color = theme.text },
        .{ .label = "muted", .color = theme.muted },
        .{ .label = "green", .color = theme.green },
        .{ .label = "red", .color = theme.red },
        .{ .label = "yellow", .color = theme.yellow },
    };
    for (entries) |entry| {
        var hex_buffer: [7]u8 = undefined;
        var line_buffer: [32]u8 = undefined;
        const hex = std.fmt.bufPrint(&hex_buffer, "#{x:0>2}{x:0>2}{x:0>2}", .{
            entry.color.r,
            entry.color.g,
            entry.color.b,
        }) catch return;
        const line = std.fmt.bufPrint(&line_buffer, "{s:<10} {s}\n", .{ entry.label, hex }) catch return;
        host.stdout.write(line);
    }
}

fn expectParse(expected: Action, argv: []const []const u8) !void {
    try std.testing.expectEqualDeep(expected, parse(argv));
}

test "no arguments prints help" {
    try expectParse(.help, &.{});
    try expectParse(.help, &.{"prompty"});
    try expectParse(.help, &.{ "prompty", "help" });
    try expectParse(.help, &.{ "prompty", "--help" });
    try expectParse(.help, &.{ "prompty", "-h" });
}

test "render takes an optional shell and colour switch" {
    try expectParse(.{ .render = .{} }, &.{ "prompty", "render" });
    try expectParse(
        .{ .render = .{ .shell = .zsh, .color = false } },
        &.{ "prompty", "render", "--shell=zsh", "--no-color" },
    );
    try expectParse(
        .{ .render = .{ .shell = .bash } },
        &.{ "prompty", "render", "--shell=bash" },
    );
    try expectParse(
        .{ .render = .{ .shell = .plain } },
        &.{ "prompty", "render", "--shell=plain" },
    );
    try expectParse(
        .{ .render = .{ .git = false } },
        &.{ "prompty", "render", "--git=false" },
    );
    try expectParse(.{ .render = .{} }, &.{ "prompty", "render", "--git" });
    try expectParse(.{ .render = .{ .git = false } }, &.{ "prompty", "render", "-g=false" });
    // Both at once, one of them with an explicit value.
    try expectParse(
        .{ .render = .{ .git = false, .duration = true } },
        &.{ "prompty", "render", "-g=false", "--duration" },
    );
    // A boolean flag with something else after it is a usage error, not a
    // guess: `--git=maybe` has no meaning.
    try expectParse(.{ .invalid = "--git=maybe" }, &.{ "prompty", "render", "--git=maybe" });
    try expectParse(.{ .invalid = "--duration=0" }, &.{ "prompty", "render", "--duration=0" });
    try expectParse(.{ .invalid = "--no-git-status" }, &.{ "prompty", "render", "--no-git-status" });
    try expectParse(.{ .render = .{ .color = false } }, &.{ "prompty", "render", "--color=false" });
}

test "render rejects unknown flags and shells" {
    try expectParse(.{ .invalid = "--shell=fish" }, &.{ "prompty", "render", "--shell=fish" });
    try expectParse(.{ .invalid = "--wat" }, &.{ "prompty", "render", "--wat" });
    try expectParse(.{ .invalid = "extra" }, &.{ "prompty", "render", "--no-color", "extra" });
}

test "init takes the duration option after the shell" {
    try expectParse(
        .{ .init = .{ .shell = .zsh, .duration = true } },
        &.{ "prompty", "init", "zsh", "--duration" },
    );
    try expectParse(.{ .invalid = "--wat" }, &.{ "prompty", "init", "zsh", "--wat" });
}

test "render takes the duration under both spellings" {
    try expectParse(
        .{ .render = .{ .duration = true } },
        &.{ "prompty", "render", "--duration" },
    );
    try expectParse(
        .{ .render = .{ .duration = true } },
        &.{ "prompty", "render", "-d" },
    );
    try expectParse(
        .{ .init = .{ .shell = .bash, .duration = true } },
        &.{ "prompty", "init", "bash", "-d" },
    );
}

test "init requires exactly one supported shell" {
    try expectParse(.{ .init = .{ .shell = .zsh } }, &.{ "prompty", "init", "zsh" });
    try expectParse(.{ .init = .{ .shell = .bash } }, &.{ "prompty", "init", "bash" });
    try expectParse(.{ .invalid = "init" }, &.{ "prompty", "init" });
    try expectParse(.{ .invalid = "fish" }, &.{ "prompty", "init", "fish" });
    try expectParse(.{ .invalid = "plain" }, &.{ "prompty", "init", "plain" });
    try expectParse(.{ .invalid = "extra" }, &.{ "prompty", "init", "zsh", "extra" });
}

test "version has three spellings" {
    try expectParse(.version, &.{ "prompty", "version" });
    try expectParse(.version, &.{ "prompty", "--version" });
    try expectParse(.version, &.{ "prompty", "-V" });
}

test "theme prints the derived palette" {
    try expectParse(.{ .theme = .{} }, &.{ "prompty", "theme" });
}

test "theme detect takes an optional force" {
    try expectParse(.{ .theme = .{ .detect = true } }, &.{ "prompty", "theme", "detect" });
    try expectParse(
        .{ .theme = .{ .detect = true, .force = true } },
        &.{ "prompty", "theme", "detect", "--force" },
    );
    try expectParse(.{ .invalid = "forget" }, &.{ "prompty", "theme", "forget" });
    try expectParse(.{ .invalid = "--watch" }, &.{ "prompty", "theme", "detect", "--watch" });
}

test "unknown commands are reported verbatim" {
    try expectParse(.{ .invalid = "bench" }, &.{ "prompty", "bench" });
}

// ---------------------------------------------------------------------------
// Dispatch tests: the commands run against a fake host, which is exactly what
// the real process wires together.
// ---------------------------------------------------------------------------

const fakes = @import("../test_support/fakes.zig");

const CliHarness = struct {
    files: fakes.FakeFiles,
    environment: fakes.FakeEnv,
    clock: fakes.FakeClock = .{},
    terminal: fakes.FakeTerminal = .{},
    host: fakes.FakeHost,
    store: store_mod.Store = undefined,

    fn init(sources: []const fakes.FakeFiles.File, environment: []const [2][]const u8) CliHarness {
        var harness = CliHarness{
            .files = fakes.FakeFiles.withDirectories(sources, &.{}),
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

    fn dispatch(self: *CliHarness, argv: []const []const u8) u8 {
        return run(parse(argv), self.host.host(), &self.store);
    }
};

const base_environment = [_][2][]const u8{
    .{ "USER", "dev" },
    .{ "HOME", "/home/dev" },
    .{ "PWD", "/home/dev" },
};

test "version prints the name and version from the manifest" {
    var harness = CliHarness.init(&.{}, &base_environment);
    try std.testing.expectEqual(exit_ok, harness.dispatch(&.{ "prompty", "version" }));

    var expected: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&expected, "{s} {s}\n", .{ metadata.name, metadata.version }) catch unreachable;
    try std.testing.expectEqualStrings(line, harness.host.stdout());
}

test "help is printed for no arguments and for help" {
    var implicit = CliHarness.init(&.{}, &base_environment);
    try std.testing.expectEqual(exit_ok, implicit.dispatch(&.{"prompty"}));
    try std.testing.expect(std.mem.indexOf(u8, implicit.host.stdout(), "usage: " ++ metadata.name) != null);

    var explicit = CliHarness.init(&.{}, &base_environment);
    try std.testing.expectEqual(exit_ok, explicit.dispatch(&.{ "prompty", "help" }));
    try std.testing.expectEqualStrings(implicit.host.stdout(), explicit.host.stdout());
}

test "render writes exactly one prompt and one write" {
    var harness = CliHarness.init(&.{}, &base_environment);
    try std.testing.expectEqual(exit_ok, harness.dispatch(&.{ "prompty", "render", "--no-color" }));

    const rendered = harness.host.stdout();
    try std.testing.expect(std.mem.startsWith(u8, rendered, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\u{276f}") != null);
    // One syscall per prompt: the whole line goes out together.
    try std.testing.expectEqual(@as(usize, 1), harness.host.out.writes);
}

test "init prints the integration for the requested shell" {
    var zsh = CliHarness.init(&.{}, &base_environment);
    try std.testing.expectEqual(exit_ok, zsh.dispatch(&.{ "prompty", "init", "zsh" }));
    try std.testing.expect(std.mem.indexOf(u8, zsh.host.stdout(), "add-zsh-hook precmd") != null);

    var bash = CliHarness.init(&.{}, &base_environment);
    try std.testing.expectEqual(exit_ok, bash.dispatch(&.{ "prompty", "init", "bash" }));
    try std.testing.expect(std.mem.indexOf(u8, bash.host.stdout(), "PROMPT_COMMAND") != null);
}

test "theme prints one line per palette entry" {
    var harness = CliHarness.init(&.{}, &base_environment);
    try std.testing.expectEqual(exit_ok, harness.dispatch(&.{ "prompty", "theme" }));
    const output = harness.host.stdout();
    try std.testing.expect(std.mem.indexOf(u8, output, "background #1e1e2e\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "yellow") != null);
    try std.testing.expectEqual(@as(usize, 9), harness.host.out.writes);
}

test "theme detect is a no-op once the background is known" {
    var harness = CliHarness.init(&.{
        .{ .path = "/home/dev/.cache/prompty/theme", .contents = "#f5f5f5" },
    }, &base_environment);
    try std.testing.expectEqual(exit_ok, harness.dispatch(&.{ "prompty", "theme", "detect" }));
    try std.testing.expect(std.mem.indexOf(u8, harness.host.stdout(), "background #f5f5f5") != null);
    // No terminal was asked, and nothing was written.
    try std.testing.expectEqual(@as(usize, 0), harness.host.files.write_count);
}

test "theme detect stores what the terminal reports" {
    var harness = CliHarness.init(&.{}, &base_environment);
    harness.host.terminal = .{ .response = "\x1b]11;rgb:0000/0000/0000\x1b\\" };

    try std.testing.expectEqual(exit_ok, harness.dispatch(&.{ "prompty", "theme", "detect" }));
    try std.testing.expectEqual(@as(usize, 1), harness.host.files.write_count);
    try std.testing.expectEqualStrings("#000000\n", harness.host.files.written[0].bytes);
    // The fake filesystem records writes but does not materialise them, so the
    // printed palette still reflects the default background.
    try std.testing.expect(std.mem.indexOf(u8, harness.host.stdout(), "background #") != null);
}

test "theme detect --force asks again even when cached" {
    var harness = CliHarness.init(&.{
        .{ .path = "/home/dev/.cache/prompty/theme", .contents = "#f5f5f5" },
    }, &base_environment);
    harness.host.terminal = .{ .response = "\x1b]11;rgb:0000/0000/0000\x1b\\" };

    try std.testing.expectEqual(
        exit_ok,
        harness.dispatch(&.{ "prompty", "theme", "detect", "--force" }),
    );
    try std.testing.expectEqual(@as(usize, 1), harness.host.files.write_count);
}

test "a silent terminal is reported without failing the shell" {
    var harness = CliHarness.init(&.{}, &base_environment);
    try std.testing.expectEqual(exit_ok, harness.dispatch(&.{ "prompty", "theme", "detect" }));
    try std.testing.expect(std.mem.indexOf(u8, harness.host.stderr(), "did not report") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.host.stdout(), "background #1e1e2e") != null);
    try std.testing.expectEqual(@as(usize, 0), harness.host.files.write_count);
}

test "an unknown argument is a usage error on stderr" {
    var harness = CliHarness.init(&.{}, &base_environment);
    try std.testing.expectEqual(exit_usage, harness.dispatch(&.{ "prompty", "wat" }));
    try std.testing.expect(std.mem.indexOf(u8, harness.host.stderr(), "unknown argument 'wat'") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.host.stderr(), "usage: ") != null);
    try std.testing.expectEqualStrings("", harness.host.stdout());
}
