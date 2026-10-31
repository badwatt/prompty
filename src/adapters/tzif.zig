//! Minimal TZif (RFC 8536) reader: enough to answer "what is the UTC offset at
//! this instant", with no allocation and no libc.
//!
//! Zig's `std.tz` needs an allocator and a reader; a prompt needs neither, and
//! paying for them on every single prompt is exactly the kind of cost prompty
//! exists to avoid.

const std = @import("std");

pub const magic = "TZif";

const Header = struct {
    counts: Counts,
    version: u8,
};

const Counts = struct {
    is_utc: u32,
    is_std: u32,
    leap: u32,
    transition: u32,
    type: u32,
    chars: u32,

    fn isSane(self: Counts) bool {
        // A TZif file has at least one local time type and a non-empty
        // abbreviation table; anything larger than this is not a real zone.
        if (self.type == 0) return false;
        if (self.chars == 0) return false;
        if (self.type > 256) return false;
        if (self.chars > 512) return false;
        if (self.transition > 100_000) return false;
        return true;
    }
};

/// Returns the UTC offset, in seconds, that applies to `unix_seconds`.
///
/// Null means "this is not a TZif file, or it is malformed": the caller then
/// falls back to UTC rather than printing a wrong clock.
pub fn offsetAt(zone: []const u8, unix_seconds: i64) ?i32 {
    var reader = Reader{ .data = zone };
    const first = parseHeader(&reader) orelse return null;
    const first_block = blockLength(first.counts, 4) orelse return null;

    var block = Block{
        .counts = first.counts,
        .data_start = reader.position,
        .time_size = 4,
    };

    if (first.version >= '2') {
        // Version 2+ files carry a second, 64-bit block that supersedes the
        // legacy one. Only the second block is interesting.
        reader.skip(first_block) orelse return null;
        const second = parseHeader(&reader) orelse return null;
        const second_block = blockLength(second.counts, 8) orelse return null;
        if (reader.position + second_block > zone.len) return null;
        block = .{
            .counts = second.counts,
            .data_start = reader.position,
            .time_size = 8,
        };
    } else {
        if (block.data_start + first_block > zone.len) return null;
    }

    return block.lookup(zone, unix_seconds);
}

const Block = struct {
    counts: Counts,
    data_start: usize,
    time_size: usize,

    fn indicesStart(self: Block) usize {
        return self.data_start + self.counts.transition * self.time_size;
    }

    fn typesStart(self: Block) usize {
        return self.indicesStart() + self.counts.transition;
    }

    fn lookup(self: Block, zone: []const u8, unix_seconds: i64) ?i32 {
        if (self.counts.transition == 0) return self.fallbackOffset(zone);

        const first_time = self.timeAt(zone, 0) orelse return null;
        if (unix_seconds < first_time) return self.fallbackOffset(zone);

        // Binary search for the last transition that is not in the future.
        var low: u32 = 0;
        var high: u32 = self.counts.transition;
        while (low + 1 < high) {
            const middle = low + (high - low) / 2;
            const time = self.timeAt(zone, middle) orelse return null;
            if (time <= unix_seconds) {
                low = middle;
            } else {
                high = middle;
            }
        }

        const index_offset = self.indicesStart() + low;
        if (index_offset >= zone.len) return null;
        return self.typeOffset(zone, zone[index_offset]);
    }

    /// Before the first transition, and in zones with no transitions at all,
    /// the first non-DST type is the right answer.
    fn fallbackOffset(self: Block, zone: []const u8) ?i32 {
        var index: u32 = 0;
        while (index < self.counts.type) : (index += 1) {
            const is_dst = self.typeIsDst(zone, index) orelse return null;
            if (!is_dst) return self.typeOffset(zone, index);
        }
        return self.typeOffset(zone, 0);
    }

    fn timeAt(self: Block, zone: []const u8, index: u32) ?i64 {
        const offset = self.data_start + index * self.time_size;
        const reader = Reader{ .data = zone, .position = offset };
        return switch (self.time_size) {
            4 => if (reader.i32Big()) |value| @as(i64, value) else null,
            8 => reader.i64Big(),
            else => null,
        };
    }

    fn typeIsDst(self: Block, zone: []const u8, index: u32) ?bool {
        const offset = self.typesStart() + index * 6 + 4;
        if (offset >= zone.len) return null;
        return zone[offset] != 0;
    }

    fn typeOffset(self: Block, zone: []const u8, index: u32) ?i32 {
        if (index >= self.counts.type) return null;
        const offset = self.typesStart() + @as(usize, index) * 6;
        const reader = Reader{ .data = zone, .position = offset };
        return reader.i32Big();
    }
};

