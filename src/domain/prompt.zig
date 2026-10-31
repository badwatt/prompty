//! The prompt itself: a pure function from a view model to bytes.
//!
//! Layout (one line, always):
//!
//!     \ue0b6 user \ue0b0 ~/path \ue0b0 main \ue0b0  zig 0.17.0  12:04 ❯
//!
//! The three pill segments fade towards the terminal background from left to
//! right, then the chevron returns to it. Everything after the pill is dimmed
//! detail: languages, direnv, last exit status, duration and the clock.

const std = @import("std");
const canvas_mod = @import("canvas.zig");
const clock_mod = @import("clock.zig");
const duration_mod = @import("duration.zig");
const git_mod = @import("git.zig");
const language_mod = @import("language.zig");
const theme_mod = @import("theme.zig");

const Canvas = canvas_mod.Canvas;
const Rgb = theme_mod.Rgb;
const Shell = canvas_mod.Shell;

pub const Git = struct {
    branch: []const u8,
    operation: git_mod.Operation,
    detached: bool,
};

pub const Language = struct {
    kind: language_mod.Kind,
    version: ?[]const u8,
};

pub const Model = struct {
    theme: theme_mod.Theme,
    shell: Shell = .plain,
    color: bool = true,
    user: ?[]const u8 = null,
    is_root: bool = false,
    path: []const u8,
    git: ?Git = null,
    languages: [max_languages]Language = undefined,
    language_count: u8 = 0,
    time: ?clock_mod.TimeOfDay = null,
    duration_ms: ?u64 = null,
    exit_code: ?u8 = null,
    direnv: bool = false,

    pub const max_languages = 5;

    pub fn addLanguage(self: *Model, language: Language) void {
        std.debug.assert(self.language_count < max_languages);
        self.languages[self.language_count] = language;
        self.language_count += 1;
    }

    pub fn detectedLanguages(self: *const Model) []const Language {
        return self.languages[0..self.language_count];
    }
};

const powerline = struct {
    const cap_left = "\u{e0b6}";
    const separator = "\u{e0b0}";
    const chevron = "\u{276f}";
};

const direnv_glyph = "\u{f0d6e}";
const clock_glyph = "\u{f051a}";
const failure_glyph = "\u{2718}";

pub fn render(model: *const Model, buffer: []u8) []const u8 {
    var canvas = Canvas.init(buffer, model.shell, model.color);
    canvas.text("\n");

    var next_surface: Rgb = model.theme.path_surface;
    if (model.user) |user| {
        next_surface = if (model.is_root) model.theme.red else model.theme.user_surface;
        paint(&canvas, next_surface, null);
        canvas.text(powerline.cap_left);
        paint(&canvas, model.theme.text, next_surface);
        canvas.text(" ");
        canvas.text(user);
        canvas.text(" ");
        canvas.text(powerline.separator);
        setBackground(&canvas, model.theme.path_surface);
    } else {
        paint(&canvas, model.theme.path_surface, null);
        canvas.text(powerline.cap_left);
    }

    paint(&canvas, model.theme.text, model.theme.path_surface);
    canvas.text(" ");
    canvas.text(model.path);
    canvas.text(" ");

    if (model.git) |repo| {
        canvas.text(powerline.separator);
        canvas.text(" ");
        setBackground(&canvas, model.theme.git_surface);
        paint(&canvas, model.theme.text, model.theme.git_surface);
        canvas.text(repo.branch);
        if (repo.operation != .none) {
            paint(&canvas, model.theme.yellow, model.theme.git_surface);
            canvas.text(" ");
            canvas.text(repo.operation.label());
            paint(&canvas, model.theme.text, model.theme.git_surface);
        }
        canvas.text(" ");
    }

    // Close the pill: the last surface fades back into the terminal background,
    // and the reset drops the background colour for everything that follows.
    paint(&canvas, if (model.git != null) model.theme.git_surface else model.theme.path_surface, null);
    canvas.text(powerline.separator);
    reset(&canvas);

    var extras = Extras{ .canvas = &canvas, .theme = &model.theme };
    for (model.detectedLanguages()) |language| {
        extras.begin(model.theme.text);
        extras.text(language.kind.icon());
        if (language.version) |version| {
            extras.text(" ");
            extras.text(version);
        }
    }
    if (model.direnv) {
        extras.begin(model.theme.green);
        extras.text(direnv_glyph);
    }
    if (model.exit_code) |code| {
        if (code != 0) {
            extras.begin(model.theme.red);
            extras.text(failure_glyph);
            var status: [3]u8 = undefined;
            extras.text(std.fmt.bufPrint(&status, "{d}", .{code}) catch unreachable);
        }
    }
    if (model.duration_ms) |milliseconds| {
        extras.begin(durationColor(&model.theme, milliseconds));
        var human: [duration_mod.max_length]u8 = undefined;
        extras.text(duration_mod.format(&human, milliseconds));
    }
    if (model.time) |now| {
        extras.begin(model.theme.muted);
        extras.text(clock_glyph);
        extras.text(" ");
        var digits: [clock_mod.max_length]u8 = undefined;
        extras.text(clock_mod.format(&digits, now));
    }

    paint(&canvas, model.theme.green, null);
    canvas.escape("\x1b[1m");
    canvas.text(" " ++ powerline.chevron ++ " ");
    reset(&canvas);
    return canvas.bytes();
}

