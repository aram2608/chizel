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
//! values in the result point into the parser's internal buffer.

const std = @import("std");
const ArgIterator = std.process.ArgIterator;
const Allocator = std.mem.Allocator;
const ParseResult = @import("ParseResult.zig");
const Option = @import("Option.zig");
const Parser = @This();
const OptionsMap = std.StringHashMap(Option);
const startsWith = std.mem.startsWith;

const NegationState = enum {
    none,
    negate,
};

gpa: Allocator,
options: OptionsMap,
short_map: std.AutoHashMap(u8, []const u8),
buffer: []const u8,
start: usize = 0,
current: usize = 0,
program_name: []const u8 = "",
option_order: std.ArrayList([]const u8) = .empty,
unknown_options: std.ArrayList([]const u8) = .empty,
parsed: bool = false,
negate: NegationState = .none,

/// Create a parser from a `std.process.ArgIterator`.
///
/// `args` is taken by value and fully consumed: `argv[0]` is stored as the
/// program name, and the remaining tokens are joined into a single internal
/// buffer separated by spaces.  Do not call `args.next()` after passing it
/// here; the iterator is exhausted.  Continue to call `args.deinit()` via
/// `defer` in the caller — it is safe to deinit an exhausted iterator.
///
/// The caller must keep `gpa` alive for the lifetime of both this parser and
/// any `ParseResult` it produces.
///
/// Returns `error.ArgumentBufferOverflow` when the joined argument string
/// (all tokens plus one separator byte per token) exceeds 4096 bytes.
pub fn init(gpa: Allocator, args: ArgIterator) !Parser {
    var temp: [4096]u8 = undefined;
    var pos: usize = 0;
    var temp_args = args;
    const name = temp_args.next().?; // argv[0]

    while (temp_args.next()) |arg| {
        if (pos + arg.len + 1 > temp.len) return error.ArgumentBufferOverflow;
        @memcpy(temp[pos..][0..arg.len], arg);
        temp[pos + arg.len] = ' ';
        pos += arg.len + 1;
    }
    return .{
        .gpa = gpa,
        .program_name = try gpa.dupe(u8, name),
        .buffer = try gpa.dupe(u8, temp[0..pos]),
        .options = OptionsMap.init(gpa),
        .short_map = std.AutoHashMap(u8, []const u8).init(gpa),
    };
}

/// Free all resources owned by the parser.
///
/// Must be called *after* `ParseResult.deinit()` for any result produced by
/// this parser, because `string` and `string_slice` values in the result are
/// slices into the parser's internal buffer.  Freeing the parser first leaves
/// those slices dangling.
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
    self.gpa.free(self.buffer);
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

