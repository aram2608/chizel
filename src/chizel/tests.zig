const std = @import("std");
const testing = std.testing;
const Chizel = @import("chizel.zig").Chizel;

const SliceIter = struct {
    tokens: []const []const u8,
    index: usize = 0,

    pub fn next(self: *SliceIter) ?[]const u8 {
        if (self.index >= self.tokens.len) return null;
        defer self.index += 1;
        return self.tokens[self.index];
    }
};

fn ziggyParser(comptime Opts: type, iter: *SliceIter) Chizel(Opts) {
    const arena = std.heap.ArenaAllocator.init(testing.allocator);
    return Chizel(Opts).init(iter, arena);
}

// Boolean

test "ziggy boolean: absent keeps default false" {
    const Opts = struct { verbose: bool = false };
    var iter = SliceIter{ .tokens = &.{"prog"} };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(!r.opts.verbose);
}

test "ziggy boolean: --flag sets true" {
    const Opts = struct { verbose: bool = false };
    var iter = SliceIter{ .tokens = &.{ "prog", "--verbose" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.opts.verbose);
}

test "ziggy boolean: --no-flag sets false" {
    const Opts = struct { verbose: bool = true };
    var iter = SliceIter{ .tokens = &.{ "prog", "--no-verbose" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(!r.opts.verbose);
}

test "ziggy boolean: short flag" {
    const Opts = struct {
        verbose: bool = false,
        pub const shorts = .{ .verbose = 'v' };
    };
    var iter = SliceIter{ .tokens = &.{ "prog", "-v" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.opts.verbose);
}

test "ziggy boolean: --no- on non-bool returns error" {
    const Opts = struct { port: u16 = 8080 };
    var iter = SliceIter{ .tokens = &.{ "prog", "--no-port" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    try testing.expectError(error.CannotNegate, p.parse());
}

// Integer

test "ziggy int: parsed correctly" {
    const Opts = struct { port: u16 = 0 };
    var iter = SliceIter{ .tokens = &.{ "prog", "--port", "9090" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqual(@as(u16, 9090), r.opts.port);
}

test "ziggy int: default used when absent" {
    const Opts = struct { port: u16 = 8080 };
    var iter = SliceIter{ .tokens = &.{"prog"} };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqual(@as(u16, 8080), r.opts.port);
}

test "ziggy int: short flag" {
    const Opts = struct {
        port: u16 = 0,
        pub const shorts = .{ .port = 'p' };
    };
    var iter = SliceIter{ .tokens = &.{ "prog", "-p", "1000" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqual(@as(u16, 1000), r.opts.port);
}

test "ziggy int: missing value returns error" {
    const Opts = struct { port: u16 = 0 };
    var iter = SliceIter{ .tokens = &.{ "prog", "--port" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    try testing.expectError(error.MissingValue, p.parse());
}

test "ziggy int: bad value returns error" {
    const Opts = struct { port: u16 = 0 };
    var iter = SliceIter{ .tokens = &.{ "prog", "--port", "abc" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    try testing.expectError(error.InvalidCharacter, p.parse());
}

// Float

test "ziggy float: parsed correctly" {
    const Opts = struct { rate: f32 = 0 };
    var iter = SliceIter{ .tokens = &.{ "prog", "--rate", "3.14" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectApproxEqRel(@as(f32, 3.14), r.opts.rate, 1e-5);
}

// String

test "ziggy string: parsed correctly" {
    const Opts = struct { host: []const u8 = "localhost" };
    var iter = SliceIter{ .tokens = &.{ "prog", "--host", "example.com" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqualStrings("example.com", r.opts.host);
}

test "ziggy string: default used when absent" {
    const Opts = struct { host: []const u8 = "localhost" };
    var iter = SliceIter{ .tokens = &.{"prog"} };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqualStrings("localhost", r.opts.host);
}

test "ziggy string: missing value returns error" {
    const Opts = struct { host: []const u8 = "localhost" };
    var iter = SliceIter{ .tokens = &.{ "prog", "--host" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    try testing.expectError(error.MissingValue, p.parse());
}

// Optional

test "ziggy optional: null when absent" {
    const Opts = struct { name: ?[]const u8 = null };
    var iter = SliceIter{ .tokens = &.{"prog"} };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.opts.name == null);
}

test "ziggy optional: value when present" {
    const Opts = struct { name: ?[]const u8 = null };
    var iter = SliceIter{ .tokens = &.{ "prog", "--name", "alice" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqualStrings("alice", r.opts.name.?);
}

// String slice

test "ziggy string slice: consumes multiple values" {
    const Opts = struct { tags: []const []const u8 = &.{} };
    var iter = SliceIter{ .tokens = &.{ "prog", "--tags", "a", "b", "c" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqual(@as(usize, 3), r.opts.tags.len);
    try testing.expectEqualStrings("a", r.opts.tags[0]);
    try testing.expectEqualStrings("b", r.opts.tags[1]);
    try testing.expectEqualStrings("c", r.opts.tags[2]);
}

test "ziggy string slice: stops at next flag" {
    const Opts = struct { tags: []const []const u8 = &.{}, verbose: bool = false };
    var iter = SliceIter{ .tokens = &.{ "prog", "--tags", "a", "b", "--verbose" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqual(@as(usize, 2), r.opts.tags.len);
    try testing.expect(r.opts.verbose);
}

test "ziggy string slice: negative numbers not treated as flags" {
    const Opts = struct { vals: []const []const u8 = &.{} };
    var iter = SliceIter{ .tokens = &.{ "prog", "--vals", "-1", "-2.5" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqual(@as(usize, 2), r.opts.vals.len);
    try testing.expectEqualStrings("-1", r.opts.vals[0]);
    try testing.expectEqualStrings("-2.5", r.opts.vals[1]);
}

test "ziggy string slice: missing value returns error" {
    const Opts = struct { tags: []const []const u8 = &.{} };
    var iter = SliceIter{ .tokens = &.{ "prog", "--tags" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    try testing.expectError(error.MissingValue, p.parse());
}

// Positionals

test "ziggy positionals: collected in order" {
    const Opts = struct { verbose: bool = false };
    var iter = SliceIter{ .tokens = &.{ "prog", "foo", "bar", "baz" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqual(@as(usize, 3), r.positionals.len);
    try testing.expectEqualStrings("foo", r.positionals[0]);
    try testing.expectEqualStrings("bar", r.positionals[1]);
    try testing.expectEqualStrings("baz", r.positionals[2]);
}

test "ziggy positionals: mixed with flags" {
    const Opts = struct { verbose: bool = false };
    var iter = SliceIter{ .tokens = &.{ "prog", "foo", "--verbose", "bar" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqual(@as(usize, 2), r.positionals.len);
    try testing.expect(r.opts.verbose);
}

// prog

test "ziggy prog: captured from argv[0]" {
    const Opts = struct { verbose: bool = false };
    var iter = SliceIter{ .tokens = &.{"myapp"} };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqualStrings("myapp", r.prog);
}

// Unknown options

test "ziggy unknown: error when allow_unknown=false" {
    const Opts = struct { verbose: bool = false };
    var iter = SliceIter{ .tokens = &.{ "prog", "--typo" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    try testing.expectError(error.UnknownOption, p.parse());
}

test "ziggy unknown: collected when allow_unknown=true" {
    const Opts = struct {
        verbose: bool = false,
        pub const config = .{ .allow_unknown = true };
    };
    var iter = SliceIter{ .tokens = &.{ "prog", "--typo" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqual(@as(usize, 1), r.unknown_options.len);
    try testing.expectEqualStrings("typo", r.unknown_options[0]);
}

// -- separator

test "ziggy --: remaining tokens become positionals" {
    const Opts = struct { verbose: bool = false };
    var iter = SliceIter{ .tokens = &.{ "prog", "--verbose", "--", "--not-a-flag", "pos" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.opts.verbose);
    try testing.expectEqual(@as(usize, 2), r.positionals.len);
    try testing.expectEqualStrings("--not-a-flag", r.positionals[0]);
    try testing.expectEqualStrings("pos", r.positionals[1]);
}

// --help

test "ziggy help: had_help true for --help" {
    const Opts = struct { verbose: bool = false };
    var iter = SliceIter{ .tokens = &.{ "prog", "--help" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.had_help);
}

test "ziggy help: had_help true for -h" {
    const Opts = struct { verbose: bool = false };
    var iter = SliceIter{ .tokens = &.{ "prog", "-h" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.had_help);
}

test "ziggy help: false when absent" {
    const Opts = struct { verbose: bool = false };
    var iter = SliceIter{ .tokens = &.{"prog"} };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(!r.had_help);
}

// Error conditions

test "ziggy already parsed returns error" {
    const Opts = struct { verbose: bool = false };
    var iter = SliceIter{ .tokens = &.{"prog"} };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    _ = try p.parse();
    try testing.expectError(error.AlreadyParsed, p.parse());
}

// Inline key=value syntax

test "ziggy inline value: --string=value" {
    const Opts = struct { host: []const u8 = "localhost" };
    var iter = SliceIter{ .tokens = &.{ "prog", "--host=example.com" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqualStrings("example.com", r.opts.host);
}

test "ziggy inline value: --int=value" {
    const Opts = struct { port: u16 = 0 };
    var iter = SliceIter{ .tokens = &.{ "prog", "--port=9090" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqual(@as(u16, 9090), r.opts.port);
}

test "ziggy inline value: --float=value" {
    const Opts = struct { rate: f32 = 0 };
    var iter = SliceIter{ .tokens = &.{ "prog", "--rate=1.5" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectApproxEqRel(@as(f32, 1.5), r.opts.rate, 1e-5);
}

test "ziggy inline value: --optional=value" {
    const Opts = struct { name: ?[]const u8 = null };
    var iter = SliceIter{ .tokens = &.{ "prog", "--name=alice" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqualStrings("alice", r.opts.name.?);
}

test "ziggy inline value: --bool=value returns error" {
    const Opts = struct { verbose: bool = false };
    var iter = SliceIter{ .tokens = &.{ "prog", "--verbose=true" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    try testing.expectError(error.BoolCannotHaveValue, p.parse());
}

test "ziggy inline value: --slice=first then continues consuming" {
    const Opts = struct { tags: []const []const u8 = &.{} };
    var iter = SliceIter{ .tokens = &.{ "prog", "--tags=a", "b", "c" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqual(@as(usize, 3), r.opts.tags.len);
    try testing.expectEqualStrings("a", r.opts.tags[0]);
    try testing.expectEqualStrings("b", r.opts.tags[1]);
    try testing.expectEqualStrings("c", r.opts.tags[2]);
}

// Combined short flags

test "ziggy combined shorts: -abc sets all three booleans" {
    const Opts = struct {
        alpha: bool = false,
        beta: bool = false,
        gamma: bool = false,
        pub const shorts = .{ .alpha = 'a', .beta = 'b', .gamma = 'g' };
    };
    var iter = SliceIter{ .tokens = &.{ "prog", "-abg" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.opts.alpha);
    try testing.expect(r.opts.beta);
    try testing.expect(r.opts.gamma);
}

test "ziggy combined shorts: unknown char in group errors" {
    const Opts = struct {
        alpha: bool = false,
        pub const shorts = .{ .alpha = 'a' };
    };
    var iter = SliceIter{ .tokens = &.{ "prog", "-az" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    try testing.expectError(error.UnknownOption, p.parse());
}

test "ziggy combined shorts: unknown collected when allow_unknown" {
    const Opts = struct {
        alpha: bool = false,
        pub const shorts = .{ .alpha = 'a' };
        pub const config = .{ .allow_unknown = true };
    };
    var iter = SliceIter{ .tokens = &.{ "prog", "-az" } };
    var p = ziggyParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.opts.alpha);
    try testing.expectEqual(@as(usize, 1), r.unknown_options.len);
    try testing.expectEqualStrings("z", r.unknown_options[0]);
}