fn durationColor(theme: *const theme_mod.Theme, milliseconds: u64) Rgb {
    if (milliseconds >= 10_000) return theme.red;
    if (milliseconds >= 2_000) return theme.yellow;
    return theme.muted;
}

/// The dim detail after the pill: separated by two spaces, one colour change
/// per item and nothing else.
const Extras = struct {
    canvas: *Canvas,
    theme: *const theme_mod.Theme,
    count: usize = 0,

    fn begin(self: *Extras, color: Rgb) void {
        self.canvas.text(" ");
        if (self.count > 0) self.canvas.text(" ");
        self.count += 1;
        paint(self.canvas, color, null);
    }

    fn text(self: *Extras, content: []const u8) void {
        self.canvas.text(content);
    }
};

fn paint(canvas: *Canvas, foreground: ?Rgb, background: ?Rgb) void {
    if (foreground) |color| {
        canvas.escapeFmt("\x1b[38;2;{d};{d};{d}m", .{ color.r, color.g, color.b });
    }
    if (background) |color| {
        canvas.escapeFmt("\x1b[48;2;{d};{d};{d}m", .{ color.r, color.g, color.b });
    }
}

fn setBackground(canvas: *Canvas, background: Rgb) void {
    canvas.escapeFmt("\x1b[48;2;{d};{d};{d}m", .{ background.r, background.g, background.b });
}

fn reset(canvas: *Canvas) void {
    canvas.escape("\x1b[0m");
}

fn fixtureTheme() theme_mod.Theme {
    return theme_mod.Theme.derive(theme_mod.Theme.default_background);
}

const plain_buffer_size = Canvas.capacity;

fn renderToString(model: *const Model) []const u8 {
    const buffer = struct {
        var bytes: [plain_buffer_size]u8 = undefined;
    };
    return render(model, &buffer.bytes);
}

/// Models are built by the compiler use case, which fills the language array in
/// place; tests describe the same thing and let this fill it in.
fn withLanguages(base: Model, languages: []const Language) Model {
    var model = base;
    for (languages) |language| model.addLanguage(language);
    return model;
}

test "renders the full line without colour" {
    const model = withLanguages(.{
        .theme = fixtureTheme(),
        .color = false,
        .user = "badwatt",
        .path = "~/src/prompty",
        .git = .{ .branch = "main", .operation = .none, .detached = false },
        .time = .{ .hour = 12, .minute = 4 },
        .duration_ms = 1_234,
    }, &.{.{ .kind = .zig, .version = "0.17.0" }});
    try std.testing.expectEqualStrings(
        "\n" ++
            "\u{e0b6} badwatt \u{e0b0} ~/src/prompty \u{e0b0} main \u{e0b0}" ++
            " \u{e6a9} 0.17.0  1.2s  \u{f051a} 12:04 \u{276f} ",
        renderToString(&model),
    );
}

test "omits every optional segment when there is nothing to say" {
    const model = Model{ .theme = fixtureTheme(), .color = false, .path = "/" };
    try std.testing.expectEqualStrings(
        "\n\u{e0b6} / \u{e0b0} \u{276f} ",
        renderToString(&model),
    );
}

test "marks root with the alert colour and keeps the cap" {
    const model = Model{
        .theme = fixtureTheme(),
        .user = "root",
        .is_root = true,
        .path = "/root",
    };
    const theme = fixtureTheme();
    const rendered = renderToString(&model);
    var buffer: [24]u8 = undefined;
    const red_sequence = std.fmt.bufPrint(&buffer, "\x1b[38;2;{d};{d};{d}m", .{ theme.red.r, theme.red.g, theme.red.b }) catch unreachable;
    try std.testing.expect(std.mem.indexOf(u8, rendered, red_sequence) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, " root ") != null);
}

