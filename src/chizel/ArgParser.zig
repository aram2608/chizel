//! ArgParser — registers options and parses `argv` into a `ParseResult`.
//!
//! ## Typical usage
//!
//! ```zig
//! var args = try std.process.ArgIterator.initWithAllocator(allocator);
//! defer args.deinit();
//!
//! var parser = try ArgParser.init(allocator, args);
//! defer parser.deinit();
//!
//! try parser.addOption(.{ .name = "verbose", .tag = .boolean, .short = 'v' });
//! try parser.addOption(.{ .name = "port",    .tag = .int,     .default = .{ .int = 8080 } });
//!
//! var result = try parser.parse();
//! defer result.deinit();
//! ```
//!
//! Call `parse()` exactly once.  `deinit()` must be called *after* the
//! corresponding `ParseResult.deinit()` because `string` and `string_slice`
//! values in the result point into the process argv or environment block.

const std = @import("std");
const ArgIterator = std.process.ArgIterator;
const Allocator = std.mem.Allocator;
const ParseResult = @import("ParseResult.zig");
const Option = @import("Option.zig");
const Parser = @This();
const OptionsMap = std.StringHashMap(Option);
const startsWith = std.mem.startsWith;
const isAlphanumeric = std.ascii.isAlphanumeric;
const isAlphabetic = std.ascii.isAlphabetic;
const eqlIgnoreCase = std.ascii.eqlIgnoreCase;

/// A slice-backed token source used by `initFromTokens` for tests.
const SliceIter = struct {
    tokens: []const []const u8,
    index: usize,

    fn next(self: *SliceIter) ?[]const u8 {
        if (self.index >= self.tokens.len) return null;
        defer self.index += 1;
        return self.tokens[self.index];
    }
};

/// Union over the two possible token sources: a real `ArgIterator` (production)
/// or a slice (tests / `initFromTokens`).
const ArgsSource = union(enum) {
    iter: ArgIterator,
    slice: SliceIter,

    fn next(self: *ArgsSource) ?[]const u8 {
        return switch (self.*) {
            .iter => |*it| it.next(),
            .slice => |*it| it.next(),
        };
    }
};

pub const ParserConfig = struct {
    allow_unknown: bool,
};

gpa: Allocator,
options: OptionsMap,
short_map: std.AutoHashMap(u8, []const u8),
args: ArgsSource,
/// One-token lookahead used by `parseStringSlice` to put back a flag token.
peek: ?[]const u8 = null,
program_name: []const u8 = "",
option_order: std.ArrayList([]const u8) = .empty,
allow_unknown: bool = false,
unknown_options: std.ArrayList([]const u8) = .empty,
parsed: bool = false,

/// Create a parser from a `std.process.ArgIterator`.
///
/// `args` is taken by value.  `argv[0]` is consumed immediately as the
/// program name.  The remaining tokens are left in the iterator for `parse()`.
/// Do not call `args.next()` after passing it here.  Continue to call
/// `args.deinit()` via `defer` in the caller — it is safe to deinit an
/// exhausted iterator.
///
/// The caller must keep `gpa` alive for the lifetime of both this parser and
/// any `ParseResult` it produces.
pub fn init(gpa: Allocator, args: ArgIterator, config: ParserConfig) !Parser {
    var mut_args = args;
    const name = mut_args.next().?; // consume argv[0]
    return .{
        .gpa = gpa,
        .program_name = try gpa.dupe(u8, name),
        .allow_unknown = config.allow_unknown,
        .args = .{ .iter = mut_args },
        .options = OptionsMap.init(gpa),
        .short_map = std.AutoHashMap(u8, []const u8).init(gpa),
    };
}

/// Create a parser from a slice of pre-tokenized strings.
///
/// `tokens[0]` is used as the program name (`argv[0]`).  `tokens[1..]` are
/// the arguments to be parsed.  This is the preferred constructor for tests
/// because it avoids `std.process.ArgIterator` entirely.
///
/// Example:
/// ```zig
/// var parser = try ArgParser.initFromTokens(allocator,
///     &.{ "myapp", "--port", "8080" },
///     .{ .allow_unknown = false });
/// ```
pub fn initFromTokens(gpa: Allocator, tokens: []const []const u8, config: ParserConfig) !Parser {
    const name: []const u8 = if (tokens.len > 0) tokens[0] else "";
    const rest: []const []const u8 = if (tokens.len > 1) tokens[1..] else &.{};
    return .{
        .gpa = gpa,
        .program_name = try gpa.dupe(u8, name),
        .allow_unknown = config.allow_unknown,
        .args = .{ .slice = .{ .tokens = rest, .index = 0 } },
        .options = OptionsMap.init(gpa),
        .short_map = std.AutoHashMap(u8, []const u8).init(gpa),
    };
}