fn parseHeader(reader: *Reader) ?Header {
    const start = reader.position;
    const bytes = reader.take(44) orelse return null;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return null;
    const version = bytes[4];
    if (version != 0 and version != '2' and version != '3' and version != '4') return null;

    const counts = Counts{
        .is_utc = be32(bytes[20..24]),
        .is_std = be32(bytes[24..28]),
        .leap = be32(bytes[28..32]),
        .transition = be32(bytes[32..36]),
        .type = be32(bytes[36..40]),
        .chars = be32(bytes[40..44]),
    };
    if (!counts.isSane()) return null;
    reader.position = start + 44;
    return .{ .counts = counts, .version = version };
}

fn blockLength(counts: Counts, time_size: usize) ?usize {
    const transition_bytes = std.math.mul(u32, counts.transition, @intCast(time_size)) catch return null;
    const total = @as(u64, transition_bytes) +
        counts.transition +
        @as(u64, counts.type) * 6 +
        counts.chars +
        @as(u64, counts.leap) * 8 +
        counts.is_std +
        counts.is_utc;
    return @intCast(total);
}

const Reader = struct {
    data: []const u8,
    position: usize = 0,

    fn take(self: *Reader, count: usize) ?[]const u8 {
        if (self.position + count > self.data.len) return null;
        const slice = self.data[self.position..][0..count];
        self.position += count;
        return slice;
    }

    fn skip(self: *Reader, count: usize) ?void {
        if (self.position + count > self.data.len) return null;
        self.position += count;
    }

    fn i32Big(self: Reader) ?i32 {
        if (self.position + 4 > self.data.len) return null;
        const value = std.mem.readInt(i32, self.data[self.position..][0..4], .big);
        return value;
    }

    fn i64Big(self: Reader) ?i64 {
        if (self.position + 8 > self.data.len) return null;
        const value = std.mem.readInt(i64, self.data[self.position..][0..8], .big);
        return value;
    }
};

fn be32(bytes: []const u8) u32 {
    std.debug.assert(bytes.len == 4);
    return std.mem.readInt(u32, bytes[0..4], .big);
}

// ---------------------------------------------------------------------------
// Test fixtures: a tiny, explicit TZif writer so every branch of the parser is
// exercised without depending on the host's zoneinfo database.
// ---------------------------------------------------------------------------

