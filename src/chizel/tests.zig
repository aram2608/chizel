const std = @import("std");
const testing = std.testing;
const Chizel = @import("chizel.zig").Chizel;
const Chip = @import("chizel.zig").Chip;

const SliceIter = struct {
    tokens: []const []const u8,
    index: usize = 0,

    pub fn next(self: *SliceIter) ?[]const u8 {
        if (self.index >= self.tokens.len) return null;
        defer self.index += 1;
        return self.tokens[self.index];
    }
};

fn chipParser(comptime Opts: type, iter: *SliceIter) Chip(Opts) {
    const arena = std.heap.ArenaAllocator.init(testing.allocator);
    return Chip(Opts).init(iter, arena);
}

fn chizelParser(comptime Cmds: type, iter: *SliceIter) Chizel(Cmds) {
    const arena = std.heap.ArenaAllocator.init(testing.allocator);
    return Chizel(Cmds).init(iter, arena);
}

// Boolean

test "chip boolean: absent keeps default false" {
    const Opts = struct { verbose: bool = false };
    var iter = SliceIter{ .tokens = &.{"prog"} };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(!r.opts.verbose);
}

test "chip boolean: --flag sets true" {
    const Opts = struct { verbose: bool = false };
    var iter = SliceIter{ .tokens = &.{ "prog", "--verbose" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.opts.verbose);
}

test "chip boolean: --no-flag sets false" {
    const Opts = struct { verbose: bool = true };
    var iter = SliceIter{ .tokens = &.{ "prog", "--no-verbose" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(!r.opts.verbose);
}

test "chip boolean: short flag" {
    const Opts = struct {
        verbose: bool = false,
        pub const shorts = .{ .verbose = 'v' };
    };
    var iter = SliceIter{ .tokens = &.{ "prog", "-v" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.opts.verbose);
}

test "chip boolean: --no- on non-bool returns error" {
    const Opts = struct { port: u16 = 8080 };
    var iter = SliceIter{ .tokens = &.{ "prog", "--no-port" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    try testing.expectError(error.CannotNegate, p.parse());
}

// Integer

test "chip int: parsed correctly" {
    const Opts = struct { port: u16 = 0 };
    var iter = SliceIter{ .tokens = &.{ "prog", "--port", "9090" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqual(@as(u16, 9090), r.opts.port);
}

test "chip int: default used when absent" {
    const Opts = struct { port: u16 = 8080 };
    var iter = SliceIter{ .tokens = &.{"prog"} };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqual(@as(u16, 8080), r.opts.port);
}

test "chip int: short flag" {
    const Opts = struct {
        port: u16 = 0,
        pub const shorts = .{ .port = 'p' };
    };
    var iter = SliceIter{ .tokens = &.{ "prog", "-p", "1000" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqual(@as(u16, 1000), r.opts.port);
}

test "chip int: missing value returns error" {
    const Opts = struct { port: u16 = 0 };
    var iter = SliceIter{ .tokens = &.{ "prog", "--port" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    try testing.expectError(error.MissingValue, p.parse());
}

test "chip int: bad value returns error" {
    const Opts = struct { port: u16 = 0 };
    var iter = SliceIter{ .tokens = &.{ "prog", "--port", "abc" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    try testing.expectError(error.InvalidCharacter, p.parse());
}

// Float

test "chip float: parsed correctly" {
    const Opts = struct { rate: f32 = 0 };
    var iter = SliceIter{ .tokens = &.{ "prog", "--rate", "3.14" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectApproxEqRel(@as(f32, 3.14), r.opts.rate, 1e-5);
}

// String

test "chip string: parsed correctly" {
    const Opts = struct { host: []const u8 = "localhost" };
    var iter = SliceIter{ .tokens = &.{ "prog", "--host", "example.com" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqualStrings("example.com", r.opts.host);
}

test "chip string: default used when absent" {
    const Opts = struct { host: []const u8 = "localhost" };
    var iter = SliceIter{ .tokens = &.{"prog"} };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqualStrings("localhost", r.opts.host);
}

test "chip string: missing value returns error" {
    const Opts = struct { host: []const u8 = "localhost" };
    var iter = SliceIter{ .tokens = &.{ "prog", "--host" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    try testing.expectError(error.MissingValue, p.parse());
}

// Optional

test "chip optional: null when absent" {
    const Opts = struct { name: ?[]const u8 = null };
    var iter = SliceIter{ .tokens = &.{"prog"} };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.opts.name == null);
}

test "chip optional: value when present" {
    const Opts = struct { name: ?[]const u8 = null };
    var iter = SliceIter{ .tokens = &.{ "prog", "--name", "alice" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqualStrings("alice", r.opts.name.?);
}

// String slice

test "chip string slice: consumes multiple values" {
    const Opts = struct { tags: []const []const u8 = &.{} };
    var iter = SliceIter{ .tokens = &.{ "prog", "--tags", "a", "b", "c" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqual(@as(usize, 3), r.opts.tags.len);
    try testing.expectEqualStrings("a", r.opts.tags[0]);
    try testing.expectEqualStrings("b", r.opts.tags[1]);
    try testing.expectEqualStrings("c", r.opts.tags[2]);
}

test "chip string slice: stops at next flag" {
    const Opts = struct { tags: []const []const u8 = &.{}, verbose: bool = false };
    var iter = SliceIter{ .tokens = &.{ "prog", "--tags", "a", "b", "--verbose" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqual(@as(usize, 2), r.opts.tags.len);
    try testing.expect(r.opts.verbose);
}

test "chip string slice: negative numbers not treated as flags" {
    const Opts = struct { vals: []const []const u8 = &.{} };
    var iter = SliceIter{ .tokens = &.{ "prog", "--vals", "-1", "-2.5" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqual(@as(usize, 2), r.opts.vals.len);
    try testing.expectEqualStrings("-1", r.opts.vals[0]);
    try testing.expectEqualStrings("-2.5", r.opts.vals[1]);
}

test "chip string slice: missing value returns error" {
    const Opts = struct { tags: []const []const u8 = &.{} };
    var iter = SliceIter{ .tokens = &.{ "prog", "--tags" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    try testing.expectError(error.MissingValue, p.parse());
}

// Positionals

test "chip positionals: collected in order" {
    const Opts = struct { verbose: bool = false };
    var iter = SliceIter{ .tokens = &.{ "prog", "foo", "bar", "baz" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqual(@as(usize, 3), r.positionals.len);
    try testing.expectEqualStrings("foo", r.positionals[0]);
    try testing.expectEqualStrings("bar", r.positionals[1]);
    try testing.expectEqualStrings("baz", r.positionals[2]);
}

test "chip positionals: mixed with flags" {
    const Opts = struct { verbose: bool = false };
    var iter = SliceIter{ .tokens = &.{ "prog", "foo", "--verbose", "bar" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqual(@as(usize, 2), r.positionals.len);
    try testing.expect(r.opts.verbose);
}

// prog

test "chip prog: captured from argv[0]" {
    const Opts = struct { verbose: bool = false };
    var iter = SliceIter{ .tokens = &.{"myapp"} };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqualStrings("myapp", r.prog);
}

// Unknown options

test "chip unknown: error when allow_unknown=false" {
    const Opts = struct { verbose: bool = false };
    var iter = SliceIter{ .tokens = &.{ "prog", "--typo" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    try testing.expectError(error.UnknownOption, p.parse());
}

test "chip unknown: collected when allow_unknown=true" {
    const Opts = struct {
        verbose: bool = false,
        pub const config = .{ .allow_unknown = true };
    };
    var iter = SliceIter{ .tokens = &.{ "prog", "--typo" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqual(@as(usize, 1), r.unknown_options.len);
    try testing.expectEqualStrings("typo", r.unknown_options[0]);
}

// -- separator

test "chip --: remaining tokens become positionals" {
    const Opts = struct { verbose: bool = false };
    var iter = SliceIter{ .tokens = &.{ "prog", "--verbose", "--", "--not-a-flag", "pos" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.opts.verbose);
    try testing.expectEqual(@as(usize, 2), r.positionals.len);
    try testing.expectEqualStrings("--not-a-flag", r.positionals[0]);
    try testing.expectEqualStrings("pos", r.positionals[1]);
}

// --help

test "chip help: had_help true for --help" {
    const Opts = struct { verbose: bool = false };
    var iter = SliceIter{ .tokens = &.{ "prog", "--help" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.had_help);
}

test "chip help: had_help true for -h" {
    const Opts = struct { verbose: bool = false };
    var iter = SliceIter{ .tokens = &.{ "prog", "-h" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.had_help);
}

test "chip help: false when absent" {
    const Opts = struct { verbose: bool = false };
    var iter = SliceIter{ .tokens = &.{"prog"} };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(!r.had_help);
}

// Error conditions

test "chip already parsed returns error" {
    const Opts = struct { verbose: bool = false };
    var iter = SliceIter{ .tokens = &.{"prog"} };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    _ = try p.parse();
    try testing.expectError(error.AlreadyParsed, p.parse());
}

// Inline key=value syntax

test "chip inline value: --string=value" {
    const Opts = struct { host: []const u8 = "localhost" };
    var iter = SliceIter{ .tokens = &.{ "prog", "--host=example.com" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqualStrings("example.com", r.opts.host);
}

test "chip inline value: --int=value" {
    const Opts = struct { port: u16 = 0 };
    var iter = SliceIter{ .tokens = &.{ "prog", "--port=9090" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqual(@as(u16, 9090), r.opts.port);
}

test "chip inline value: --float=value" {
    const Opts = struct { rate: f32 = 0 };
    var iter = SliceIter{ .tokens = &.{ "prog", "--rate=1.5" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectApproxEqRel(@as(f32, 1.5), r.opts.rate, 1e-5);
}

test "chip inline value: --optional=value" {
    const Opts = struct { name: ?[]const u8 = null };
    var iter = SliceIter{ .tokens = &.{ "prog", "--name=alice" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqualStrings("alice", r.opts.name.?);
}

test "chip inline value: --bool=value returns error" {
    const Opts = struct { verbose: bool = false };
    var iter = SliceIter{ .tokens = &.{ "prog", "--verbose=true" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    try testing.expectError(error.BoolCannotHaveValue, p.parse());
}

test "chip inline value: --slice=first then continues consuming" {
    const Opts = struct { tags: []const []const u8 = &.{} };
    var iter = SliceIter{ .tokens = &.{ "prog", "--tags=a", "b", "c" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqual(@as(usize, 3), r.opts.tags.len);
    try testing.expectEqualStrings("a", r.opts.tags[0]);
    try testing.expectEqualStrings("b", r.opts.tags[1]);
    try testing.expectEqualStrings("c", r.opts.tags[2]);
}

// Combined short flags

test "chip combined shorts: -abc sets all three booleans" {
    const Opts = struct {
        alpha: bool = false,
        beta: bool = false,
        gamma: bool = false,
        pub const shorts = .{ .alpha = 'a', .beta = 'b', .gamma = 'g' };
    };
    var iter = SliceIter{ .tokens = &.{ "prog", "-abg" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.opts.alpha);
    try testing.expect(r.opts.beta);
    try testing.expect(r.opts.gamma);
}

test "chip combined shorts: unknown char in group errors" {
    const Opts = struct {
        alpha: bool = false,
        pub const shorts = .{ .alpha = 'a' };
    };
    var iter = SliceIter{ .tokens = &.{ "prog", "-az" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    try testing.expectError(error.UnknownOption, p.parse());
}

test "chip combined shorts: unknown collected when allow_unknown" {
    const Opts = struct {
        alpha: bool = false,
        pub const shorts = .{ .alpha = 'a' };
        pub const config = .{ .allow_unknown = true };
    };
    var iter = SliceIter{ .tokens = &.{ "prog", "-az" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.opts.alpha);
    try testing.expectEqual(@as(usize, 1), r.unknown_options.len);
    try testing.expectEqualStrings("z", r.unknown_options[0]);
}

// Subcommands (union(enum))

test "chizel subcommand: correct variant is active" {
    const Cmds = union(enum) {
        serve: struct { port: u16 = 8080 },
        build: struct { release: bool = false },
    };
    var iter = SliceIter{ .tokens = &.{ "prog", "serve" } };
    var p = chizelParser(Cmds, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.opts == .serve);
}

test "chizel subcommand: flags parsed into the active variant" {
    const Cmds = union(enum) {
        serve: struct { port: u16 = 8080 },
        build: struct { release: bool = false },
    };
    var iter = SliceIter{ .tokens = &.{ "prog", "serve", "--port", "9090" } };
    var p = chizelParser(Cmds, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqual(@as(u16, 9090), r.opts.serve.port);
}

test "chizel subcommand: default used when flag absent" {
    const Cmds = union(enum) {
        serve: struct { port: u16 = 8080 },
        build: struct { release: bool = false },
    };
    var iter = SliceIter{ .tokens = &.{ "prog", "build" } };
    var p = chizelParser(Cmds, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(!r.opts.build.release);
}

test "chizel subcommand: shorts on subcommand struct" {
    const Cmds = union(enum) {
        serve: struct {
            port: u16 = 8080,
            pub const shorts = .{ .port = 'p' };
        },
    };
    var iter = SliceIter{ .tokens = &.{ "prog", "serve", "-p", "1234" } };
    var p = chizelParser(Cmds, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqual(@as(u16, 1234), r.opts.serve.port);
}

test "chizel subcommand: missing subcommand returns error" {
    const Cmds = union(enum) {
        serve: struct { port: u16 = 8080 },
    };
    var iter = SliceIter{ .tokens = &.{"prog"} };
    var p = chizelParser(Cmds, &iter);
    defer p.deinit();
    try testing.expectError(error.MissingSubcommand, p.parse());
}

test "chizel subcommand: unknown subcommand returns error" {
    const Cmds = union(enum) {
        serve: struct { port: u16 = 8080 },
    };
    var iter = SliceIter{ .tokens = &.{ "prog", "typo" } };
    var p = chizelParser(Cmds, &iter);
    defer p.deinit();
    try testing.expectError(error.UnknownSubcommand, p.parse());
}

test "chizel subcommand: positionals collected" {
    const Cmds = union(enum) {
        run: struct { verbose: bool = false },
    };
    var iter = SliceIter{ .tokens = &.{ "prog", "run", "file1", "file2" } };
    var p = chizelParser(Cmds, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqual(@as(usize, 2), r.positionals.len);
    try testing.expectEqualStrings("file1", r.positionals[0]);
    try testing.expectEqualStrings("file2", r.positionals[1]);
}

test "chizel subcommand: inline --string=value" {
    const Cmds = union(enum) {
        serve: struct { host: []const u8 = "localhost" },
    };
    var iter = SliceIter{ .tokens = &.{ "prog", "serve", "--host=example.com" } };
    var p = chizelParser(Cmds, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqualStrings("example.com", r.opts.serve.host);
}

test "chizel subcommand: inline --int=value" {
    const Cmds = union(enum) {
        serve: struct { port: u16 = 8080 },
    };
    var iter = SliceIter{ .tokens = &.{ "prog", "serve", "--port=9090" } };
    var p = chizelParser(Cmds, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqual(@as(u16, 9090), r.opts.serve.port);
}

test "chizel subcommand: inline --bool=value returns error" {
    const Cmds = union(enum) {
        serve: struct { verbose: bool = false },
    };
    var iter = SliceIter{ .tokens = &.{ "prog", "serve", "--verbose=true" } };
    var p = chizelParser(Cmds, &iter);
    defer p.deinit();
    try testing.expectError(error.BoolCannotHaveValue, p.parse());
}

test "chizel subcommand: -- separator becomes positionals" {
    const Cmds = union(enum) {
        run: struct { verbose: bool = false },
    };
    var iter = SliceIter{ .tokens = &.{ "prog", "run", "--verbose", "--", "--not-a-flag", "pos" } };
    var p = chizelParser(Cmds, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.opts.run.verbose);
    try testing.expectEqual(@as(usize, 2), r.positionals.len);
    try testing.expectEqualStrings("--not-a-flag", r.positionals[0]);
    try testing.expectEqualStrings("pos", r.positionals[1]);
}

test "chizel subcommand: --help sets had_help" {
    const Cmds = union(enum) {
        serve: struct { port: u16 = 8080 },
    };
    var iter = SliceIter{ .tokens = &.{ "prog", "serve", "--help" } };
    var p = chizelParser(Cmds, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.had_help);
}

// Hyphenated long flags

test "chizel hyphen: --dry-run maps to dry_run field" {
    const Opts = struct { dry_run: bool = false };
    var iter = SliceIter{ .tokens = &.{ "prog", "--dry-run" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.opts.dry_run);
}

test "chizel hyphen: --output-file maps to output_file field" {
    const Opts = struct { output_file: []const u8 = "" };
    var iter = SliceIter{ .tokens = &.{ "prog", "--output-file", "out.txt" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqualStrings("out.txt", r.opts.output_file);
}

// CombinedShortRequiresValue

test "chizel combined shorts: non-bool in group returns error" {
    const Opts = struct {
        verbose: bool = false,
        port: u16 = 0,
        pub const shorts = .{ .verbose = 'v', .port = 'p' };
    };
    var iter = SliceIter{ .tokens = &.{ "prog", "-vp" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    try testing.expectError(error.CombinedShortRequiresValue, p.parse());
}

// Float error cases

test "chizel float: missing value returns error" {
    const Opts = struct { rate: f32 = 0 };
    var iter = SliceIter{ .tokens = &.{ "prog", "--rate" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    try testing.expectError(error.MissingValue, p.parse());
}

test "chizel float: bad value returns error" {
    const Opts = struct { rate: f32 = 0 };
    var iter = SliceIter{ .tokens = &.{ "prog", "--rate", "abc" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    try testing.expectError(error.InvalidCharacter, p.parse());
}

// Optional non-string types

test "chizel optional int: null when absent" {
    const Opts = struct { count: ?u32 = null };
    var iter = SliceIter{ .tokens = &.{"prog"} };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.opts.count == null);
}

test "chizel optional int: value when present" {
    const Opts = struct { count: ?u32 = null };
    var iter = SliceIter{ .tokens = &.{ "prog", "--count", "42" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqual(@as(u32, 42), r.opts.count.?);
}

test "chizel optional bool: value when present" {
    const Opts = struct { flag: ?bool = null };
    var iter = SliceIter{ .tokens = &.{ "prog", "--flag" } };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.opts.flag.? == true);
}

// MissingProgramName

test "chizel error: empty iterator returns MissingProgramName" {
    const Opts = struct { verbose: bool = false };
    var iter = SliceIter{ .tokens = &.{} };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    try testing.expectError(error.MissingProgramName, p.parse());
}

// prog basename stripping

test "chizel prog: basename stripped from full path" {
    const Opts = struct { verbose: bool = false };
    var iter = SliceIter{ .tokens = &.{"/usr/local/bin/myapp"} };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expectEqualStrings("myapp", r.prog);
}

// emitParsed smoke tests

test "chizel emitParsed: struct output contains field names" {
    const Opts = struct { port: u16 = 9090, verbose: bool = true };
    var iter = SliceIter{ .tokens = &.{"prog"} };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    const out = try r.emitParsed(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "port") != null);
    try testing.expect(std.mem.indexOf(u8, out, "verbose") != null);
}

test "chizel emitParsed: union output contains subcommand name" {
    const Cmds = union(enum) {
        serve: struct { port: u16 = 8080 },
        build: struct { release: bool = false },
    };
    var iter = SliceIter{ .tokens = &.{ "prog", "serve", "--port", "1234" } };
    var p = chizelParser(Cmds, &iter);
    defer p.deinit();
    const r = try p.parse();
    const out = try r.emitParsed(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "serve") != null);
    try testing.expect(std.mem.indexOf(u8, out, "port") != null);
}

// printHelp smoke tests

test "chizel printHelp: struct output contains flag names" {
    const Opts = struct {
        host: []const u8 = "localhost",
        port: u16 = 8080,
        pub const help = .{ .host = "Server host", .port = "Server port" };
        pub const shorts = .{ .host = 'H', .port = 'p' };
    };
    var iter = SliceIter{ .tokens = &.{"prog"} };
    var p = chipParser(Opts, &iter);
    defer p.deinit();
    const r = try p.parse();
    const out = try r.printHelp(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "--host") != null);
    try testing.expect(std.mem.indexOf(u8, out, "--port") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Server host") != null);
}

test "chizel printHelp: root --help shows subcommand list" {
    const Cmds = union(enum) {
        serve: struct {
            port: u16 = 8080,
            pub const help = .{ ._cmd = "Start the server" };
        },
        build: struct {
            release: bool = false,
            pub const help = .{ ._cmd = "Build the project" };
        },
    };
    var iter = SliceIter{ .tokens = &.{ "prog", "--help" } };
    var p = chizelParser(Cmds, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.had_root_help);
    const out = try r.printHelp(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "serve") != null);
    try testing.expect(std.mem.indexOf(u8, out, "build") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Start the server") != null);
}

test "chizel printHelp: subcommand --help shows subcommand options" {
    const Cmds = union(enum) {
        serve: struct {
            port: u16 = 8080,
            pub const help = .{ ._cmd = "Start the server", .port = "Port to listen on" };
        },
        build: struct {
            release: bool = false,
            pub const help = .{ ._cmd = "Build the project" };
        },
    };
    var iter = SliceIter{ .tokens = &.{ "prog", "serve", "--help" } };
    var p = chizelParser(Cmds, &iter);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(!r.had_root_help);
    const out = try r.printHelp(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "--port") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Port to listen on") != null);
    try testing.expect(std.mem.indexOf(u8, out, "build") == null);
}
