const std = @import("std");
const defaultValue = std.builtin.Type.StructField.defaultValue;
const startsWith = std.mem.startsWith;
const Allocator = std.mem.Allocator;
const isAlphabetic = std.ascii.isAlphabetic;
const fields = std.meta.fields;
const eql = std.mem.eql;
const indexOf = std.mem.indexOf;

/// Chizel: comptime struct-driven CLI argument parser.
///
/// Define your options as a plain Zig struct with default values and Chizel handles the rest.
/// For programs with subcommands, pass a `union(enum)` instead; each variant names a
/// subcommand and holds a struct of its own flags.
/// All allocations are backed by an `ArenaAllocator` and freed with a single `deinit`.
///
/// ## Type parameter
///
/// `Options` must be one of:
///
/// - A **struct**: every field defines an accepted flag and must have a default value
///   (enforced at compile time). Optionally declare `pub const shorts`, `pub const help`,
///   and `pub const config` inside.
///
/// - A **tagged union** (`union(enum)`): each variant names a subcommand and must be a
///   struct satisfying the same rules as above (all fields defaulted, optional `shorts`).
///
/// ## Defining options (struct)
///
/// Every field must have a default value. For logically required fields use `?T = null`;
/// the type system then forces the caller to handle the missing case:
///
/// ```zig
/// const Opts = struct {
///     host: ?[]const u8        = null,  // required; caller must handle null
///     port: u16                = 8080,
///     verbose: bool            = false,
///     tags: []const []const u8 = &.{},
///
///     pub const shorts = .{ .host = 'h', .port = 'p' };
///     pub const config = .{
///         .help_enabled  = true,
///         .allow_unknown = false,
///     };
/// };
/// ```
///
/// ## Defining subcommands (union)
///
/// Each union variant names a subcommand. The variant's type must be a struct whose
/// fields follow the same rules as above. Each subcommand struct may have its own
/// `pub const shorts`.
///
/// ```zig
/// const Cmds = union(enum) {
///     serve: struct {
///         port: u16 = 8080,
///         pub const shorts = .{ .port = 'p' };
///     },
///     build: struct {
///         release: bool = false,
///     },
/// };
/// ```
///
/// The first non-program-name token is consumed as the subcommand name. All remaining
/// tokens are parsed as flags for that subcommand's struct. The result's `opts` field
/// is the union value; switch on it to dispatch:
///
/// ```zig
/// switch (result.opts) {
///     .serve => |s| std.debug.print("port={}\n", .{s.port}),
///     .build => |b| std.debug.print("release={}\n", .{b.release}),
/// }
/// ```
///
/// ## Usage
///
/// ```zig
/// var args = try std.process.argsWithAllocator(allocator);
/// defer args.deinit();
///
/// const arena = std.heap.ArenaAllocator.init(allocator);
/// var parser = Chizel(Opts).init(&args, arena);
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
/// - `prog`:            `argv[0]`, the program name.
/// - `opts`:            the populated `Options` struct or union.
/// - `positionals`:     non-flag tokens collected in order.
/// - `unknown_options`: unrecognised flag names; only populated when
///                      `config.allow_unknown = true`, otherwise `parse()` errors.
/// - `had_help`:        `true` when `--help` or `-h` appeared; only meaningful
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
/// var parser = Chizel(Opts).init(&args, arena);
/// defer parser.deinit();              // runs last (correct)
/// const result = try parser.parse(); // result borrows from arena
/// ```
///
pub fn Chizel(comptime Options: type) type {
    // Extract behaviour flags from Options.config at comptime, falling back to defaults.
    // These must be in scope for the returned struct's parse() method regardless of
    // whether Options is a struct or a tagged union.
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

    if (@typeInfo(Options) == .@"struct") {

        // Require all Options fields to have defaults so initDefaults() is always safe.
        for (std.meta.fields(Options)) |field| {
            if (field.default_value_ptr == null) {
                @compileError("Chizel: field `" ++ field.name ++ "` must have a default value. " ++
                    "For required arguments use `?T = null`.");
            }
        }

        if (cfg_help_enabled and @hasField(Options, "help"))
            @compileError("Field named `help` conflicts with built-in --help handling.");

        comptime {
            if (cfg_help_enabled and @hasDecl(Options, "shorts")) {
                for (fields(@TypeOf(Options.shorts))) |field| {
                    const s: u8 = @field(Options.shorts, field.name);
                    if (s == 'h') @compileError("Short flag 'h' conflicts with built-in --help. " ++ "Set `pub const config = .{ help_enabled = false ) }` to use -h yourself");
                }
            }
        }
    } else if (@typeInfo(Options) == .@"union") {
        const union_info = @typeInfo(Options).@"union";

        if (union_info.tag_type == null) {
            @compileError("Chizel: subcommand union must be a tagged union (`union(enum)`).");
        }

        for (union_info.fields) |field| {
            if (@typeInfo(field.type) != .@"struct") {
                @compileError("Chizel: subcommand `" ++ field.name ++ "` must be a struct.");
            }
            // Require all Subcommand fields to have defaults so initDefaults() is always safe.
            for (std.meta.fields(field.type)) |sub_field| {
                if (sub_field.default_value_ptr == null) {
                    @compileError("Chizel: field `" ++ sub_field.name ++ "` in subcommand `" ++ field.name ++ "` must have a default value. " ++
                        "For required arguments use `?T = null`.");
                }
            }
        }
    } else {
        @compileError("Chizel: `Options` must be a struct or a tagged union (`union(enum)`).");
    }

    return struct {
        arena: std.heap.ArenaAllocator,
        iter: ErasedIter,
        parsed: bool = false,
        const Self = @This();

        // Type erased iterator used by the parser.
        // The type is resolved at compile time and the next function
        // is stored as a function pointer.
        // Very complex in the backend but this improves the usability of the
        // library's API.
        const ErasedIter = struct {
            ptr: *anyopaque,
            next_fn: *const fn (*anyopaque) ?[]const u8,
            peeked: ?[]const u8 = null,

            fn next(self: *@This()) ?[]const u8 {
                if (self.peeked) |p| {
                    self.peeked = null;
                    return p;
                }
                return self.next_fn(self.ptr);
            }

            fn peek(self: *@This()) ?[]const u8 {
                if (self.peeked == null) self.peeked = self.next_fn(self.ptr);
                return self.peeked;
            }
        };

        /// Create a parser.
        ///
        /// - `inner`: a pointer to the token source; must outlive the parser.
        ///            `argv[0]` is consumed on the first call to `parse()`.
        /// - `arena`: taken by value; freed by `deinit()`.
        ///
        /// Parser behaviour (help interception, unknown flag handling) is configured via
        /// `pub const config` in `Options` rather than here; see the module doc for details.
        pub fn init(inner: anytype, arena: std.heap.ArenaAllocator) Self {
            const T = @TypeOf(inner);
            comptime if (@typeInfo(T) != .pointer)
                @compileError("Chizel.init: `inner` must be a pointer to an iterator.");
            const gen = struct {
                fn nextFn(ptr: *anyopaque) ?[]const u8 {
                    return @as(T, @ptrCast(@alignCast(ptr))).next();
                }
            };
            return .{
                .arena = arena,
                .iter = .{ .ptr = @ptrCast(inner), .next_fn = gen.nextFn },
            };
        }

        /// Frees all memory allocated during `parse`.
        ///
        /// Must be called after all use of the returned `Result` is complete.
        /// Prefer `defer parser.deinit()` immediately after `init`.
        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }

        /// The value returned by `parse()`.
        pub const Result = struct {
            /// `argv[0]`: the program name as passed to the process.
            prog: []const u8,
            /// The populated options struct.
            opts: Options,
            /// Non-flag tokens collected in the order they appeared.
            positionals: []const []const u8,
            /// Unrecognised flag names (without leading dashes).
            /// Only populated when `allow_unknown = true`.
            unknown_options: []const []const u8,
            /// `true` when `--help` or `-h` appeared anywhere in argv.
            /// When true, `opts` may be partially populated; check this first.
            had_help: bool,

            // TODO: Fix these two methods for the new subcommands

            /// Return a human-readable dump of the parsed result, useful for
            /// debugging. Caller owns the returned slice.
            pub fn emitParsed(self: *const @This(), allocator: Allocator) ![]const u8 {
                var buff = std.io.Writer.Allocating.init(allocator);
                errdefer buff.deinit();

                try buff.writer.print("prog: {s}\n", .{self.prog});
                try buff.writer.print("had_help: {}\n", .{self.had_help});

                try buff.writer.print("positionals: [", .{});
                for (self.positionals, 0..) |p, i| {
                    if (i > 0) try buff.writer.print(", ", .{});
                    try buff.writer.print("{s}", .{p});
                }
                try buff.writer.print("]\n", .{});

                if (self.unknown_options.len > 0) {
                    try buff.writer.print("unknown_options: [", .{});
                    for (self.unknown_options, 0..) |u, i| {
                        if (i > 0) try buff.writer.print(", ", .{});
                        try buff.writer.print("{s}", .{u});
                    }
                    try buff.writer.print("]\n", .{});
                }

                try buff.writer.print("opts:\n", .{});
                if (@typeInfo(Options) == .@"union") {
                    const tag = std.meta.activeTag(self.opts);
                    try buff.writer.print("  subcommand: {s}\n", .{@tagName(tag)});
                    inline for (@typeInfo(Options).@"union".fields) |ufield| {
                        if (std.mem.eql(u8, ufield.name, @tagName(tag))) {
                            const sub = @field(self.opts, ufield.name);
                            inline for (fields(ufield.type)) |field| {
                                const val = @field(sub, field.name);
                                try buff.writer.print("    {s}: ", .{field.name});
                                try emitValue(field.type, val, &buff.writer);
                                try buff.writer.print("\n", .{});
                            }
                        }
                    }
                } else {
                    inline for (fields(Options)) |field| {
                        const val = @field(self.opts, field.name);
                        try buff.writer.print("  {s}: ", .{field.name});
                        try emitValue(field.type, val, &buff.writer);
                        try buff.writer.print("\n", .{});
                    }
                }

                return buff.toOwnedSlice();
            }

            /// Generates the constructed help message. The caller is responsible
            /// for freeing all memory.
            pub fn printHelp(self: *const @This(), allocator: Allocator) ![]const u8 {
                var buff = std.io.Writer.Allocating.init(allocator);
                errdefer buff.deinit();
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

        // writer interface must have a print method similar to the
        // std.debug.print(fmt: []const u8, args: anytype);
        fn emitValue(comptime T: type, val: T, writer: anytype) !void {
            switch (T) {
                bool => try writer.print("{}", .{val}),
                []const u8 => try writer.print("\"{s}\"", .{val}),
                []const []const u8 => {
                    try writer.print("[", .{});
                    for (val, 0..) |s, i| {
                        if (i > 0) try writer.print(", ", .{});
                        try writer.print("\"{s}\"", .{s});
                    }
                    try writer.print("]", .{});
                },
                else => switch (@typeInfo(T)) {
                    .int, .float => try writer.print("{}", .{val}),
                    .optional => |opt| {
                        if (val) |inner| {
                            try emitValue(opt.child, inner, writer);
                        } else {
                            try writer.print("null", .{});
                        }
                    },
                    else => try writer.print("<{s}>", .{@typeName(T)}),
                },
            }
        }

        /// Parse the argument iterator and return a `Result`.
        ///
        /// Consumes `argv[0]` as the program name, then processes remaining
        /// tokens as flags or positionals. May only be called once.
        ///
        /// ## Flag syntax
        ///
        /// - `--name value`:  long flag with a value
        /// - `--flag`:        boolean flag (sets `true`)
        /// - `--no-flag`:     boolean negation (sets `false`)
        /// - `-s value`:      short alias (declared via `pub const shorts` in `Options`)
        /// - `--`:            end of flags; all remaining tokens become positionals
        ///
        /// ## Errors
        ///
        /// - `error.AlreadyParsed`:        `parse` was called more than once.
        /// - `error.MissingProgramName`:   the iterator was empty (no `argv[0]`).
        /// - `error.MissingSubcommand`:    union mode: no subcommand token followed `argv[0]`.
        /// - `error.UnknownSubcommand`:    union mode: the subcommand token matched no variant.
        /// - `error.MissingValue`:         a non-boolean flag had no following token.
        /// - `error.CannotNegate`:         `--no-` was applied to a non-boolean field.
        /// - `error.BoolCannotHaveValue`:  `--flag=value` was used on a boolean field.
        /// - `error.UnknownOption`:        an unrecognised flag appeared and
        ///                                 `allow_unknown` is `false`.
        /// - `error.InvalidCharacter` / `error.Overflow`: integer parse failure.
        pub fn parse(self: *Self) !Result {
            if (self.parsed) return error.AlreadyParsed;
            self.parsed = true;

            const allocator = self.arena.allocator();
            var positionals: std.ArrayList([]const u8) = .empty;
            var unknown: std.ArrayList([]const u8) = .empty;
            var had_help = false;

            const program_name = self.iter.next() orelse return error.MissingProgramName;

            // Options can contain subcommands or come in as a simpler program.
            // Validation happens at compile time so we don't have to worry
            // about any strange behavior.
            const opts: Options = if (@typeInfo(Options) == .@"struct") blk: {
                var defaults: Options = .{};
                try self.parseStructOpts(Options, &defaults, &positionals, &unknown, &had_help, allocator);
                break :blk defaults;
            } else blk: {
                const subcmd = self.iter.next() orelse return error.MissingSubcommand;
                var result: Options = undefined;
                var matched = false;
                inline for (@typeInfo(Options).@"union".fields) |f| {
                    if (!matched and eql(u8, subcmd, f.name)) {
                        var sub: f.type = .{};
                        try self.parseStructOpts(f.type, &sub, &positionals, &unknown, &had_help, allocator);
                        result = @unionInit(Options, f.name, sub);
                        matched = true;
                    }
                }
                if (!matched) return error.UnknownSubcommand;
                break :blk result;
            };

            return .{
                .prog = std.fs.path.basename(program_name),
                .opts = opts,
                .positionals = try positionals.toOwnedSlice(allocator),
                .unknown_options = try unknown.toOwnedSlice(allocator),
                .had_help = had_help,
            };
        }

        fn parseStructOpts(
            self: *Self,
            comptime T: type,
            target: *T,
            positionals: *std.ArrayList([]const u8),
            unknown: *std.ArrayList([]const u8),
            had_help: *bool,
            allocator: Allocator,
        ) !void {
            while (self.iter.next()) |opt| {
                if (eql(u8, opt, "--")) {
                    while (self.iter.next()) |pos| try positionals.append(allocator, pos);
                    break;
                }
                if (cfg_help_enabled and (eql(u8, opt, "--help") or eql(u8, opt, "-h"))) {
                    had_help.* = true;
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

                    // Long opts arrive as --long-opt so convert `-` to `_` before
                    // matching against struct field names. Save the original for
                    // unknown-option reporting so callers see the flag as typed.
                    const original_key = key;

                    // For better performance we only perform the normalization
                    // if a '-' is found in the string.
                    // Each normalization requires a heap allocation so if we can
                    // skip for non-long options it's probably better.
                    const normalized_key = if (std.mem.indexOfScalar(u8, key, '-') != null) blk: {
                        const buff = try allocator.dupe(u8, key);
                        std.mem.replaceScalar(u8, buff, '-', '_');
                        break :blk buff;
                    } else key;

                    var matched = false;
                    blk: inline for (std.meta.fields(T)) |field| {
                        if (eql(u8, normalized_key, field.name)) {
                            const base_type = switch (@typeInfo(field.type)) {
                                .optional => |o| o.child,
                                else => field.type,
                            };
                            if (negated and base_type != bool) return error.CannotNegate;
                            @field(target.*, field.name) = try self.parseNext(field.type, negated, inline_val, allocator);
                            matched = true;
                            break :blk;
                        }
                    }
                    if (!matched) {
                        if (cfg_allow_unknown) try unknown.append(allocator, original_key) else return error.UnknownOption;
                    }
                } else if (startsWith(u8, opt, "-")) {
                    if (opt.len > 2) {
                        for (opt[1..]) |o| {
                            var matched = false;
                            if (@hasDecl(T, "shorts")) {
                                inline for (fields(T)) |field| {
                                    if (@hasField(@TypeOf(T.shorts), field.name)) {
                                        const s: u8 = @field(T.shorts, field.name);
                                        if (o == s) {
                                            const base_type = switch (@typeInfo(field.type)) {
                                                .optional => |p| p.child,
                                                else => field.type,
                                            };
                                            if (base_type != bool) return error.CombinedShortRequiresValue;
                                            @field(target.*, field.name) = try self.parseNext(field.type, false, null, allocator);
                                            matched = true;
                                        }
                                    }
                                }
                            }
                            if (!matched) {
                                if (cfg_allow_unknown) {
                                    const char_str = try allocator.dupe(u8, &[_]u8{o});
                                    try unknown.append(allocator, char_str);
                                } else return error.UnknownOption;
                            }
                        }
                    } else {
                        const key = opt[1..];
                        var matched = false;
                        if (@hasDecl(T, "shorts")) {
                            inline for (fields(T)) |field| {
                                if (@hasField(@TypeOf(T.shorts), field.name)) {
                                    const s: u8 = @field(T.shorts, field.name);
                                    if (key.len == 1 and key[0] == s) {
                                        @field(target.*, field.name) = try self.parseNext(field.type, false, null, allocator);
                                        matched = true;
                                    }
                                }
                            }
                        }
                        if (!matched) {
                            if (cfg_allow_unknown) try unknown.append(allocator, key) else return error.UnknownOption;
                        }
                    }
                } else try positionals.append(allocator, opt);
            }
        }

        fn parseNext(
            self: *Self,
            comptime FieldType: type,
            negated: bool,
            inline_val: ?[]const u8,
            allocator: Allocator,
        ) !FieldType {
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
