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
const git_status_mod = @import("git_status.zig");
const language_mod = @import("language.zig");
const theme_mod = @import("theme.zig");

const Canvas = canvas_mod.Canvas;
const Rgb = theme_mod.Rgb;
const Shell = canvas_mod.Shell;

pub const Git = struct {
    branch: []const u8,
    operation: git_mod.Operation,
    detached: bool,
    status: git_status_mod.Status = .{},
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

const bold_on = "\x1b[1m";
const bold_off = "\x1b[22m";

/// The branch glyph from the terminal setup prompty was built for.
const branch_glyph = "\u{f113}";

// Symbol for each status category, one glyph each and no counts.
const conflicted_glyph = "=";
const stashed_glyph = "$";
const deleted_glyph = "\u{2718}";
const renamed_glyph = "\u{00bb}";
const modified_glyph = "!";
const staged_glyph = "+";
const untracked_glyph = "?";
const diverged_glyph = "\u{21d5}";
const ahead_glyph = "\u{21e1}";
const behind_glyph = "\u{21e3}";

const direnv_glyph = "\u{f0d6e}";
const clock_glyph = "\u{f051a}";
const failure_glyph = "\u{2718}";

pub fn render(model: *const Model, buffer: []u8) []const u8 {
    var canvas = Canvas.init(buffer, model.shell, model.color);
    canvas.text("\n");

    // The pill is a chain of surfaces. A separator is inked with the colour of
    // the surface it leaves and filled with the colour of the one it enters;
    // that is what makes the glyph read as an arrow. Painting it with the text
    // colour instead leaves a bright wedge, and painting it with the same
    // colour on both sides leaves nothing at all.
    var surface: Rgb = model.theme.path_surface;
    if (model.user) |user| {
        surface = if (model.is_root) model.theme.red else model.theme.user_surface;
        paint(&canvas, surface, null);
        canvas.text(powerline.cap_left);
        paint(&canvas, model.theme.text, surface);
        // The name is the one place the prompt raises its voice. Boldness is
        // turned off with SGR 22 rather than a full reset, so the segment
        // colours survive for the separator that follows.
        canvas.escape(bold_on);
        canvas.text(" ");
        canvas.text(user);
        canvas.text(" ");
        canvas.escape(bold_off);
        transition(&canvas, surface, model.theme.path_surface);
        surface = model.theme.path_surface;
    } else {
        paint(&canvas, surface, null);
        canvas.text(powerline.cap_left);
    }

    paint(&canvas, model.theme.text, surface);
    canvas.text(" ");
    canvas.text(model.path);
    canvas.text(" ");

    if (model.git) |repo| {
        transition(&canvas, surface, model.theme.git_surface);
        surface = model.theme.git_surface;
        paint(&canvas, model.theme.text, surface);
        canvas.text(" ");
        canvas.text(branch_glyph);
        canvas.text(" ");
        canvas.text(repo.branch);
        if (repo.operation != .none) {
            paint(&canvas, model.theme.yellow, surface);
            canvas.text(" ");
            canvas.text(repo.operation.label());
            paint(&canvas, model.theme.text, surface);
        }
        if (!repo.status.isClean()) {
            canvas.text(" ");
            writeStatus(&canvas, repo.status);
        }
        canvas.text(" ");
    }

    closePill(&canvas, surface);

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
    canvas.escape(bold_on);
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
/// The status symbols: conflicts first, then the worktree state, then how far
/// the branch has drifted from its upstream.
fn writeStatus(canvas: *Canvas, status: git_status_mod.Status) void {
    if (status.conflicted > 0) canvas.text(conflicted_glyph);
    if (status.stashed > 0) canvas.text(stashed_glyph);
    if (status.deleted > 0) canvas.text(deleted_glyph);
    if (status.renamed > 0) canvas.text(renamed_glyph);
    if (status.modified > 0) canvas.text(modified_glyph);
    if (status.staged > 0) canvas.text(staged_glyph);
    if (status.untracked > 0) canvas.text(untracked_glyph);
    // Divergence is one symbol, never two.
    if (status.isDiverged()) {
        canvas.text(diverged_glyph);
    } else if (status.ahead > 0) {
        canvas.text(ahead_glyph);
    } else if (status.behind > 0) {
        canvas.text(behind_glyph);
    }
}

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

/// Paints the separator that ends one segment and begins the next.
fn transition(canvas: *Canvas, from: Rgb, to: Rgb) void {
    paint(canvas, from, to);
    canvas.text(powerline.separator);
}

/// Ends the pill. The ink is the last surface and the fill is the terminal's
/// own background, which first has to be cleared: a segment's background would
/// otherwise still be in effect and the arrow would vanish into it.
fn closePill(canvas: *Canvas, from: Rgb) void {
    reset(canvas);
    paint(canvas, from, null);
    canvas.text(powerline.separator);
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
            "\u{e0b6} badwatt \u{e0b0} ~/src/prompty \u{e0b0} \u{f113} main \u{e0b0}" ++
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

/// A separator is only an arrow when the ink is the surface being left and the
/// fill is the surface being entered.
fn expectSeparator(rendered: []const u8, ink: Rgb, fill: Rgb) !void {
    var buffer: [64]u8 = undefined;
    const sequence = std.fmt.bufPrint(&buffer, "\x1b[38;2;{d};{d};{d}m\x1b[48;2;{d};{d};{d}m{s}", .{
        ink.r,               ink.g,  ink.b,
        fill.r,              fill.g, fill.b,
        powerline.separator,
    }) catch unreachable;
    try std.testing.expect(std.mem.indexOf(u8, rendered, sequence) != null);
}

test "every separator leaves one surface and enters the next" {
    const theme = fixtureTheme();
    const model = Model{
        .theme = theme,
        .user = "dev",
        .path = "~/p",
        .git = .{ .branch = "main", .operation = .none, .detached = false },
    };
    const rendered = renderToString(&model);

    try expectSeparator(rendered, theme.user_surface, theme.path_surface);
    try expectSeparator(rendered, theme.path_surface, theme.git_surface);

    // The pill closes onto the terminal background, so the fill is cleared
    // first and only the ink is painted.
    var closing_buffer: [48]u8 = undefined;
    const closing = std.fmt.bufPrint(&closing_buffer, "\x1b[0m\x1b[38;2;{d};{d};{d}m{s}", .{
        theme.git_surface.r,
        theme.git_surface.g,
        theme.git_surface.b,
        powerline.separator,
    }) catch unreachable;
    try std.testing.expect(std.mem.indexOf(u8, rendered, closing) != null);

    // Three separators for three segments, never one more.
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, rendered, powerline.separator));

    // And the text colour is never used as a separator's ink: that is the bug
    // that made the arrow look like a white wedge.
    var wrong_buffer: [32]u8 = undefined;
    const wedge = std.fmt.bufPrint(&wrong_buffer, "\x1b[38;2;{d};{d};{d}m{s}", .{
        theme.text.r,
        theme.text.g,
        theme.text.b,
        powerline.separator,
    }) catch unreachable;
    try std.testing.expect(std.mem.indexOf(u8, rendered, wedge) == null);
}

test "the user name is bold and the boldness ends before the separator" {
    const theme = fixtureTheme();
    const model = Model{
        .theme = theme,
        .user = "dev",
        .path = "~/p",
        .git = .{ .branch = "main", .operation = .none, .detached = false },
    };
    const rendered = renderToString(&model);

    try std.testing.expect(std.mem.indexOf(u8, rendered, bold_on ++ " dev ") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, " " ++ bold_off) != null);

    // Reset before the chevron, so the rest of the prompt keeps normal weight.
    const bold_off_position = std.mem.indexOf(u8, rendered, bold_off).?;
    const first_separator = std.mem.indexOf(u8, rendered, powerline.separator).?;
    try std.testing.expect(bold_off_position < first_separator);

    // Nothing else is bold except the chevron.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, rendered, bold_on));
}

