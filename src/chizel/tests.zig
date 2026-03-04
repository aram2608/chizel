const std = @import("std");
const testing = std.testing;
const ArgParser = @import("ArgParser.zig");
const Option = @import("Option.zig");
const Completions = @import("Completions.zig");

// Boolean

test "boolean: absent defaults to not-present" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{"prog"}, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{ .name = "verbose", .tag = .boolean });
    var r = try p.parse();
    defer r.deinit();
    try testing.expect(!r.isPresent("verbose"));
}

test "boolean: present" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{ "prog", "--verbose" }, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{ .name = "verbose", .tag = .boolean });
    var r = try p.parse();
    defer r.deinit();
    try testing.expect(r.isPresent("verbose"));
}

test "boolean: --no-<flag> negation" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{ "prog", "--no-verbose" }, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{ .name = "verbose", .tag = .boolean, .default = .{ .boolean = true } });
    var r = try p.parse();
    defer r.deinit();
    try testing.expect(!r.isPresent("verbose"));
}

test "boolean: short flag" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{ "prog", "-v" }, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{ .name = "verbose", .tag = .boolean, .short = 'v' });
    var r = try p.parse();
    defer r.deinit();
    try testing.expect(r.isPresent("verbose"));
}

// Integer

test "int: parsed correctly" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{ "prog", "--port", "8080" }, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{ .name = "port", .tag = .int });
    var r = try p.parse();
    defer r.deinit();
    try testing.expectEqual(@as(i64, 8080), r.getInt("port").?);
}

test "int: negative value" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{ "prog", "--offset", "-5" }, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{ .name = "offset", .tag = .int });
    var r = try p.parse();
    defer r.deinit();
    try testing.expectEqual(@as(i64, -5), r.getInt("offset").?);
}

test "int: bad value returns error" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{ "prog", "--port", "abc" }, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{ .name = "port", .tag = .int });
    try testing.expectError(error.InvalidCharacter, p.parse());
}

test "int: missing value token returns error" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{ "prog", "--port" }, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{ .name = "port", .tag = .int });
    try testing.expectError(error.MissingValue, p.parse());
}

// Float

test "float: parsed correctly" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{ "prog", "--rate", "3.14" }, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{ .name = "rate", .tag = .float });
    var r = try p.parse();
    defer r.deinit();
    try testing.expectApproxEqRel(@as(f64, 3.14), r.getFloat("rate").?, 1e-9);
}

// String

test "string: parsed correctly" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{ "prog", "--host", "localhost" }, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{ .name = "host", .tag = .string });
    var r = try p.parse();
    defer r.deinit();
    try testing.expectEqualStrings("localhost", r.getString("host").?);
}

test "string: missing value token returns error" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{ "prog", "--host" }, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{ .name = "host", .tag = .string });
    try testing.expectError(error.MissingValue, p.parse());
}

// String slice

test "string_slice: consumes multiple values" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{ "prog", "--tags", "a", "b", "c" }, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{ .name = "tags", .tag = .string_slice });
    var r = try p.parse();
    defer r.deinit();
    const tags = r.getStringSlice("tags").?;
    try testing.expectEqual(@as(usize, 3), tags.len);
    try testing.expectEqualStrings("a", tags[0]);
    try testing.expectEqualStrings("b", tags[1]);
    try testing.expectEqualStrings("c", tags[2]);
}

test "string_slice: stops at next flag" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{ "prog", "--tags", "a", "b", "--verbose" }, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{ .name = "tags", .tag = .string_slice });
    try p.addOption(.{ .name = "verbose", .tag = .boolean });
    var r = try p.parse();
    defer r.deinit();
    const tags = r.getStringSlice("tags").?;
    try testing.expectEqual(@as(usize, 2), tags.len);
    try testing.expect(r.isPresent("verbose"));
}

test "string_slice: negative numbers not treated as flags" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{ "prog", "--vals", "-1", "-2.5" }, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{ .name = "vals", .tag = .string_slice });
    var r = try p.parse();
    defer r.deinit();
    const vals = r.getStringSlice("vals").?;
    try testing.expectEqual(@as(usize, 2), vals.len);
    try testing.expectEqualStrings("-1", vals[0]);
    try testing.expectEqualStrings("-2.5", vals[1]);
}

// Defaults

test "default: used when flag absent" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{"prog"}, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{ .name = "port", .tag = .int, .default = .{ .int = 8080 } });
    var r = try p.parse();
    defer r.deinit();
    try testing.expectEqual(@as(i64, 8080), r.getInt("port").?);
}

test "default: overridden by cli" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{ "prog", "--port", "9090" }, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{ .name = "port", .tag = .int, .default = .{ .int = 8080 } });
    var r = try p.parse();
    defer r.deinit();
    try testing.expectEqual(@as(i64, 9090), r.getInt("port").?);
}

test "default: absent option returns null" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{"prog"}, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{ .name = "host", .tag = .string });
    var r = try p.parse();
    defer r.deinit();
    try testing.expect(r.getString("host") == null);
}