const Fixture = struct {
    const Type = struct { offset: i32, is_dst: bool };
    const Zone = struct { transitions: []const i64, indices: []const u8, types: []const Type };

    buffer: [512]u8 = undefined,
    length: usize = 0,

    fn append(self: *Fixture, bytes: []const u8) void {
        @memcpy(self.buffer[self.length..][0..bytes.len], bytes);
        self.length += bytes.len;
    }

    fn appendInt(self: *Fixture, comptime T: type, value: T) void {
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, .big);
        self.append(&bytes);
    }

    fn header(self: *Fixture, version: u8, header_counts: Counts) void {
        self.append(magic);
        self.append(&.{version});
        const padding: [15]u8 = @splat(0);
        self.append(&padding);
        self.appendInt(u32, header_counts.is_utc);
        self.appendInt(u32, header_counts.is_std);
        self.appendInt(u32, header_counts.leap);
        self.appendInt(u32, header_counts.transition);
        self.appendInt(u32, header_counts.type);
        self.appendInt(u32, header_counts.chars);
    }

    fn data(self: *Fixture, block: Zone, time_size: usize) void {
        for (block.transitions) |transition| {
            if (time_size == 4) {
                self.appendInt(i32, @intCast(transition));
            } else {
                self.appendInt(i64, transition);
            }
        }
        self.append(block.indices);
        for (block.types) |type_value| {
            self.appendInt(i32, type_value.offset);
            self.append(&.{@intFromBool(type_value.is_dst), 0});
        }
        self.append("UTC0");
    }

    fn countsOf(block: Zone) Counts {
        return .{
            .is_utc = 0,
            .is_std = 0,
            .leap = 0,
            .transition = @intCast(block.transitions.len),
            .type = @intCast(block.types.len),
            .chars = 4,
        };
    }

    fn single(self: *Fixture, version: u8, block: Zone) []const u8 {
        const header_counts = countsOf(block);
        self.header(version, header_counts);
        self.data(block, 4);
        return self.buffer[0..self.length];
    }

    fn withSecondBlock(self: *Fixture, first: Zone, second: Zone) []const u8 {
        self.header('2', countsOf(first));
        self.data(first, 4);
        self.header('2', countsOf(second));
        self.data(second, 8);
        return self.buffer[0..self.length];
    }
};

test "version 1 zones resolve offsets around their transitions" {
    var fixture: Fixture = .{};
    const zone = fixture.single(0, .{
        .transitions = &.{ 1_000, 1_000_000 },
        .indices = &.{ 0, 1 },
        .types = &.{
            .{ .offset = 3_600, .is_dst = false },
            .{ .offset = 7_200, .is_dst = true },
        },
    });

    // Before the first transition the first non-DST type applies.
    try std.testing.expectEqual(@as(?i32, 3_600), offsetAt(zone, 0));
    try std.testing.expectEqual(@as(?i32, 3_600), offsetAt(zone, 999));
    try std.testing.expectEqual(@as(?i32, 3_600), offsetAt(zone, 1_000));
    try std.testing.expectEqual(@as(?i32, 3_600), offsetAt(zone, 999_999));
    try std.testing.expectEqual(@as(?i32, 7_200), offsetAt(zone, 1_000_000));
    try std.testing.expectEqual(@as(?i32, 7_200), offsetAt(zone, std.math.maxInt(i64)));
}

test "version 2 zones use the 64-bit block" {
    var fixture: Fixture = .{};
    // The legacy block says +1h, the modern block says -5h: only the modern
    // block may be consulted.
    const zone = fixture.withSecondBlock(
        .{
            .transitions = &.{0},
            .indices = &.{0},
            .types = &.{.{ .offset = 3_600, .is_dst = false }},
        },
        .{
            .transitions = &.{ -100, 1_000_000 },
            .indices = &.{ 0, 1 },
            .types = &.{
                .{ .offset = -18_000, .is_dst = false },
                .{ .offset = -14_400, .is_dst = true },
            },
        },
    );

    try std.testing.expectEqual(@as(?i32, -18_000), offsetAt(zone, 0));
    try std.testing.expectEqual(@as(?i32, -14_400), offsetAt(zone, 1_000_000));
    try std.testing.expectEqual(@as(?i32, -14_400), offsetAt(zone, 2_000_000_000));
}

test "zones without transitions use their only type" {
    var fixture: Fixture = .{};
    const zone = fixture.single(0, .{
        .transitions = &.{},
        .indices = &.{},
        .types = &.{.{ .offset = 19_800, .is_dst = false }},
    });
    try std.testing.expectEqual(@as(?i32, 19_800), offsetAt(zone, 0));
    try std.testing.expectEqual(@as(?i32, 19_800), offsetAt(zone, 1_700_000_000));
}

test "a DST-only zone falls back to its first type" {
    var fixture: Fixture = .{};
    const zone = fixture.single(0, .{
        .transitions = &.{},
        .indices = &.{},
        .types =&.{.{ .offset = 7_200, .is_dst = true }},
    });
    try std.testing.expectEqual(@as(?i32, 7_200), offsetAt(zone, 0));
}