test "detached heads and in-progress operations are visible" {
    const model = Model{
        .theme = fixtureTheme(),
        .color = false,
        .path = "~/repo",
        .git = .{ .branch = "a1b2c3d", .operation = .rebase, .detached = true },
    };
    try std.testing.expectEqualStrings(
        "\n\u{e0b6} ~/repo \u{e0b0} a1b2c3d rebase \u{e0b0} \u{276f} ",
        renderToString(&model),
    );
}

test "failure, direnv and several languages all appear" {
    const model = withLanguages(.{
        .theme = fixtureTheme(),
        .color = false,
        .path = "~/mono",
        .git = .{ .branch = "dev", .operation = .merge, .detached = false },
        .direnv = true,
        .exit_code = 130,
    }, &.{
        .{ .kind = .zig, .version = null },
        .{ .kind = .go, .version = "1.22.3" },
        .{ .kind = .odin, .version = null },
    });
    const rendered = renderToString(&model);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\u{e6a9}  \u{f07d3} 1.22.3  \u{f10d3}") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\u{f0d6e}") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\u{2718}130") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "dev merge") != null);
}

test "a successful exit status is not rendered" {
    const model = Model{ .theme = fixtureTheme(), .color = false, .path = "/", .exit_code = 0 };
    try std.testing.expectEqualStrings(
        "\n\u{e0b6} / \u{e0b0} \u{276f} ",
        renderToString(&model),
    );
}

test "duration colour escalates with slowness" {
    const theme = fixtureTheme();
    try std.testing.expectEqual(theme.muted, durationColor(&theme, 0));
    try std.testing.expectEqual(theme.muted, durationColor(&theme, 1_999));
    try std.testing.expectEqual(theme.yellow, durationColor(&theme, 2_000));
    try std.testing.expectEqual(theme.yellow, durationColor(&theme, 9_999));
    try std.testing.expectEqual(theme.red, durationColor(&theme, 10_000));
}

test "zsh output wraps every escape and quotes percent signs" {
    const model = Model{
        .theme = fixtureTheme(),
        .shell = .zsh,
        .user = "dev",
        .path = "~/50%",
        .git = .{ .branch = "main", .operation = .none, .detached = false },
    };
    const rendered = renderToString(&model);

    // Every ESC must be inside a %{ ... %} pair.
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, rendered, index, "\x1b")) |position| {
        try std.testing.expect(position >= 2);
        try std.testing.expectEqualStrings("%{", rendered[position - 2 .. position]);
        index = position + 1;
    }
    try std.testing.expect(std.mem.indexOf(u8, rendered, "50%%") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b]") == null);
}

test "bash output wraps every escape and quotes backslashes" {
    const model = Model{
        .theme = fixtureTheme(),
        .shell = .bash,
        .path = "~\\tmp",
    };
    const rendered = renderToString(&model);
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, rendered, index, "\x1b")) |position| {
        try std.testing.expect(position >= 2);
        try std.testing.expectEqualStrings("\\[", rendered[position - 2 .. position]);
        index = position + 1;
    }
    try std.testing.expect(std.mem.indexOf(u8, rendered, "~\\\\tmp") != null);
}

test "the buffer bound is never exceeded by a maximal prompt" {
    const long_component: [100]u8 = @splat('a');
    const model = withLanguages(.{
        .theme = fixtureTheme(),
        .user = "averyveryverylongusername",
        .path = "~/" ++ long_component ++ "/" ++ long_component ++ "/" ++ long_component,
        .git = .{ .branch = "feature/" ++ long_component, .operation = .cherry_pick, .detached = false },
        .time = .{ .hour = 23, .minute = 59 },
        .duration_ms = 10_000,
        .exit_code = 255,
        .direnv = true,
    }, &.{
        .{ .kind = .zig, .version = "0.17.0" },
        .{ .kind = .rust, .version = "1.80.0" },
        .{ .kind = .go, .version = "1.22.3" },
        .{ .kind = .node, .version = "20.11.0" },
        .{ .kind = .odin, .version = "dev-2024-01" },
    });
    const rendered = renderToString(&model);
    try std.testing.expect(rendered.len < plain_buffer_size);
}
