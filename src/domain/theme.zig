//! Derives the whole prompt palette from a single value: the terminal
//! background. This is what lets prompty look native in any theme without a
//! config file, while keeping the derivation pure (and therefore testable).
//!
//! The surfaces are mixed in Oklab lightness rather than in sRGB so that the
//! segments stay perceptually even: naive sRGB blending of very dark colours
//! produces muddy, indistinguishable greys.

const std = @import("std");
const rgb = @import("rgb.zig");

pub const Rgb = rgb.Rgb;

pub const Theme = struct {
    background: Rgb,
    user_surface: Rgb,
    path_surface: Rgb,
    git_surface: Rgb,
    text: Rgb,
    muted: Rgb,
    green: Rgb,
    red: Rgb,
    yellow: Rgb,

    /// Catppuccin Mocha base00. The default because it is the theme prompty
    /// was tuned against; any terminal background can override it.
    pub const default_background = Rgb{ .r = 0x1e, .g = 0x1e, .b = 0x2e };

    pub fn derive(background: Rgb) Theme {
        const base = Lab.fromRgb(background);
        const dark = base.isDark();
        const tint = if (dark)
            Lab.fromRgb(.{ .r = 198, .g = 208, .b = 245 })
        else
            Lab.fromRgb(.{ .r = 65, .g = 69, .b = 89 });
        const opacity: f32 = if (dark) 0.21 else 0.15;
        const safe = base.withSafeLuminance();

        const text = if (dark)
            Rgb{ .r = 0xcd, .g = 0xd6, .b = 0xf4 }
        else
            Rgb{ .r = 0x4c, .g = 0x4f, .b = 0x69 };

        return .{
            .background = background,
            .user_surface = safe.mixToward(tint, opacity).toRgb(),
            .path_surface = safe.mixToward(tint, opacity * 0.62).toRgb(),
            .git_surface = safe.mixToward(tint, opacity * 0.34).toRgb(),
            .text = text,
            .muted = text.blend(background, 0.45),
            .green = if (dark)
                Rgb{ .r = 0xa6, .g = 0xe3, .b = 0xa1 }
            else
                Rgb{ .r = 0x40, .g = 0xa0, .b = 0x2b },
            .red = if (dark)
                Rgb{ .r = 0xf3, .g = 0x8b, .b = 0xa8 }
            else
                Rgb{ .r = 0xd2, .g = 0x0f, .b = 0x39 },
            .yellow = if (dark)
                Rgb{ .r = 0xf9, .g = 0xe2, .b = 0xaf }
            else
                Rgb{ .r = 0xdf, .g = 0x8e, .b = 0x1d },
        };
    }
};

const Lab = struct {
    l: f32,
    a: f32,
    b: f32,

    fn fromRgb(color: Rgb) Lab {
        const r = linearize(color.r);
        const g = linearize(color.g);
        const b = linearize(color.b);

        const cone_l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b;
        const cone_m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b;
        const cone_s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b;

        const l_root = root3(@max(cone_l, 0.0));
        const m_root = root3(@max(cone_m, 0.0));
        const s_root = root3(@max(cone_s, 0.0));

        return .{
            .l = 0.2104542553 * l_root + 0.7936177850 * m_root - 0.0040720468 * s_root,
            .a = 1.9779984951 * l_root - 2.4285922050 * m_root + 0.4505937099 * s_root,
            .b = 0.0259040371 * l_root + 0.7827717662 * m_root - 0.8086757660 * s_root,
        };
    }

    fn toRgb(self: Lab) Rgb {
        const l_root = self.l + 0.3963377774 * self.a + 0.2158037573 * self.b;
        const m_root = self.l - 0.1055613458 * self.a - 0.0638541728 * self.b;
        const s_root = self.l - 0.0894841775 * self.a - 1.2914855480 * self.b;

        const cone_l = l_root * l_root * l_root;
        const cone_m = m_root * m_root * m_root;
        const cone_s = s_root * s_root * s_root;

        const r = 4.0767416621 * cone_l - 3.3077115913 * cone_m + 0.2309699292 * cone_s;
        const g = -1.2684380046 * cone_l + 2.6097574011 * cone_m - 0.3413193965 * cone_s;
        const b = -0.0041960863 * cone_l - 0.7034186147 * cone_m + 1.7076147010 * cone_s;

        return .{
            .r = delinearize(r),
            .g = delinearize(g),
            .b = delinearize(b),
        };
    }

    fn isDark(self: Lab) bool {
        return self.l < 0.5;
    }

    /// Very dark backgrounds have nothing to mix with: everything collapses to
    /// black. Lift the lightness floor so the segments stay visible.
    fn withSafeLuminance(self: Lab) Lab {
        return .{ .l = @max(self.l, 0.15), .a = self.a, .b = self.b };
    }

    fn mixToward(self: Lab, other: Lab, amount: f32) Lab {
        std.debug.assert(amount >= 0.0);
        std.debug.assert(amount <= 1.0);
        return .{
            .l = self.l + (other.l - self.l) * amount,
            .a = self.a + (other.a - self.a) * amount,
            .b = self.b + (other.b - self.b) * amount,
        };
    }
};

