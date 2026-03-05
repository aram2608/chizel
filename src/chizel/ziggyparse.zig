const std = @import("std");
const defaultValue = std.builtin.Type.StructField.defaultValue;
const startsWith = std.mem.startsWith;
const Allocator = std.mem.Allocator;
const isAlphabetic = std.ascii.isAlphabetic;
const fields = std.meta.fields;
const eql = std.mem.eql;
const indexOf = std.mem.indexOf;

/// ZiggyParse — comptime struct-driven CLI argument parser.
///
/// A lightweight alternative to `ArgParser` for simple use cases. Define your
/// options as a plain Zig struct with default values and ZiggyParse handles the rest.
/// All allocations are backed by an `ArenaAllocator` and freed with a single `deinit`.
///
/// ## Type parameters
///
/// - `Options`   — struct whose fields define the accepted flags. Every field
///                 must have a default value (enforced at compile time). Optionally
///                 declare `pub const shorts` inside to map field names to short chars.
/// - `IterType`  — any type with a `pub fn next(*T) ?[]const u8` method,
///                 e.g. `*std.process.ArgIterator` or a test slice iterator.
///
/// ## Defining options
///
/// Every field in `Options` must have a default value. Fields without a default
/// cause a compile error. For fields that are logically required (no sensible
/// default), use `?T = null` — the type system then forces the caller to handle
/// the missing case:
///
/// ```zig
/// const Opts = struct {
///     host: ?[]const u8        = null,  // required — caller must handle null
///     port: u16                = 8080,
///     verbose: bool            = false,
///     tags: []const []const u8 = &.{},
///
///     // Optional: map field names to single-character short aliases.
///     pub const shorts = .{ .host = 'h', .port = 'p' };
///
///     // Optional: parser behaviour — all fields have defaults, omit to use defaults.
///     pub const config = .{
///         .help_enabled  = true,   // intercept --help / -h and set Result.had_help
///         .allow_unknown = false,  // collect unknown flags instead of erroring
///     };
/// };
/// ```
///
/// ## Usage
///
/// ```zig
/// var args = try std.process.ArgIterator.initWithAllocator(allocator);
/// defer args.deinit();
///
/// const arena = std.heap.ArenaAllocator.init(allocator);
/// var parser = ZiggyParse(Opts, *ArgIterator).init(&args, arena);
/// defer parser.deinit();
///
/// const result = try parser.parse();
/// const host = result.opts.host orelse return error.MissingHost;
/// ```
///
/// ## Result
///
/// `parse()` returns a `Result` containing:
///
/// - `prog`            — `argv[0]`, the program name.
/// - `opts`            — the populated `Options` struct.
/// - `positionals`     — non-flag tokens collected in order.
/// - `unknown_options` — unrecognised flag names; only populated when
///                       `config.allow_unknown = true`, otherwise `parse()` errors.
/// - `had_help`        — `true` when `--help` or `-h` appeared; only meaningful
///                       when `config.help_enabled = true` (the default).
///
/// ## Supported field types
///
/// | Zig type              | CLI behaviour                                         |
/// |-----------------------|-------------------------------------------------------|
/// | `bool`                | `--flag` → `true`; `--no-flag` → `false`             |
/// | `[]const u8`          | Consumes the next token; duped into the arena         |
/// | `[]const []const u8`  | Consumes tokens until the next flag or end of args    |
/// | `i*` / `u*`           | Parses the next token as an integer                   |
/// | `f*`                  | Parses the next token as a float                      |
/// | `?T`                  | Parses as `T` when the flag is present, else `null`   |
///
/// ## Boolean negation
///
/// Prefix any boolean flag with `--no-` to set it to `false`:
///
/// ```
/// myapp --no-verbose
/// ```
///
/// Applying `--no-` to a non-boolean flag is an error (`error.CannotNegate`).
///
/// ## Unknown flags
///
/// Set `pub const config = .{ .allow_unknown = true }` in `Options` to collect
/// unrecognised flags in `Result.unknown_options` rather than returning
/// `error.UnknownOption`. Unknown short flags are stored without the leading `-`.
///
/// ## Lifetime
///
/// All heap values in the returned `Result` (strings, slices, positionals) are
/// owned by the parser's arena. Accessing them after `parser.deinit()` is
/// undefined behaviour. Always `defer parser.deinit()` immediately after `init`:
///
/// ```zig
/// var parser = ZiggyParse(Opts, *ArgIterator).init(&args, arena);
/// defer parser.deinit();              // runs last — correct
/// const result = try parser.parse(); // result borrows from arena
/// ```
pub fn ZiggyParse(comptime Options: type, comptime IterType: type) type {
    if (@typeInfo(Options) != .@"struct") @compileError("ZiggyParse: `Options` must be a struct.");

    // Require all Options fields to have defaults so initDefaults() is always safe.
    inline for (std.meta.fields(Options)) |field| {
        if (field.default_value_ptr == null) {
            @compileError("ZiggyParse: field `" ++ field.name ++ "` must have a default value. " ++
                "For required arguments use `?T = null` or switch to ArgParser.");
        }
    }

    // Extract behaviour flags from Options.config at comptime, falling back to defaults.
    const cfg_help_enabled: bool = if (@hasDecl(Options, "config") and
        @hasField(@TypeOf(Options.config), "help_enabled"))
        Options.config.help_enabled
    else
        true;

    const cfg_allow_unknown: bool = if (@hasDecl(Options, "config") and
        @hasField(@TypeOf(Options.config), "allow_unknown"))
        Options.config.allow_unknown
    else
        false;

    return struct {
        arena: std.heap.ArenaAllocator,
        iter: Iter(IterType),
        parsed: bool = false,
        const Self = @This();

        /// Create a parser.
        ///
        /// - `inner` — the token source; `argv[0]` is consumed on the first call to `parse()`.
        /// - `arena` — taken by value; freed by `deinit()`.
        ///
        /// Parser behaviour (help interception, unknown flag handling) is configured via
        /// `pub const config` in `Options` rather than here — see the module doc for details.
        pub fn init(inner: IterType, arena: std.heap.ArenaAllocator) Self {
            return .{
                .arena = arena,
                .iter = .{ .inner = inner },
            };
        }

        /// Frees all memory allocated during `parse`.
        ///
        /// Must be called after all use of the returned `Result` is complete.
        /// Prefer `defer parser.deinit()` immediately after `init`.
        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }

        fn Iter(comptime T: type) type {
            return struct {
                inner: T,
                peeked: ?[]const u8 = null,

                fn next(self: *@This()) ?[]const u8 {
                    if (self.peeked) |peeked| {
                        self.peeked = null;
                        return peeked;
                    }

                    return self.inner.next();
                }

                fn peek(self: *@This()) ?[]const u8 {
                    if (self.peeked == null) self.peeked = self.inner.next();
                    return self.peeked;
                }
            };
        }

        /// The value returned by `parse()`.
        pub const Result = struct {
            /// `argv[0]` — the program name as passed to the process.
            prog: []const u8,
            /// The populated options struct.
            opts: Options,
            /// Non-flag tokens collected in the order they appeared.
            positionals: []const []const u8,
            /// Unrecognised flag names (without leading dashes).
            /// Only populated when `allow_unknown = true`.
            unknown_options: []const []const u8,
            /// `true` when `--help` or `-h` appeared anywhere in argv.
            /// When true, `opts` may be partially populated — check this first.
            had_help: bool,

            pub fn printHelp(self: *const @This(), allocator: Allocator) ![]const u8 {
                var buff = std.io.Writer.Allocating.init(allocator);
                try buff.writer.print("Usage: {s} [OPTIONS]\n\nOptions:\n", .{self.prog});

                if (@hasDecl(Options, "help")) {
                    // Compute the longest flag name at comptime for alignment.
                    comptime var max_name_len: usize = 0;
                    inline for (fields(Options)) |field| {
                        if (field.name.len > max_name_len) max_name_len = field.name.len;
                    }

                    inline for (fields(Options)) |field| {
                        if (@hasField(@TypeOf(Options.help), field.name)) {
                            const help: []const u8 = @field(Options.help, field.name);
                            const has_short = @hasDecl(Options, "shorts") and
                                @hasField(@TypeOf(Options.shorts), field.name);
                            if (has_short) {
                                const s: u8 = @field(Options.shorts, field.name);
                                try buff.writer.print("  -{c}, --{s}", .{ s, field.name });
                            } else {
                                try buff.writer.print("      --{s}", .{field.name});
                            }

                            const padding = max_name_len - field.name.len + 3;
                            for (0..padding) |_| try buff.writer.writeByte(' ');
                            try buff.writer.print("{s}\n", .{help});
                        }
                    }
                } else {
                    @compileError("To produce a help message for `Options` please provide a `help` declaration.");
                }

                return buff.toOwnedSlice();
            }
        };

        fn initDefaults() Options {
            var val: Options = undefined;
            inline for (fields(Options)) |field| {
                // .? is safe — validated at comptime above that all fields have defaults.
                @field(val, field.name) = defaultValue(field).?;
            }
            return val;
        }

        /// Parse the argument iterator and return a `Result`.
        ///
        /// Consumes `argv[0]` as the program name, then processes remaining
        /// tokens as flags or positionals. May only be called once.
        ///
        /// ## Flag syntax
        ///
        /// - `--name value`  — long flag with a value
        /// - `--flag`        — boolean flag (sets `true`)
        /// - `--no-flag`     — boolean negation (sets `false`)
        /// - `-s value`      — short alias (declared via `pub const shorts` in `Options`)
        /// - `--`            — end of flags; all remaining tokens become positionals
        ///
        /// ## Errors
        ///
        /// - `error.AlreadyParsed`        — `parse` was called more than once.
        /// - `error.MissingProgramName`   — the iterator was empty (no `argv[0]`).
        /// - `error.MissingValue`         — a non-boolean flag had no following token.
        /// - `error.CannotNegate`         — `--no-` was applied to a non-boolean field.
        /// - `error.BoolCannotHaveValue`  — `--flag=value` was used on a boolean field.
        /// - `error.UnknownOption`        — an unrecognised flag appeared and
        ///                                 `allow_unknown` is `false`.
        /// - `error.InvalidCharacter` / `error.Overflow` — integer parse failure.
        pub fn parse(self: *Self) !Result {
            if (self.parsed) return error.AlreadyParsed;

            const allocator = self.arena.allocator();
            self.parsed = true;
            var defaults = initDefaults();
            // Comptime-initialized so @field access in inline for is safe.
            var positionals: std.ArrayList([]const u8) = .empty;
            var unknown: std.ArrayList([]const u8) = .empty;
            var had_help = false;

            const program_name = self.iter.next() orelse return error.MissingProgramName;
            while (self.iter.next()) |opt| {
                if (eql(u8, opt, "--")) {
                    while (self.iter.next()) |pos| try positionals.append(allocator, pos);
                    break;
                }
                if (cfg_help_enabled and
                    (eql(u8, opt, "--help") or std.mem.eql(u8, opt, "-h")))
                {
                    had_help = true;
                    continue;
                }
                if (startsWith(u8, opt, "--")) {
                    var key = opt[2..];
                    var inline_val: ?[]const u8 = null;
                    if (indexOf(u8, key, "=")) |i| {
                        inline_val = key[i + 1 ..];
                        key = key[0..i];
                    }
                    const negated = startsWith(u8, key, "no-");
                    if (negated) key = key[3..];
                    var matched = false;
                    inline for (std.meta.fields(Options)) |field| {
                        if (std.mem.eql(u8, key, field.name)) {
                            const base_type = switch (@typeInfo(field.type)) {
                                .optional => |o| o.child,
                                else => field.type,
                            };
                            if (negated and base_type != bool) return error.CannotNegate;

                            @field(defaults, field.name) = try self.parseNext(field.type, negated, inline_val, allocator);
                            matched = true;
                        }
                    }
                    if (!matched) {
                        if (cfg_allow_unknown) try unknown.append(allocator, key) else return error.UnknownOption;
                    }
                } else if (startsWith(u8, opt, "-")) {
                    const key = opt[1..];
                    var matched = false;
                    if (@hasDecl(Options, "shorts")) {
                        inline for (std.meta.fields(Options)) |field| {
                            if (@hasField(@TypeOf(Options.shorts), field.name)) {
                                const s: u8 = @field(Options.shorts, field.name);
                                if (key.len == 1 and key[0] == s) {
                                    @field(defaults, field.name) = try self.parseNext(field.type, false, null, allocator);
                                    matched = true;
                                }
                            }
                        }
                    }
                    if (!matched) {
                        if (cfg_allow_unknown) try unknown.append(allocator, key) else return error.UnknownOption;
                    }
                } else {
                    try positionals.append(allocator, opt);
                }
            }

            return .{
                .prog = std.fs.path.basename(program_name),
                .opts = defaults,
                .positionals = try positionals.toOwnedSlice(allocator),
                .unknown_options = try unknown.toOwnedSlice(allocator),
                .had_help = had_help,
            };
        }

        fn parseNext(self: *Self, comptime FieldType: type, negated: bool, inline_val: ?[]const u8, allocator: Allocator) !FieldType {
            return switch (FieldType) {
                bool => blk: {
                    if (inline_val != null) return error.BoolCannotHaveValue;
                    break :blk !negated;
                },

                []const u8 => blk: {
                    const s = inline_val orelse self.iter.next() orelse return error.MissingValue;
                    break :blk try allocator.dupe(u8, s);
                },

                // Consumes tokens until the next flag token or end of args.
                // looksLikeOptionToken allows negative numbers like "-1" or "-3.14"
                // to be consumed as values rather than stopping the slice early.
                // An inline value (--flag=foo) is treated as the first element.
                []const []const u8 => blk: {
                    var list: std.ArrayList([]const u8) = .empty;
                    if (inline_val) |v| try list.append(allocator, try allocator.dupe(u8, v));
                    while (self.iter.peek()) |s| {
                        if (looksLikeOptionToken(s)) break;
                        _ = self.iter.next();
                        try list.append(allocator, try allocator.dupe(u8, s));
                    }
                    if (list.items.len == 0) return error.MissingValue;
                    break :blk try list.toOwnedSlice(allocator);
                },

                else => switch (@typeInfo(FieldType)) {
                    .int => blk: {
                        const s = inline_val orelse self.iter.next() orelse return error.MissingValue;
                        break :blk try std.fmt.parseInt(FieldType, s, 10);
                    },
                    .float => blk: {
                        const s = inline_val orelse self.iter.next() orelse return error.MissingValue;
                        break :blk try std.fmt.parseFloat(FieldType, s);
                    },
                    .optional => |opt| try self.parseNext(opt.child, negated, inline_val, allocator),
                    else => @compileError("Unsupported type: " ++ @typeName(FieldType)),
                },
            };
        }

        // Returns true when `token` looks like the start of a flag (`--anything`
        // or `-<alpha>`). Values like `-1` or `-3.14` return false so they are
        // not mistakenly treated as flag boundaries in string-slice parsing.
        fn looksLikeOptionToken(token: []const u8) bool {
            if (!startsWith(u8, token, "-") or token.len < 2) return false;
            return token[1] == '-' or isAlphabetic(token[1]);
        }
    };
}

