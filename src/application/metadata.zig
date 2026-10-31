//! Application metadata. Both values come from `build.zig.zon`, through the
//! `build_options` module that build.zig generates, so there is exactly one
//! place to bump a version.

const std = @import("std");
const options = @import("build_options");

pub const name: []const u8 = options.name;
pub const version: []const u8 = options.version;

test "the generated name and version are usable" {
    try std.testing.expect(name.len > 0);
    try std.testing.expect(std.mem.indexOfAny(u8, name, " \t\n") == null);
    const parsed = try std.SemanticVersion.parse(version);
    try std.testing.expect(parsed.major >= 0);
}
