//! The render surface: a bounded buffer that knows how to emit colours and how
//! to quote literal text for the shell that is going to display the result.
//!
//! Zsh wraps non-printing sequences in `%{...%}` and treats `%` as an escape
//! character; bash wraps them in `\[...\]` and treats `\` as an escape
//! character. Getting this wrong does not just look ugly, it corrupts line
//! editing, so it lives in one place and is tested for every shell.

const std = @import("std");

pub const Shell = enum {
    plain,
    zsh,
    bash,

    pub fn parse(name: []const u8) ?Shell {
        if (std.mem.eql(u8, name, "plain")) return .plain;
        if (std.mem.eql(u8, name, "zsh")) return .zsh;
        if (std.mem.eql(u8, name, "bash")) return .bash;
        return null;
    }

    /// Sequence that opens a non-printing escape for this shell.
    fn escapeOpen(self: Shell) []const u8 {
        return switch (self) {
            .plain => "",
            .zsh => "%{",
            .bash => "\\[",
        };
    }

    /// Sequence that closes a non-printing escape for this shell.
    fn escapeClose(self: Shell) []const u8 {
        return switch (self) {
            .plain => "",
            .zsh => "%}",
            .bash => "\\]",
        };
    }
};

pub const Canvas = struct {
    /// A maximal prompt is about 1 KiB: a clipped path, a branch, every marker
    /// and a truecolor sequence per segment. 2048 leaves room for all of that
    /// with margin, and `zig build test` checks the bound with every field at
    /// its maximum.
    pub const capacity = 2048;

    buffer: []u8,
    len: usize,
    shell: Shell,
    color: bool,

    pub fn init(buffer: []u8, shell: Shell, color: bool) Canvas {
        std.debug.assert(buffer.len <= capacity);
        return .{ .buffer = buffer, .len = 0, .shell = shell, .color = color };
    }

    pub fn bytes(self: *const Canvas) []const u8 {
        return self.buffer[0..self.len];
    }

    /// Appends literal text, quoting any character the target shell would
    /// otherwise interpolate.
    pub fn text(self: *Canvas, content: []const u8) void {
        switch (self.shell) {
            .plain => self.raw(content),
            .zsh => self.textQuoting(content, '%'),
            .bash => self.textQuoting(content, '\\'),
        }
    }

    /// Appends a non-printing sequence, wrapped for the target shell. Without
    /// colour nothing is emitted at all, so `NO_COLOR` output is byte-for-byte
    /// plain text.
    pub fn escape(self: *Canvas, sequence: []const u8) void {
        if (!self.color) return;
        self.raw(self.shell.escapeOpen());
        self.raw(sequence);
        self.raw(self.shell.escapeClose());
    }

    /// Appends a non-printing sequence built from a format string.
    pub fn escapeFmt(self: *Canvas, comptime format: []const u8, args: anytype) void {
        if (!self.color) return;
        var scratch: [64]u8 = undefined;
        const sequence = std.fmt.bufPrint(&scratch, format, args) catch unreachable;
        self.escape(sequence);
    }

    fn textQuoting(self: *Canvas, content: []const u8, special: u8) void {
        var start: usize = 0;
        for (content, 0..) |byte, index| {
            if (byte != special) continue;
            self.raw(content[start .. index + 1]);
            self.raw(&[_]u8{special});
            start = index + 1;
        }
        self.raw(content[start..]);
    }

    /// Appends to the buffer and stops at its end. The guard used to be an
    /// assertion, which the release build compiles away: a name longer than the
    /// prompt then wrote past the buffer and the prompt printed whatever
    /// followed it from the stack.
    fn raw(self: *Canvas, content: []const u8) void {
        const room = self.buffer.len - self.len;
        var taken = @min(content.len, room);
        if (taken < content.len) {
            while (taken > 0 and (content[taken] & 0xc0) == 0x80) taken -= 1;
        }
        @memcpy(self.buffer[self.len..][0..taken], content[0..taken]);
        self.len += taken;
    }
};