pub const CompletionShell = enum { fish, zsh, bash };

/// Generate shell completion script for the given `Options` struct.
///
/// `Options` must be the same struct type passed to `ZiggyParse`. Only the
/// comptime shape of `Options` is used — no parser instance is needed.
///
/// - `.fish` — emits a file suitable for `~/.config/fish/completions/<prog>.fish`
/// - `.bash` — emits a `complete` function suitable for sourcing in `.bashrc`
/// - `.zsh`  — not yet implemented; returns `error.NotImplemented`
pub fn genCompletions(
    comptime Options: type,
    target: CompletionShell,
    allocator: Allocator,
    prog: []const u8,
) ![]const u8 {
    return switch (target) {
        .fish => genFishCompletions(Options, allocator, prog),
        .bash => genBashCompletions(Options, allocator, prog),
        .zsh => genZshCompletions(Options, allocator, prog),
    };
}

fn genZshCompletions(
    comptime Options: type,
    allocator: Allocator,
    prog: []const u8,
) ![]const u8 {
    var buff = std.io.Writer.Allocating.init(allocator);
    errdefer buff.deinit();

    try buff.writer.print("#compdef {s}\n\n", .{prog});
    try buff.writer.print("_{s}() {{\n", .{prog});
    try buff.writer.print("    _arguments -s -w \\\n", .{});

    inline for (fields(Options)) |field| {
        const base_type = switch (@typeInfo(field.type)) {
            .optional => |o| o.child,
            else => field.type,
        };
        const is_bool = base_type == bool;
        const has_short = @hasDecl(Options, "shorts") and @hasField(@TypeOf(Options.shorts), field.name);
        const has_help = @hasDecl(Options, "help") and @hasField(@TypeOf(Options.help), field.name);
        const help_text: []const u8 = if (has_help) @field(Options.help, field.name) else field.name;

        if (is_bool) {
            if (has_short) {
                const s: u8 = @field(Options.shorts, field.name);
                try buff.writer.print("        '(-{c} --{s})-{c}[{s}]' \\\n", .{ s, field.name, s, help_text });
                try buff.writer.print("        '(-{c} --{s})--{s}[{s}]' \\\n", .{ s, field.name, field.name, help_text });
            } else {
                try buff.writer.print("        '--{s}[{s}]' \\\n", .{ field.name, help_text });
            }
            try buff.writer.print("        '--no-{s}[Negate {s}]' \\\n", .{ field.name, field.name });
        } else {
            if (has_short) {
                const s: u8 = @field(Options.shorts, field.name);
                try buff.writer.print("        '(-{c} --{s})-{c}+[{s}]:{s}: ' \\\n", .{ s, field.name, s, help_text, field.name });
                try buff.writer.print("        '(-{c} --{s})--{s}=[{s}]:{s}: ' \\\n", .{ s, field.name, field.name, help_text, field.name });
            } else {
                try buff.writer.print("        '--{s}=[{s}]:{s}: ' \\\n", .{ field.name, help_text, field.name });
            }
        }
    }

    try buff.writer.print("        '--help[Print this help message]' && return 0\n", .{});
    try buff.writer.print("}}\n", .{});
    try buff.writer.print("_{s} \"$@\"\n", .{prog});

    return buff.toOwnedSlice();
}

