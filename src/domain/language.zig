//! Language detection that never spawns a toolchain.
//!
//! Starship runs `go version`, `node --version` and friends on every prompt,
//! which costs tens of milliseconds each. prompty instead recognises a project
//! by its manifest and reads the version from the file the project already
//! carries (`.zigversion`, `.nvmrc`, `go.mod`, `rust-toolchain.toml`). When the
//! project does not pin a version, only the icon is shown.

const std = @import("std");

pub const Kind = enum {
    zig,
    rust,
    go,
    node,
    odin,

    /// Nerd Font glyphs, matching the terminal setup prompty was built for.
    pub fn icon(self: Kind) []const u8 {
        return switch (self) {
            .zig => "\u{e6a9}",
            .rust => "\u{e68b}",
            .go => "\u{f07d3}",
            .node => "\u{f0399}",
            .odin => "\u{f10d3}",
        };
    }
};

pub const Set = struct {
    bits: u5 = 0,

    pub fn empty() Set {
        return .{ .bits = 0 };
    }

    pub fn add(self: *Set, kind: Kind) void {
        self.bits |= bit(kind);
    }

    pub fn has(self: Set, kind: Kind) bool {
        return self.bits & bit(kind) != 0;
    }

    fn bit(kind: Kind) u5 {
        return @as(u5, 1) << @intFromEnum(kind);
    }
};

pub const Entry = struct {
    name: []const u8,
    is_dir: bool,
};

pub const max_version_bytes = 24;

/// Classifies one directory entry. Adapters stream entries straight into this
/// so a project root never has to be materialised in memory.
pub fn classifyName(set: *Set, name: []const u8, is_dir: bool) void {
    if (is_dir) return;
    if (std.mem.eql(u8, name, "build.zig") or std.mem.eql(u8, name, "build.zig.zon")) {
        set.add(.zig);
        return;
    }
    if (std.mem.eql(u8, name, "Cargo.toml")) {
        set.add(.rust);
        return;
    }
    if (std.mem.eql(u8, name, "go.mod") or std.mem.eql(u8, name, "go.sum")) {
        set.add(.go);
        return;
    }
    if (std.mem.eql(u8, name, "package.json")) {
        set.add(.node);
        return;
    }
    if (std.mem.endsWith(u8, name, ".odin")) set.add(.odin);
}

/// Reads `.minimum_zig_version = "0.17.0"` out of `build.zig.zon`.
pub fn zigVersionFromZon(contents: []const u8) ?[]const u8 {
    const key = ".minimum_zig_version";
    var index = std.mem.indexOf(u8, contents, key) orelse return null;
    index += key.len;
    while (index < contents.len and (contents[index] == ' ' or contents[index] == '=')) index += 1;
    return quoted(contents, index);
}

/// Reads the `go 1.22.3` directive from `go.mod`.
pub fn goVersionFromMod(contents: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, "go ")) continue;
        const version = std.mem.trim(u8, line[3..], " \t\r");
        if (validVersion(version)) return version;
        return null;
    }
    return null;
}

/// Reads `channel = "1.80.0"` from `rust-toolchain.toml`.
pub fn rustVersionFromToolchain(contents: []const u8) ?[]const u8 {
    const key = "channel";
    var index = std.mem.indexOf(u8, contents, key) orelse return null;
    index += key.len;
    while (index < contents.len and (contents[index] == ' ' or contents[index] == '=')) index += 1;
    const version = quoted(contents, index) orelse return null;
    return if (validVersion(version)) version else null;
}

/// Reads a plain version file such as `.nvmrc` or `.zigversion`, tolerating a
/// leading `v` and the `rust-toolchain` file's optional `[channel]` markers.
pub fn plainVersion(contents: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, contents, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > max_version_bytes) return null;
    const version = if (trimmed[0] == 'v' and trimmed.len > 1) trimmed[1..] else trimmed;
    if (!validVersion(version)) return null;
    return version;
}

fn quoted(contents: []const u8, start: usize) ?[]const u8 {
    var index = start;
    while (index < contents.len and contents[index] != '"') index += 1;
    if (index == contents.len) return null;
    const value_start = index + 1;
    index = value_start;
    while (index < contents.len and contents[index] != '"') index += 1;
    if (index == contents.len) return null;
    const value = contents[value_start..index];
    if (!validVersion(value)) return null;
    return value;
}

fn validVersion(value: []const u8) bool {
    // A single character is never a version; it is a truncation or a typo.
    if (value.len < 2) return false;
    if (value.len > max_version_bytes) return false;
    for (value) |byte| {
        const allowed = std.ascii.isAlphanumeric(byte) or
            byte == '.' or byte == '-' or byte == '+' or byte == '_';
        if (!allowed) return false;
    }
    return true;
}