test "without a user segment the cap starts the path segment" {
    const theme = fixtureTheme();
    const model = Model{ .theme = theme, .path = "~/p" };
    const rendered = renderToString(&model);

    var cap_buffer: [48]u8 = undefined;
    const cap = std.fmt.bufPrint(&cap_buffer, "\x1b[38;2;{d};{d};{d}m{s}", .{
        theme.path_surface.r,
        theme.path_surface.g,
        theme.path_surface.b,
        powerline.cap_left,
    }) catch unreachable;
    try std.testing.expect(std.mem.startsWith(u8, rendered[1..], cap));
    try std.testing.expectEqual(@as(u8, '\n'), rendered[0]);

    // One surface means one separator, the one that closes the pill.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, powerline.separator));
}

test "detached heads and in-progress operations are visible" {
    const model = Model{
        .theme = fixtureTheme(),
        .color = false,
        .path = "~/repo",
        .git = .{ .branch = "a1b2c3d", .operation = .rebase, .detached = true },
    };
    try std.testing.expectEqualStrings(
        "\n\u{e0b6} ~/repo \u{e0b0} \u{f113} a1b2c3d rebase \u{e0b0} \u{276f} ",
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

test "the branch carries its glyph and the status carries its symbols" {
    const dirty = Model{
        .theme = fixtureTheme(),
        .color = false,
        .path = "~/repo",
        .git = .{
            .branch = "main",
            .operation = .none,
            .detached = false,
            .status = .{
                .deleted = 1,
                .modified = 1,
                .staged = 1,
                .untracked = 1,
            },
        },
    };
    // One glyph per category, densely packed after the branch.
    try std.testing.expectEqualStrings(
        "\n\u{e0b6} ~/repo \u{e0b0} \u{f113} main \u{2718}!+? \u{e0b0} \u{276f} ",
        renderToString(&dirty),
    );

    const upstream = Model{
        .theme = fixtureTheme(),
        .color = false,
        .path = "~/repo",
        .git = .{ .branch = "main", .operation = .none, .detached = false, .status = .{ .ahead = 1 } },
    };
    try std.testing.expect(std.mem.indexOf(u8, renderToString(&upstream), " \u{21e1} ") != null);

    const behind = Model{
        .theme = fixtureTheme(),
        .color = false,
        .path = "~/repo",
        .git = .{ .branch = "main", .operation = .none, .detached = false, .status = .{ .behind = 2 } },
    };
    try std.testing.expect(std.mem.indexOf(u8, renderToString(&behind), " \u{21e3} ") != null);

    // Diverged is a single symbol, never both arrows.
    const diverged = Model{
        .theme = fixtureTheme(),
        .color = false,
        .path = "~/repo",
        .git = .{
            .branch = "main",
            .operation = .none,
            .detached = false,
            .status = .{ .ahead = 1, .behind = 1 },
        },
    };
    const rendered = renderToString(&diverged);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\u{21d5}") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\u{21e1}") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\u{21e3}") == null);
}

test "a status of conflicts and stashes leads the row" {
    const model = Model{
        .theme = fixtureTheme(),
        .color = false,
        .path = "~/repo",
        .git = .{
            .branch = "main",
            .operation = .none,
            .detached = false,
            .status = .{ .conflicted = 1, .stashed = 1, .renamed = 1 },
        },
    };
    try std.testing.expectEqualStrings(
        "\n\u{e0b6} ~/repo \u{e0b0} \u{f113} main =$\u{00bb} \u{e0b0} \u{276f} ",
        renderToString(&model),
    );
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