test "shell names parse and reject" {
    try std.testing.expectEqual(@as(?Shell, .plain), Shell.parse("plain"));
    try std.testing.expectEqual(@as(?Shell, .zsh), Shell.parse("zsh"));
    try std.testing.expectEqual(@as(?Shell, .bash), Shell.parse("bash"));
    try std.testing.expectEqual(@as(?Shell, null), Shell.parse("fish"));
    try std.testing.expectEqual(@as(?Shell, null), Shell.parse(""));
    try std.testing.expectEqual(@as(?Shell, null), Shell.parse("ZSH"));
}

test "plain shell emits sequences untouched" {
    var buffer: [64]u8 = undefined;
    var canvas = Canvas.init(&buffer, .plain, true);
    canvas.escape("\x1b[1m");
    canvas.text("50% of \\ the way");
    try std.testing.expectEqualStrings("\x1b[1m50% of \\ the way", canvas.bytes());
}

test "zsh wraps escapes and doubles percent signs" {
    var buffer: [64]u8 = undefined;
    var canvas = Canvas.init(&buffer, .zsh, true);
    canvas.escape("\x1b[1m");
    canvas.text("100%");
    try std.testing.expectEqualStrings("%{\x1b[1m%}100%%", canvas.bytes());
}

test "bash wraps escapes and doubles backslashes" {
    var buffer: [64]u8 = undefined;
    var canvas = Canvas.init(&buffer, .bash, true);
    canvas.escape("\x1b[1m");
    canvas.text("c:\\tmp");
    try std.testing.expectEqualStrings("\\[\x1b[1m\\]c:\\\\tmp", canvas.bytes());
}

test "colour can be turned off without changing layout" {
    var buffer: [64]u8 = undefined;
    var canvas = Canvas.init(&buffer, .zsh, false);
    canvas.escapeFmt("\x1b[38;2;{d};{d};{d}m", .{ 1, 2, 3 });
    canvas.text("x");
    try std.testing.expectEqualStrings("x", canvas.bytes());
}

test "escapeFmt renders truecolor" {
    var buffer: [64]u8 = undefined;
    var canvas = Canvas.init(&buffer, .plain, true);
    canvas.escapeFmt("\x1b[38;2;{d};{d};{d}m", .{ 10, 20, 30 });
    canvas.text("x");
    try std.testing.expectEqualStrings("\x1b[38;2;10;20;30mx", canvas.bytes());
}

test "text past the end of the buffer is dropped, not written" {
    var buffer: [8]u8 = undefined;
    var canvas = Canvas.init(&buffer, .plain, true);
    canvas.text("abcdefgh");
    canvas.text("ijkl");
    try std.testing.expectEqualStrings("abcdefgh", canvas.bytes());
    var quoted = Canvas.init(&buffer, .zsh, true);
    quoted.text("%%%%%%");
    try std.testing.expectEqualStrings("%%%%%%%%", quoted.bytes());
}

test "a cut at the end of the buffer does not split a character" {
    var buffer: [2]u8 = undefined;
    var canvas = Canvas.init(&buffer, .plain, true);
    canvas.text("a\u{00f1}");
    try std.testing.expectEqualStrings("a", canvas.bytes());
    try std.testing.expect(std.unicode.utf8ValidateSlice(canvas.bytes()));
}

test "text at the very end of the buffer is quoted correctly" {
    var buffer: [10]u8 = undefined;
    var canvas = Canvas.init(&buffer, .zsh, true);
    canvas.text("%%%%%");
    try std.testing.expectEqualStrings("%%%%%%%%%%", canvas.bytes());
}

test "property: no text, quoted or not, escapes the buffer" {
    var prng = std.Random.DefaultPrng.init(0xca77a5);
    const random = prng.random();
    const pieces = [_][]const u8{ "abc", "%", "\\", "\x1b[1m", "ñ", "🚀", "50%" };

    inline for (.{ Shell.plain, Shell.zsh, Shell.bash }) |shell| {
        for (0..800) |_| {
            var buffer: [64]u8 = undefined;
            var canvas = Canvas.init(&buffer, shell, true);
            const count = random.intRangeAtMost(usize, 0, 20);
            for (0..count) |_| {
                const piece = pieces[random.uintLessThan(usize, pieces.len)];
                if (random.boolean()) canvas.text(piece) else canvas.escape(piece);
                try std.testing.expect(canvas.bytes().len <= buffer.len);
            }
            try std.testing.expect(canvas.len <= buffer.len);
        }
    }
}