fn genFishCompletions(
    comptime Options: type,
    allocator: Allocator,
    prog: []const u8,
) ![]const u8 {
    var buff = std.io.Writer.Allocating.init(allocator);
    errdefer buff.deinit();
    try buff.writer.print("# ~/.config/fish/completions/{s}.fish\n", .{prog});

    inline for (std.meta.fields(Options)) |field| {
        const base_type = switch (@typeInfo(field.type)) {
            .optional => |o| o.child,
            else => field.type,
        };
        const kind: []const u8 = if (base_type == bool) "-f" else "-r -f";
        const has_short = @hasDecl(Options, "shorts") and @hasField(@TypeOf(Options.shorts), field.name);
        const has_help = @hasDecl(Options, "help") and @hasField(@TypeOf(Options.help), field.name);
        if (has_help) {
            const help: []const u8 = @field(Options.help, field.name);
            if (has_short) {
                const s: u8 = @field(Options.shorts, field.name);
                try buff.writer.print("complete -c {s} -s {c} -l {s} {s} -d \"{s}\"\n", .{ prog, s, field.name, kind, help });
            } else {
                try buff.writer.print("complete -c {s} -l {s} {s} -d \"{s}\"\n", .{ prog, field.name, kind, help });
            }
        } else {
            if (has_short) {
                const s: u8 = @field(Options.shorts, field.name);
                try buff.writer.print("complete -c {s} -s {c} -l {s} {s}\n", .{ prog, s, field.name, kind });
            } else {
                try buff.writer.print("complete -c {s} -l {s} {s}\n", .{ prog, field.name, kind });
            }
        }
    }

    return buff.toOwnedSlice();
}