// isPresent semantics

test "isPresent: reflects effective boolean value, not explicit-pass status" {
    // For booleans, isPresent returns the current value of the flag.
    // A default of true means isPresent returns true even without an explicit CLI pass.
    var p = try ArgParser.initFromTokens(testing.allocator, &.{"prog"}, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{ .name = "verbose", .tag = .boolean, .default = .{ .boolean = true } });
    var r = try p.parse();
    defer r.deinit();
    try testing.expect(r.isPresent("verbose")); // default=true → effective value is true
}

test "isPresent: false for default-only non-boolean" {
    // For non-boolean types, isPresent uses count > 0, so a default alone returns false.
    var p = try ArgParser.initFromTokens(testing.allocator, &.{"prog"}, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{ .name = "host", .tag = .string, .default = .{ .string = "localhost" } });
    var r = try p.parse();
    defer r.deinit();
    try testing.expect(!r.isPresent("host"));
}

test "isPresent: true when flag explicitly passed" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{ "prog", "--verbose" }, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{ .name = "verbose", .tag = .boolean });
    var r = try p.parse();
    defer r.deinit();
    try testing.expect(r.isPresent("verbose"));
}

// getCount

test "getCount: zero when absent" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{"prog"}, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{ .name = "verbose", .tag = .boolean });
    var r = try p.parse();
    defer r.deinit();
    try testing.expectEqual(@as(u32, 0), r.getCount("verbose"));
}

test "getCount: increments with each occurrence" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{ "prog", "--verbose", "--verbose", "--verbose" }, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{ .name = "verbose", .tag = .boolean });
    var r = try p.parse();
    defer r.deinit();
    try testing.expectEqual(@as(u32, 3), r.getCount("verbose"));
}

// Positionals

test "positionals: collected in order" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{ "prog", "foo", "bar", "baz" }, .{ .allow_unknown = false });
    defer p.deinit();
    var r = try p.parse();
    defer r.deinit();
    const pos = r.getPositionals();
    try testing.expectEqual(@as(usize, 3), pos.len);
    try testing.expectEqualStrings("foo", pos[0]);
    try testing.expectEqualStrings("bar", pos[1]);
    try testing.expectEqualStrings("baz", pos[2]);
}

test "positionals: mixed with flags" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{ "prog", "foo", "--verbose", "bar" }, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{ .name = "verbose", .tag = .boolean });
    var r = try p.parse();
    defer r.deinit();
    const pos = r.getPositionals();
    try testing.expectEqual(@as(usize, 2), pos.len);
    try testing.expect(r.isPresent("verbose"));
}

// --help / -h

test "help: hadHelp true for --help" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{ "prog", "--help" }, .{ .allow_unknown = false });
    defer p.deinit();
    var r = try p.parse();
    defer r.deinit();
    try testing.expect(r.hadHelp());
}

test "help: hadHelp true for -h" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{ "prog", "-h" }, .{ .allow_unknown = false });
    defer p.deinit();
    var r = try p.parse();
    defer r.deinit();
    try testing.expect(r.hadHelp());
}

test "help: skips required option check" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{ "prog", "--help" }, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{ .name = "must_have", .tag = .string, .required = true });
    var r = try p.parse();
    defer r.deinit();
    try testing.expect(r.hadHelp());
}

// Required options

test "required: satisfied by cli" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{ "prog", "--name", "alice" }, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{ .name = "name", .tag = .string, .required = true });
    var r = try p.parse();
    defer r.deinit();
    try testing.expectEqualStrings("alice", r.getString("name").?);
}

test "required: missing returns error" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{"prog"}, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{ .name = "name", .tag = .string, .required = true });
    try testing.expectError(error.MissingRequiredOption, p.parse());
}

test "required: default alone does not satisfy" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{"prog"}, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{ .name = "port", .tag = .int, .required = true, .default = .{ .int = 8080 } });
    try testing.expectError(error.MissingRequiredOption, p.parse());
}

// Unknown options

test "unknown option: returns error when allow_unknown=false" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{ "prog", "--typo" }, .{ .allow_unknown = false });
    defer p.deinit();
    try testing.expectError(error.UnknownOption, p.parse());
}

test "unknown option: collected when allow_unknown=true" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{ "prog", "--unknown-flag" }, .{ .allow_unknown = true });
    defer p.deinit();
    var r = try p.parse();
    defer r.deinit();
    var buf = std.Io.Writer.Allocating.init(testing.allocator);
    errdefer buf.deinit();
    try p.dumpUnknown(&buf.writer);
    const out = try buf.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "unknown-flag") != null);
}

// Error conditions

test "already parsed returns error" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{"prog"}, .{ .allow_unknown = false });
    defer p.deinit();
    var r = try p.parse();
    defer r.deinit();
    try testing.expectError(error.AlreadyParsed, p.parse());
}