fn root3(value: f32) f32 {
    std.debug.assert(value >= 0.0);
    return std.math.pow(f32, value, 1.0 / 3.0);
}

fn linearize(channel: u8) f32 {
    const value = @as(f32, @floatFromInt(channel)) / 255.0;
    if (value <= 0.04045) return value / 12.92;
    return std.math.pow(f32, (value + 0.055) / 1.055, 2.4);
}

fn delinearize(value: f32) u8 {
    const clamped = std.math.clamp(value, 0.0, 1.0);
    const encoded = if (clamped <= 0.0031308)
        clamped * 12.92
    else
        1.055 * std.math.pow(f32, clamped, 1.0 / 2.4) - 0.055;
    return @intFromFloat(std.math.clamp(encoded * 255.0, 0.0, 255.0));
}

fn expectClose(expected: u8, actual: u8, tolerance: u8) !void {
    const difference = if (expected > actual) expected - actual else actual - expected;
    try std.testing.expect(difference <= tolerance);
}

test "derive keeps a dark theme readable" {
    const theme = Theme.derive(Theme.default_background);

    // Text must be light on a dark background, and dimmed text must sit
    // between the text colour and the background.
    try std.testing.expect(theme.text.r > 0xb0);
    try std.testing.expect(theme.muted.r > theme.background.r);
    try std.testing.expect(theme.muted.r < theme.text.r);

    // Surfaces fade towards the background from left to right.
    try std.testing.expect(theme.user_surface.r > theme.background.r);
    try std.testing.expect(theme.user_surface.r > theme.path_surface.r);
    try std.testing.expect(theme.path_surface.r > theme.git_surface.r);
    try std.testing.expect(theme.git_surface.r > theme.background.r);
}

test "derive picks dark text on a light terminal" {
    const theme = Theme.derive(.{ .r = 0xf5, .g = 0xf5, .b = 0xf5 });
    try std.testing.expect(theme.text.r < 0x80);
    try std.testing.expect(theme.user_surface.r < 0xf5);
    try std.testing.expect(theme.red.r > 0x80);
}

test "derive lifts pure black backgrounds above the void" {
    const theme = Theme.derive(.{ .r = 0, .g = 0, .b = 0 });
    try std.testing.expect(theme.user_surface.r > 16);
    try std.testing.expect(theme.path_surface.r > 8);
}

test "derive is deterministic and keeps the background untouched" {
    const background = Rgb{ .r = 0x1e, .g = 0x1e, .b = 0x2e };
    const first = Theme.derive(background);
    const second = Theme.derive(background);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(background, first.background);
}

test "derive matches the tuned Catppuccin Mocha surfaces" {
    const theme = Theme.derive(Theme.default_background);
    try expectClose(0x3c, theme.user_surface.r, 1);
    try expectClose(0x3e, theme.user_surface.g, 1);
    try expectClose(0x52, theme.user_surface.b, 1);
    try expectClose(0x30, theme.path_surface.r, 1);
    try expectClose(0x31, theme.path_surface.g, 1);
    try expectClose(0x44, theme.path_surface.b, 1);
    try expectClose(0x28, theme.git_surface.r, 1);
    try expectClose(0x28, theme.git_surface.g, 1);
    try expectClose(0x3a, theme.git_surface.b, 1);
}