test "rejects anything that is not a well formed TZif file" {
    var fixture: Fixture = .{};
    const good = fixture.single(0, .{
        .transitions = &.{ 1_000, 2_000 },
        .indices = &.{ 0, 1 },
        .types = &.{
            .{ .offset = 0, .is_dst = false },
            .{ .offset = 3_600, .is_dst = true },
        },
    });

    try std.testing.expectEqual(@as(?i32, null), offsetAt("", 0));
    try std.testing.expectEqual(@as(?i32, null), offsetAt("TZif", 0));
    var wrong_magic: [512]u8 = undefined;
    @memcpy(wrong_magic[0..good.len], good);
    @memcpy(wrong_magic[0..4], "XXXX");
    try std.testing.expectEqual(@as(?i32, null), offsetAt(wrong_magic[0..good.len], 0));

    var bad_version = fixture.buffer;
    fixture.length = good.len;
    bad_version[4] = '9';
    try std.testing.expectEqual(@as(?i32, null), offsetAt(bad_version[0..fixture.length], 0));

    // Truncated: the block claims more data than the file owns.
    try std.testing.expectEqual(@as(?i32, null), offsetAt(good[0 .. good.len - 1], 0));
    try std.testing.expectEqual(@as(?i32, null), offsetAt(good[0..20], 0));

    // A type index pointing outside the type table.
    var out_of_range: Fixture = .{};
    const broken = out_of_range.single(0, .{
        .transitions = &.{0},
        .indices = &.{9},
        .types = &.{.{ .offset = 0, .is_dst = false }},
    });
    try std.testing.expectEqual(@as(?i32, null), offsetAt(broken, 0));
}

test "rejects headers whose counts cannot describe a real zone" {
    var fixture: Fixture = .{};
    // No local time types at all.
    fixture.header(0, .{ .is_utc = 0, .is_std = 0, .leap = 0, .transition = 0, .type = 0, .chars = 4 });
    try std.testing.expectEqual(@as(?i32, null), offsetAt(fixture.buffer[0..fixture.length], 0));

    var no_chars: Fixture = .{};
    no_chars.header(0, .{ .is_utc = 0, .is_std = 0, .leap = 0, .transition = 0, .type = 1, .chars = 0 });
    try std.testing.expectEqual(@as(?i32, null), offsetAt(no_chars.buffer[0..no_chars.length], 0));

    var too_many_types: Fixture = .{};
    too_many_types.header(0, .{ .is_utc = 0, .is_std = 0, .leap = 0, .transition = 0, .type = 300, .chars = 4 });
    try std.testing.expectEqual(@as(?i32, null), offsetAt(too_many_types.buffer[0..too_many_types.length], 0));

    var too_many_chars: Fixture = .{};
    too_many_chars.header(0, .{ .is_utc = 0, .is_std = 0, .leap = 0, .transition = 0, .type = 1, .chars = 1_000 });
    try std.testing.expectEqual(@as(?i32, null), offsetAt(too_many_chars.buffer[0..too_many_chars.length], 0));

    var too_many_transitions: Fixture = .{};
    too_many_transitions.header(0, .{
        .is_utc = 0,
        .is_std = 0,
        .leap = 0,
        .transition = 200_000,
        .type = 1,
        .chars = 4,
    });
    try std.testing.expectEqual(
        @as(?i32, null),
        offsetAt(too_many_transitions.buffer[0..too_many_transitions.length], 0),
    );
}

test "a version 2 file whose second header is missing is rejected" {
    var fixture: Fixture = .{};
    const block = Fixture.Zone{
        .transitions = &.{0},
        .indices = &.{0},
        .types = &.{.{ .offset = 0, .is_dst = false }},
    };
    fixture.header('2', Fixture.countsOf(block));
    fixture.data(block, 4);
    try std.testing.expectEqual(@as(?i32, null), offsetAt(fixture.buffer[0..fixture.length], 0));
}