test "duplicate option returns error" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{"prog"}, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{ .name = "port", .tag = .int });
    try testing.expectError(error.DuplicateOption, p.addOption(.{ .name = "port", .tag = .int }));
}

test "reserved option name 'help'" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{"prog"}, .{ .allow_unknown = false });
    defer p.deinit();
    try testing.expectError(error.ReservedOptionName, p.addOption(.{ .name = "help", .tag = .boolean }));
}

test "reserved short flag 'h'" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{"prog"}, .{ .allow_unknown = false });
    defer p.deinit();
    try testing.expectError(error.ReservedShortFlag, p.addOption(.{ .name = "foo", .tag = .boolean, .short = 'h' }));
}

test "invalid short flag (non-alphanumeric)" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{"prog"}, .{ .allow_unknown = false });
    defer p.deinit();
    try testing.expectError(error.InvalidShortFlag, p.addOption(.{ .name = "foo", .tag = .boolean, .short = '!' }));
}

test "string_slice default not supported" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{"prog"}, .{ .allow_unknown = false });
    defer p.deinit();
    const dummy: [][]const u8 = &.{};
    try testing.expectError(error.StringSliceDefaultNotSupported, p.addOption(.{
        .name = "tags",
        .tag = .string_slice,
        .default = .{ .string_slice = dummy },
    }));
}

// Validation

test "validation: passes when callback returns true" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{ "prog", "--port", "8080" }, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{
        .name = "port",
        .tag = .int,
        .validate = struct {
            fn check(v: Option.Value) bool {
                return v.int > 0 and v.int < 65536;
            }
        }.check,
    });
    var r = try p.parse();
    defer r.deinit();
    try testing.expectEqual(@as(i64, 8080), r.getInt("port").?);
}

test "validation: fails when callback returns false" {
    var p = try ArgParser.initFromTokens(testing.allocator, &.{ "prog", "--port", "99999" }, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{
        .name = "port",
        .tag = .int,
        .validate = struct {
            fn check(v: Option.Value) bool {
                return v.int > 0 and v.int < 65536;
            }
        }.check,
    });
    try testing.expectError(error.ValidationFailed, p.parse());
}

test "validation: default is not validated when cli value is provided" {
    // Regression test for the bug where the default was always validated even
    // when a CLI value was provided.  A default of 0 fails the >0 check, but
    // the CLI value 8080 is valid — parse() must succeed.
    var p = try ArgParser.initFromTokens(testing.allocator, &.{ "prog", "--port", "8080" }, .{ .allow_unknown = false });
    defer p.deinit();
    try p.addOption(.{
        .name = "port",
        .tag = .int,
        .default = .{ .int = 0 }, // would fail the validator
        .validate = struct {
            fn check(v: Option.Value) bool {
                return v.int > 0;
            }
        }.check,
    });
    var r = try p.parse();
    defer r.deinit();
    try testing.expectEqual(@as(i64, 8080), r.getInt("port").?);
}

// Completions

test "fish completion: contains program name and flag names" {
    var comp = try Completions.init(testing.allocator, "myapp");
    defer comp.deinit();
    try comp.addOption(.{ .name = "verbose", .tag = .boolean, .short = 'v', .help = "Enable verbose output" });
    try comp.addOption(.{ .name = "port", .tag = .int, .help = "Port number" });
    const script = try comp.createAutoCompletion(.fish);
    defer testing.allocator.free(script);
    try testing.expect(std.mem.indexOf(u8, script, "myapp") != null);
    try testing.expect(std.mem.indexOf(u8, script, "verbose") != null);
    try testing.expect(std.mem.indexOf(u8, script, "port") != null);
    try testing.expect(std.mem.indexOf(u8, script, "-s v") != null); // fish short-flag syntax
}

test "bash completion: contains program name and flag names" {
    var comp = try Completions.init(testing.allocator, "myapp");
    defer comp.deinit();
    try comp.addOption(.{ .name = "verbose", .tag = .boolean, .help = "Enable verbose output" });
    try comp.addOption(.{ .name = "host", .tag = .string, .short = 'H', .help = "Host name" });
    const script = try comp.createAutoCompletion(.bash);
    defer testing.allocator.free(script);
    try testing.expect(std.mem.indexOf(u8, script, "myapp") != null);
    try testing.expect(std.mem.indexOf(u8, script, "--verbose") != null);
    try testing.expect(std.mem.indexOf(u8, script, "--host") != null);
}

test "zsh completion: contains program name and flag names" {
    var comp = try Completions.init(testing.allocator, "myapp");
    defer comp.deinit();
    try comp.addOption(.{ .name = "output", .tag = .string, .help = "Output file path" });
    const script = try comp.createAutoCompletion(.zsh);
    defer testing.allocator.free(script);
    try testing.expect(std.mem.indexOf(u8, script, "myapp") != null);
    try testing.expect(std.mem.indexOf(u8, script, "output") != null);
}