/// Free all resources owned by the parser.
///
/// Must be called *after* `ParseResult.deinit()` for any result produced by
/// this parser.
///
/// The typical pattern using `defer` is safe by default because `defer`
/// unwinds in reverse order:
///
/// ```zig
/// var parser = try ArgParser.init(allocator, args);
/// defer parser.deinit();        // deferred first, runs last
///
/// var result = try parser.parse();
/// defer result.deinit();        // deferred second, runs first ✓
/// ```
pub fn deinit(self: *Parser) void {
    self.gpa.free(self.program_name);
    self.option_order.deinit(self.gpa);
    self.options.deinit();
    self.unknown_options.deinit(self.gpa);
    self.short_map.deinit();
}

/// Register a command-line option before calling `parse()`.
///
/// Options are printed in registration order by `printHelp()`.  Call
/// `addOption` for every flag your program accepts, then call `parse()` once.
///
/// `config.name` becomes the long flag (`--name`).  `config.short`, when set,
/// provides a single-character alias (`-c`).  See `Option.Config` for the full
/// set of fields.
///
/// Errors:
/// - `error.ReservedOptionName`             — `"help"` is built-in; register it and `parse()` will error.
/// - `error.DuplicateOption`                — `config.name` was already registered.
/// - `error.StringSliceDefaultNotSupported` — defaults for `.string_slice` options are not supported;
///                                            use `getStringSlice("x") orelse &.{...}` at the call site.
pub fn addOption(self: *Parser, config: Option.Config) !void {
    if (std.mem.eql(u8, config.name, "help")) return error.ReservedOptionName;

    if (self.options.contains(config.name)) return error.DuplicateOption;
    if (config.default) |d| {
        if (d == .string_slice) return error.StringSliceDefaultNotSupported;
    }

    if (config.short) |s| {
        if (!std.ascii.isAlphanumeric(s)) return error.InvalidShortFlag;
        if (s == 'h') return error.ReservedShortFlag;
        try self.short_map.put(s, config.name);
    }

    try self.option_order.append(self.gpa, config.name);
    try self.options.put(config.name, .{
        .tag = config.tag,
        .help = config.help,
        .short = config.short,
        .required = config.required,
        .env = config.env,
        .validate = config.validate,
        .default = config.default,
    });
}