/// Parse the argument buffer and return a `ParseResult`.
///
/// May only be called once.  Register all options with `addOption` first.
///
/// ## Value resolution order
///
/// For each option, the first source that provides a value wins:
///
///   1. CLI flag (`--name value`)
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

    while (!self.isEnd()) {
        self.start = self.current;
        const c = self.advance();

        if (c == ' ') continue;

        if (c == '-') {
            var key = self.parseOption();

            // Resolve short options
            if (key.len == 1) {
                if (self.short_map.get(key[0])) |long_name| {
                    key = long_name;
                }
            }

            // Help is always reserved
            if (std.mem.eql(u8, key, "help")) {
                parse_result.had_help = true;
                continue;
            }

            const is_negated = startsWith(u8, key, "no-");
            if (is_negated) key = key[3..];

            const parse_attempt = self.options.getPtr(key);
            if (parse_attempt) |option| {
                if (is_negated and option.tag != .boolean) {
                    try self.unknown_options.append(self.gpa, key);
                    continue;
                }
                if (is_negated) self.negate = .negate;
                option.count += 1;
                // Non-boolean options require a space then their value.
                if (option.tag != .boolean) {
                    if (self.isEnd() or self.buffer[self.current] != ' ') return error.MissingValue;
                    _ = self.advance(); // skip the space
                }
                self.start = self.current;
                const value = try self.parsePayload(option.tag);

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
                try self.unknown_options.append(self.gpa, key);
            }
        } else {
            // collect the rest of the token.
            while (!self.isEnd() and !self.checkBuffer(' ')) {
                _ = self.advance();
            }
            try parse_result.positionals.append(self.gpa, self.buffer[self.start..self.current]);
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

fn advance(self: *Parser) u8 {
    if (self.isEnd()) return 0;
    const c: u8 = self.buffer[self.current];
    self.current += 1;
    return c;
}

/// Advance past all characters of an option name and return the name slice
/// with its leading dash(es) stripped.
fn parseOption(self: *Parser) []const u8 {
    while (!self.isEnd() and !self.checkBuffer(' ')) {
        _ = self.advance();
    }
    const prefix_len: usize =
        if (self.start + 1 < self.buffer.len and self.buffer[self.start + 1] == '-') 2 else 1;
    return self.buffer[self.start + prefix_len .. self.current];
}

fn parsePayload(self: *Parser, tag: Option.Tag) !Option.Value {
    return switch (tag) {
        .boolean => .{ .boolean = self.parseBool() },
        .int => .{ .int = try self.parseInt() },
        .float => .{ .float = try self.parseFloat() },
        .string => .{ .string = try self.parseString() },
        .string_slice => .{ .string_slice = try self.parseStringSlice() },
    };
}

fn parseBool(self: *Parser) bool {
    const result = switch (self.negate) {
        .negate => false,
        .none => true,
    };
    self.negate = .none;
    return result;
}

fn parseString(self: *Parser) ![]const u8 {
    const arg = self.nextToken();
    if (arg.len == 0) return error.MissingValue;
    return arg;
}

fn parseInt(self: *Parser) !i64 {
    return std.fmt.parseInt(i64, self.nextToken(), 10);
}

fn parseFloat(self: *Parser) !f64 {
    return std.fmt.parseFloat(f64, self.nextToken());
}

fn parseStringSlice(self: *Parser) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(self.gpa);

    // Collect tokens until end of buffer or something that looks like a new
    // flag.  looksLikeOption() permits values such as "-1" or "-3.14" to be
    // part of the slice while still stopping on "--flag" or "-f".
    while (!self.isEnd() and !self.looksLikeOption()) {
        self.start = self.current;
        const token = self.nextToken();
        if (token.len > 0) try list.append(self.gpa, token);
        if (!self.isEnd()) _ = self.advance(); // skip the trailing space
    }

    if (list.items.len == 0) return error.MissingValue;
    return list.toOwnedSlice(self.gpa);
}

fn nextToken(self: *Parser) []const u8 {
    while (!self.isEnd() and !self.checkBuffer(' ')) {
        _ = self.advance();
    }
    return self.buffer[self.start..self.current];
}

fn checkBuffer(self: *const Parser, c: u8) bool {
    return self.peekBuffer() == c;
}

fn peekBuffer(self: *const Parser) u8 {
    if (self.current >= self.buffer.len) return 0;
    return self.buffer[self.current];
}

fn isEnd(self: *const Parser) bool {
    return self.current >= self.buffer.len;
}

/// Returns true when the current position looks like the start of a flag
/// (`--anything` or `-<alpha>`).  Values such as `-1` or `-3.14` return false,
/// so they are not mistakenly treated as option starters in string-slice parsing.
fn looksLikeOption(self: *const Parser) bool {
    if (self.current >= self.buffer.len) return false;
    if (self.buffer[self.current] != '-') return false;
    if (self.current + 1 >= self.buffer.len) return false;
    const next = self.buffer[self.current + 1];
    return next == '-' or std.ascii.isAlphabetic(next);
}

fn parseEnvValue(gpa: Allocator, tag: Option.Tag, raw: []const u8) !Option.Value {
    return switch (tag) {
        .boolean => .{ .boolean = std.mem.eql(u8, raw, "1") or
            std.mem.eql(u8, raw, "true") or
            std.mem.eql(u8, raw, "yes") },
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

pub fn createAutoCompletion(self: *Parser, target: AutoCompTarget) !void {
    return switch (target) {
        .fish => self.createFishCompletion(),
        .bash => self.createBashCompletion(),
        .zsh => self.createZshCompletion(),
    };
}

fn createBashCompletion(self: *Parser) !void {
    const prog = std.fs.path.basename(self.program_name);
    var buff = std.Io.Writer.Allocating.init(self.gpa);
    defer buff.deinit();

    try buff.writer.print("# Source this in ~/.bashrc or place in /etc/bash_completion.d/{s}\n", .{prog});
    try buff.writer.print("_{s}() {{\n", .{prog});
    try buff.writer.print("    local cur prev opts\n", .{});
    try buff.writer.print("    _init_completion || return\n", .{});

    try buff.writer.print("    opts=\"--help -h", .{});
    for (self.option_order.items) |name| {
        const opt = self.options.get(name).?;
        try buff.writer.print(" --{s}", .{name});
        if (opt.short) |s| try buff.writer.print(" -{c}", .{s});
    }
    try buff.writer.print("\"\n", .{});

    try buff.writer.print("    case \"$prev\" in\n", .{});
    for (self.option_order.items) |name| {
        const opt = self.options.get(name).?;
        switch (opt.tag) {
            .float, .int, .string, .string_slice => {
                if (opt.short) |s| {
                    try buff.writer.print("        --{s}|-{c})\n", .{ name, s });
                } else {
                    try buff.writer.print("        --{s})\n", .{name});
                }
                try buff.writer.print("            return ;;\n", .{});
            },
            .boolean => continue,
        }
    }
    try buff.writer.print("    esac\n", .{});

    try buff.writer.print("    COMPREPLY=($(compgen -W \"$opts\" -- \"$cur\"))\n", .{});
    try buff.writer.print("}}\n", .{});
    try buff.writer.print("complete -F _{s} {s}\n", .{ prog, prog });

    var name_buf: [256]u8 = undefined;
    const filename = try std.fmt.bufPrint(&name_buf, "{s}.bash", .{prog});
    const file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();

    const temp = try buff.toOwnedSlice();
    defer self.gpa.free(temp);
    try file.writeAll(temp);
}

fn createFishCompletion(self: *Parser) !void {
    const prog = std.fs.path.basename(self.program_name);
    var buff = std.Io.Writer.Allocating.init(self.gpa);
    defer buff.deinit();

    try buff.writer.print("# ~/.config/fish/completions/{s}.fish\n", .{prog});

    for (self.option_order.items) |name| {
        const opt = self.options.get(name).?;
        // -f disables file completion for the flag itself.
        // -r additionally marks that the option requires an argument.
        const kind: []const u8 = if (opt.tag == .boolean) "-f" else "-r -f";
        if (opt.short) |s| {
            try buff.writer.print("complete -c {s} -s {c} -l {s} {s} -d \"{s}\"\n", .{ prog, s, name, kind, opt.help });
        } else {
            try buff.writer.print("complete -c {s} -l {s} {s} -d \"{s}\"\n", .{ prog, name, kind, opt.help });
        }
    }
    try buff.writer.print("complete -c {s} -s h -l help -f -d \"Print help\"\n", .{prog});

    var name_buf: [256]u8 = undefined;
    const filename = try std.fmt.bufPrint(&name_buf, "{s}.fish", .{prog});
    const file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();

    const temp = try buff.toOwnedSlice();
    defer self.gpa.free(temp);
    try file.writeAll(temp);
}

fn createZshCompletion(self: *Parser) !void {
    const prog = std.fs.path.basename(self.program_name);
    var buff = std.Io.Writer.Allocating.init(self.gpa);
    defer buff.deinit();

    try buff.writer.print("#compdef {s}\n\n", .{prog});
    try buff.writer.print("_{s}() {{\n", .{prog});
    try buff.writer.print("    _arguments -s -w \\\n", .{});

    for (self.option_order.items) |name| {
        const opt = self.options.get(name).?;
        const help = opt.help;

        if (opt.short) |s| {
            switch (opt.tag) {
                .boolean => try buff.writer.print("        '(-{c} --{s})'{{-{c},--{s}}}'[{s}]' \\\n", .{ s, name, s, name, help }),
                .string_slice => try buff.writer.print("        '*'{{-{c},--{s}}}'[{s}]:value: ' \\\n", .{ s, name, help }),
                .float, .int, .string => try buff.writer.print("        '(-{c} --{s})'{{-{c},--{s}}}'[{s}]:value: ' \\\n", .{ s, name, s, name, help }),
            }
        } else {
            switch (opt.tag) {
                .boolean => try buff.writer.print("        '--{s}[{s}]' \\\n", .{ name, help }),
                .string_slice => try buff.writer.print("        '*--{s}[{s}]:value: ' \\\n", .{ name, help }),
                .float, .int, .string => try buff.writer.print("        '--{s}[{s}]:value: ' \\\n", .{ name, help }),
            }
        }
    }

    try buff.writer.print("        '--help[Print this help message]' && return 0\n", .{});
    try buff.writer.print("}}\n", .{});

    var name_buf: [256]u8 = undefined;
    const filename = try std.fmt.bufPrint(&name_buf, "_{s}", .{prog});
    const file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();

    const temp = try buff.toOwnedSlice();
    defer self.gpa.free(temp);
    try file.writeAll(temp);
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

pub const AutoCompTarget = enum {
    bash,
    fish,
    zsh,
};