fn genBashCompletions(
    comptime Options: type,
    allocator: Allocator,
    prog: []const u8,
) ![]const u8 {
    var buff = std.io.Writer.Allocating.init(allocator);
    errdefer buff.deinit();

    try buff.writer.print("_{s}() {{\n", .{prog});
    try buff.writer.print("    local cur prev opts\n", .{});
    try buff.writer.print("    _init_completion || return\n", .{});

    try buff.writer.print("    opts=\"--help -h", .{});
    inline for (std.meta.fields(Options)) |field| {
        try buff.writer.print(" --{s}", .{field.name});
        const has_short = @hasDecl(Options, "shorts") and @hasField(@TypeOf(Options.shorts), field.name);
        if (has_short) {
            const s: u8 = @field(Options.shorts, field.name);
            try buff.writer.print(" -{c}", .{s});
        }
    }
    try buff.writer.print("\"\n", .{});

    try buff.writer.print("    case \"$prev\" in\n", .{});
    inline for (std.meta.fields(Options)) |field| {
        const base_type = switch (@typeInfo(field.type)) {
            .optional => |o| o.child,
            else => field.type,
        };
        if (base_type == bool) continue;
        const has_short = @hasDecl(Options, "shorts") and
            @hasField(@TypeOf(Options.shorts), field.name);
        if (has_short) {
            const s: u8 = @field(Options.shorts, field.name);
            try buff.writer.print("        --{s}|-{c})\n", .{ field.name, s });
        } else {
            try buff.writer.print("        --{s})\n", .{field.name});
        }
        try buff.writer.print("            return ;;\n", .{});
    }

    try buff.writer.print("    esac\n", .{});

    try buff.writer.print("    COMPREPLY=($(compgen -W \"$opts\" -- \"$cur\"))\n", .{});
    try buff.writer.print("}}\n", .{});
    try buff.writer.print("complete -F _{s} {s}\n", .{ prog, prog });

    return buff.toOwnedSlice();
}