/// Parse the argument iterator and return a `ParseResult`.
///
/// May only be called once.  Register all options with `addOption` first.
///
/// ## Value resolution order
///
/// For each option, the first source that provides a value wins:
///
///   1. CLI flag (`--name value` or `-s value`)
///   2. Environment variable (`Option.Config.env`)
///   3. Static default (`Option.Config.default`)
///
/// `required` is satisfied only by a CLI flag or an env-var fallback.
/// A `default` alone does not satisfy `required`.
///
/// ## `--help` behaviour
///
/// When `--help` (or `-h`) appears anywhere in argv, `parse()` still succeeds
/// and returns a result where `hadHelp()` is `true`.  Required-option checks
/// are skipped so that the caller can always print help without supplying every
/// flag.  Check `hadHelp()` before reading any other values.
///
/// ## Errors
///
/// - `error.AlreadyParsed`         — `parse()` was called more than once on this parser.
/// - `error.MissingValue`          — a non-boolean option appeared without a following value.
/// - `error.ValidationFailed`      — a `validate` callback returned `false`.
/// - `error.MissingRequiredOption` — a `required` option was absent from CLI and env.
///                                   Not returned when `--help` was passed.
pub fn parse(self: *Parser) !ParseResult {
    if (self.parsed) return error.AlreadyParsed;
    self.parsed = true;
    var parse_result = ParseResult.init(self.gpa);
    errdefer parse_result.deinit();

    while (self.nextArg()) |arg| {
        if (std.mem.eql(u8, arg, "--")) {
            while (self.nextArg()) |pos| try parse_result.positionals.append(self.gpa, pos);
            break;
        }
        if (startsWith(u8, arg, "--")) {
            var key = arg[2..];

            if (std.mem.eql(u8, key, "help")) {
                parse_result.had_help = true;
                continue;
            }

            const is_negated = startsWith(u8, key, "no-");
            if (is_negated) key = key[3..];

            const parse_attempt = self.options.getPtr(key);
            if (parse_attempt) |option| {
                if (is_negated and option.tag != .boolean) {
                    _ = try self.parsePayload(option.tag, false);
                    try self.unknown_options.append(self.gpa, key);
                    continue;
                }
                option.count += 1;
                const value = try self.parsePayload(option.tag, is_negated);

                if (option.validate) |validate_fn| {
                    if (!validate_fn(value)) return error.ValidationFailed;
                }

                // When an option is passed more than once the previous slice
                // needs to get removed from memory.
                if (parse_result.results.get(key)) |old| {
                    if (old.value == .string_slice) self.gpa.free(old.value.string_slice);
                }
                try parse_result.results.put(key, .{ .value = value, .count = option.count });
            } else {
                if (self.allow_unknown)
                    try self.unknown_options.append(self.gpa, key)
                else
                    return error.UnknownOption;
            }
        } else if (startsWith(u8, arg, "-") and arg.len == 2 and isAlphanumeric(arg[1])) {
            const short_char = arg[1];
            if (short_char == 'h') {
                parse_result.had_help = true;
                continue;
            }
            if (self.short_map.get(short_char)) |long_name| {
                const option = self.options.getPtr(long_name).?;
                option.count += 1;
                const value = try self.parsePayload(option.tag, false);

                if (option.validate) |validate_fn| {
                    if (!validate_fn(value)) return error.ValidationFailed;
                }

                if (parse_result.results.get(long_name)) |old| {
                    if (old.value == .string_slice) self.gpa.free(old.value.string_slice);
                }
                try parse_result.results.put(long_name, .{ .value = value, .count = option.count });
            } else {
                if (self.allow_unknown)
                    try self.unknown_options.append(self.gpa, arg[1..])
                else
                    return error.UnknownOption;
            }
        } else {
            try parse_result.positionals.append(self.gpa, arg);
        }
    }

    // Apply env-var fallbacks and static defaults for options not on the CLI.
    var opt_iter = self.options.iterator();
    while (opt_iter.next()) |entry| {
        const name = entry.key_ptr.*;
        const option = entry.value_ptr;
        if (parse_result.results.contains(name)) continue;

        // Env vars have lower priority than CLI but higher than defaults.
        if (option.env) |env_key| {
            if (std.posix.getenv(env_key)) |env_val| {
                const value = try parseEnvValue(self.gpa, option.tag, env_val);
                if (option.validate) |validate_fn| {
                    if (!validate_fn(value)) return error.ValidationFailed;
                }
                try parse_result.results.put(name, .{ .value = value, .count = 1 });
                continue;
            }
        }

        if (option.default) |default_val| {
            try parse_result.results.put(name, .{ .value = default_val, .count = 0 });
        }
    }

    // Verify all required options were satisfied (defaults do not count;
    // must be passed via CLI or env var).  Skip when --help was requested
    // so the user can always see usage without supplying every required flag.
    if (!parse_result.hadHelp()) {
        var req_iter = self.options.iterator();
        while (req_iter.next()) |entry| {
            if (!entry.value_ptr.required) continue;
            const result = parse_result.results.get(entry.key_ptr.*);
            if (result == null or result.?.count == 0) return error.MissingRequiredOption;
        }
    }

    parse_result.help_message = try self.buildHelpMessage();
    return parse_result;
}

/// Return the next token from the iterator, checking the one-token lookahead
/// buffer first.
fn nextArg(self: *Parser) ?[]const u8 {
    if (self.peek) |token| {
        self.peek = null;
        return token;
    }
    return self.args.next();
}

fn parsePayload(self: *Parser, tag: Option.Tag, negated: bool) !Option.Value {
    return switch (tag) {
        .boolean => .{ .boolean = !negated },
        .int => .{ .int = try self.parseInt() },
        .float => .{ .float = try self.parseFloat() },
        .string => .{ .string = try self.parseString() },
        .string_slice => .{ .string_slice = try self.parseStringSlice() },
    };
}

fn parseString(self: *Parser) ![]const u8 {
    const arg = self.nextArg() orelse return error.MissingValue;
    if (arg.len == 0) return error.MissingValue;
    return arg;
}

fn parseInt(self: *Parser) !i64 {
    const arg = self.nextArg() orelse return error.MissingValue;
    return std.fmt.parseInt(i64, arg, 10);
}

fn parseFloat(self: *Parser) !f64 {
    const arg = self.nextArg() orelse return error.MissingValue;
    return std.fmt.parseFloat(f64, arg);
}

fn parseStringSlice(self: *Parser) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(self.gpa);

    // Consume tokens until end of args or a token that looks like a new flag.
    // looksLikeOptionToken() permits values such as "-1" or "-3.14" to be
    // part of the slice while still stopping on "--flag" or "-f".
    while (self.nextArg()) |token| {
        if (looksLikeOptionToken(token)) {
            self.peek = token; // put it back for the outer parse loop
            break;
        }
        try list.append(self.gpa, token);
    }

    if (list.items.len == 0) return error.MissingValue;
    return list.toOwnedSlice(self.gpa);
}

/// Returns true when `token` looks like the start of a flag (`--anything` or
/// `-<alpha>`).  Values such as `-1` or `-3.14` return false, so they are not
/// mistakenly treated as option starters in string-slice parsing.
fn looksLikeOptionToken(token: []const u8) bool {
    if (!startsWith(u8, token, "-") or token.len < 2) return false;
    return token[1] == '-' or isAlphabetic(token[1]);
}