test "classify recognises every supported project" {
    var set = Set.empty();
    const entries = [_]Entry{
        .{ .name = "build.zig", .is_dir = false },
        .{ .name = "Cargo.toml", .is_dir = false },
        .{ .name = "go.mod", .is_dir = false },
        .{ .name = "package.json", .is_dir = false },
        .{ .name = "main.odin", .is_dir = false },
    };
    for (entries) |entry| classifyName(&set, entry.name, entry.is_dir);
    try std.testing.expect(set.has(.zig));
    try std.testing.expect(set.has(.rust));
    try std.testing.expect(set.has(.go));
    try std.testing.expect(set.has(.node));
    try std.testing.expect(set.has(.odin));
}

test "classify ignores look-alikes and directories" {
    // A directory that happens to be called build.zig is not a Zig project.
    var directories = Set.empty();
    classifyName(&directories, "build.zig", true);
    classifyName(&directories, "Cargo.toml", true);
    try std.testing.expect(!directories.has(.zig));
    try std.testing.expect(!directories.has(.rust));

    var set = Set.empty();
    const entries = [_]Entry{
        .{ .name = "go.sum", .is_dir = false },
        .{ .name = "cargo.toml", .is_dir = false },
        .{ .name = "package.json.bak", .is_dir = false },
        .{ .name = "main.odin.disabled", .is_dir = false },
        .{ .name = "README.md", .is_dir = false },
    };
    for (entries) |entry| classifyName(&set, entry.name, entry.is_dir);
    try std.testing.expect(set.has(.go));
    try std.testing.expect(!set.has(.zig));
    try std.testing.expect(!set.has(.rust));
    try std.testing.expect(!set.has(.node));
    try std.testing.expect(!set.has(.odin));
}

test "an empty listing yields an empty set" {
    const set = Set.empty();
    try std.testing.expect(!set.has(.zig));
}

test "reads the minimum zig version from a package manifest" {
    const zon =
        \\.{
        \\    .name = .prompty,
        \\    .version = "0.1.0",
        \\    .minimum_zig_version = "0.17.0",
        \\}
    ;
    try std.testing.expectEqualStrings("0.17.0", zigVersionFromZon(zon).?);
    try std.testing.expectEqual(@as(?[]const u8, null), zigVersionFromZon(".{}"));
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        zigVersionFromZon(".minimum_zig_version = "),
    );
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        zigVersionFromZon(".minimum_zig_version = \"0.17.0"),
    );
}

test "reads the go directive from go.mod" {
    const mod =
        \\module example.com/app
        \\
        \\go 1.22.3
        \\
        \\require example.com/dep v0.0.0
    ;
    try std.testing.expectEqualStrings("1.22.3", goVersionFromMod(mod).?);
    try std.testing.expectEqual(@as(?[]const u8, null), goVersionFromMod("module x\n"));
    try std.testing.expectEqual(@as(?[]const u8, null), goVersionFromMod("go \n"));
    try std.testing.expectEqual(@as(?[]const u8, null), goVersionFromMod("go not a version"));
}

test "reads the channel from rust-toolchain.toml" {
    const toolchain =
        \\[toolchain]
        \\channel = "1.80.0"
        \\components = [ "rustfmt" ]
    ;
    try std.testing.expectEqualStrings("1.80.0", rustVersionFromToolchain(toolchain).?);
    try std.testing.expectEqual(@as(?[]const u8, null), rustVersionFromToolchain("[toolchain]"));
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        rustVersionFromToolchain("channel = \"has spaces\""),
    );
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        rustVersionFromToolchain("channel = "),
    );
}

test "plain version files tolerate a leading v and whitespace" {
    try std.testing.expectEqualStrings("20.11.0", plainVersion("v20.11.0\n").?);
    try std.testing.expectEqualStrings("0.17.0", plainVersion("  0.17.0 \n").?);
    try std.testing.expectEqualStrings("stable", plainVersion("stable\n").?);
    try std.testing.expectEqualStrings("1.80.0-x86_64", plainVersion("1.80.0-x86_64").?);
}

test "plain version files reject junk" {
    try std.testing.expectEqual(@as(?[]const u8, null), plainVersion(""));
    try std.testing.expectEqual(@as(?[]const u8, null), plainVersion("   \n"));
    try std.testing.expectEqual(@as(?[]const u8, null), plainVersion("v"));
    try std.testing.expectEqual(@as(?[]const u8, null), plainVersion("not a version"));
    // A version string longer than the prompt's slot is rejected rather than
    // silently truncated.
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        plainVersion("1234567890123456789012345"),
    );
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        plainVersion("1.80.0-x86_64-unknown-linux-gnu"),
    );
}

test "icons are single glyphs" {
    const info = @typeInfo(Kind).@"enum";
    inline for (info.field_names, info.field_values) |field_name, field_value| {
        _ = field_name;
        const kind: Kind = @enumFromInt(field_value);
        try std.testing.expect(kind.icon().len > 0);
        try std.testing.expect(kind.icon().len < 6);
    }
}