fn parseEnvValue(gpa: Allocator, tag: Option.Tag, raw: []const u8) !Option.Value {
    return switch (tag) {
        .boolean => .{ .boolean = eqlIgnoreCase(raw, "1") or
            eqlIgnoreCase(raw, "true") or
            eqlIgnoreCase(raw, "yes") },
        .int => .{ .int = try std.fmt.parseInt(i64, raw, 10) },
        .float => .{ .float = try std.fmt.parseFloat(f64, raw) },
        .string => .{ .string = raw }, // env block is valid for the process lifetime
        .string_slice => blk: {
            var list: std.ArrayList([]const u8) = .empty;
            errdefer list.deinit(gpa);
            var it = std.mem.splitScalar(u8, raw, ' ');
            while (it.next()) |part| {
                if (part.len > 0) try list.append(gpa, part);
            }
            break :blk .{ .string_slice = try list.toOwnedSlice(gpa) };
        },
    };
}

fn buildHelpMessage(self: *Parser) ![]u8 {
    const prog = std.fs.path.basename(self.program_name);
    const prefix = "--";
    const col_gap: usize = 2;
    // Short-flag column: "-s, " (4 chars) or "    " (4-space padding).
    const short_col: usize = 4;

    var buff = std.Io.Writer.Allocating.init(self.gpa);
    errdefer buff.deinit();

    try buff.writer.print("Usage: {s} [OPTIONS]\nOptions:\n", .{prog});

    // Seed with the built-in --help so it is included in alignment calculations.
    var max_left: usize = short_col + prefix.len + "help".len;
    for (self.option_order.items) |name| {
        const opt = self.options.get(name).?;
        const hint = typeHint(opt.tag);
        const left = short_col + prefix.len + name.len + if (hint.len > 0) 1 + hint.len else 0;
        if (left > max_left) max_left = left;
    }

    for (self.option_order.items) |name| {
        const opt = self.options.get(name).?;
        const hint = typeHint(opt.tag);
        var left: usize = short_col + prefix.len + name.len;

        if (opt.short) |s| {
            try buff.writer.print("-{c}, ", .{s});
        } else {
            try buff.writer.print("    ", .{});
        }

        try buff.writer.print("{s}{s}", .{ prefix, name });
        if (hint.len > 0) {
            try buff.writer.print(" {s}", .{hint});
            left += 1 + hint.len;
        }
        try buff.writer.splatByteAll(' ', max_left - left + col_gap);
        try buff.writer.print("{s}", .{opt.help});

        if (opt.required) try buff.writer.print(" (required)", .{});
        if (opt.env) |env_key| try buff.writer.print(" [${s}]", .{env_key});
        if (opt.default) |d| {
            switch (d) {
                .boolean => |v| try buff.writer.print(" (default: {})", .{v}),
                .int => |v| try buff.writer.print(" (default: {})", .{v}),
                .float => |v| try buff.writer.print(" (default: {})", .{v}),
                .string => |v| try buff.writer.print(" (default: {s})", .{v}),
                .string_slice => {}, // guarded against in addOption
            }
        }
        try buff.writer.print("\n", .{});
    }

    // --help is always listed last.
    const help_left = short_col + prefix.len + "help".len;
    try buff.writer.print("    {s}help", .{prefix});
    try buff.writer.splatByteAll(' ', max_left - help_left + col_gap);
    try buff.writer.print("Print this help message\n", .{});

    return buff.toOwnedSlice();
}

fn typeHint(tag: Option.Tag) []const u8 {
    return switch (tag) {
        .boolean => "",
        .int => "<int>",
        .float => "<float>",
        .string => "<string>",
        .string_slice => "<string...>",
    };
}

/// Write each unrecognised flag name to `writer`, one per line.
///
/// An option is "unknown" when its name was not registered with `addOption`.
/// Unknown options are silently collected rather than causing `parse()` to
/// error, so call this after `parse()` to detect typos or unsupported flags.
///
/// Output format: `Unknown opt: <name>\n`
pub fn dumpUnknown(self: *const Parser, writer: anytype) !void {
    for (self.unknown_options.items) |name| {
        try writer.print("Unknown opt: {s}\n", .{name});
    }
}

/// Write each registered option name and its value type to `writer`, one per line.
///
/// Intended for debugging.  Options are printed in registration order.
///
/// Output format: `Key: <name> || Tag: <tag>\n`
pub fn dumpOptions(self: *const Parser, writer: anytype) !void {
    for (self.option_order.items) |name| {
        const opt = self.options.get(name).?;
        try writer.print("Key: {s} || Tag: {s}\n", .{ name, @tagName(opt.tag) });
    }
}
