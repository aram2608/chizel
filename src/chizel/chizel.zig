const std = @import("std");
const path = std.fs.path;
const startsWith = std.mem.startsWith;
const Allocator = std.mem.Allocator;
const isAlphabetic = std.ascii.isAlphabetic;
const fields = std.meta.fields;

// TODO: Add a config flag or option to pass in so the user can shut off env
// var parsing. common names like "path" can caused problems

/// Subcommand parser. `Options` must be a tagged `union(enum)` where each variant
/// names a subcommand and holds a struct of flags.
///
/// Every field in each subcommand struct must have a default value (enforced at
/// compile time). Use `?T = null` for logically required fields.
///
/// Each subcommand struct may optionally declare:
/// - `pub const shorts` to map field names to single-character aliases
/// - `pub const help` with a `._cmd` field for the subcommand description
/// - `pub fn validate_<field>(value: T) !void` to validate a parsed field value
///
/// Validation functions are called after parsing and may return any error, which
/// is propagated directly from `parse()`. The function signature must accept one
/// argument of the field's base type (unwrapped if optional).
///
/// The first token after `argv[0]` is consumed as the subcommand name. Passing
/// `--help` before a subcommand sets `Result.had_help` without requiring
/// a valid subcommand.
///
/// ```zig
/// const Cmds = union(enum) {
///     serve: struct {
///         port: u16 = 8080,
///         pub const shorts = .{ .port = 'p' };
///         pub const help = .{ ._cmd = "Start the server", .port = "Port to listen on" };
///     },
///     build: struct { release: bool = false },
/// };
///
/// var parser = Chizel(Cmds).init(&args, arena);
/// defer parser.deinit();
///
/// const result = try parser.parse();
/// switch (result.opts) {
///     .serve => |s| std.debug.print("port={}\n", .{s.port}),
///     .build => |b| std.debug.print("release={}\n", .{b.release}),
/// }
/// ```
///
/// All heap values in `Result` are owned by the parser's arena and freed by `deinit()`.
pub fn Chizel(comptime Options: type) type {
    if (@typeInfo(Options) != .@"union") @compileError("Options must be a `union`");
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

    const cfg_help_enabled = configFlag(Options, "help_enabled", true);
    const cfg_allow_unknown = configFlag(Options, "allow_unknown", false);
    const cfg_parse_env = configFlag(Options, "parse_env", true);

    // Validation checks at comptime
    comptime {
        for (union_info.fields) |ufield| {
            checkShortsCollisions(ufield.type, " in subcommand `" ++ ufield.name ++ "`");
            checkValidateFns(ufield.type, " in subcommand `" ++ ufield.name ++ "`");
        }
    }

    return struct {
        arena: std.heap.ArenaAllocator,
        iter: ErasedIter,
        parsed: bool = false,
        const Self = @This();

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
            // Cast the functon pointer so we can use it in our iterator
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
            /// `true` when `--help` appeared anywhere in argv.
            /// When true, `opts` may be partially populated; check this first.
            had_help: bool,
            /// `true` when `--help` appeared before any subcommand (root-level help).
            /// When true, `opts` is the first variant with defaults and should not be used.
            had_root_help: bool,

            /// Return a human-readable dump of the parsed result, useful for
            /// debugging. Caller owns the returned slice.
            pub fn emitParsed(self: *const @This(), allocator: Allocator) ![]const u8 {
                var buff = std.io.Writer.Allocating.init(allocator);
                errdefer buff.deinit();

                try emitResultHeader(self.prog, self.had_help, self.positionals, self.unknown_options, &buff.writer);

                try buff.writer.print("opts:\n", .{});
                const tag = std.meta.activeTag(self.opts);
                try buff.writer.print("  subcommand: {s}\n", .{@tagName(tag)});
                inline for (@typeInfo(Options).@"union".fields) |ufield| {
                    if (tag == @field(std.meta.Tag(Options), ufield.name)) {
                        const sub = @field(self.opts, ufield.name);
                        inline for (fields(ufield.type)) |field| {
                            const val = @field(sub, field.name);
                            try buff.writer.print("    {s}: ", .{field.name});
                            try emitValue(field.type, val, &buff.writer);
                            try buff.writer.print("\n", .{});
                        }
                        break;
                    }
                }

                return buff.toOwnedSlice();
            }

            /// Generates the constructed help message. The caller is responsible
            /// for freeing all memory.
            pub fn printHelp(self: *const @This(), allocator: Allocator) ![]const u8 {
                comptime {
                    for (@typeInfo(Options).@"union".fields) |ufield| {
                        if (!@hasDecl(ufield.type, "help") and !@hasDecl(Options, "help"))
                            @compileError("printHelp: add `pub const help` to union `" ++
                                @typeName(Options) ++ "` or to each subcommand struct.");
                    }
                }
                var buff = std.io.Writer.Allocating.init(allocator);
                errdefer buff.deinit();

                if (self.had_root_help) {
                    // Root-level --help: show the subcommand list.
                    try buff.writer.print("Usage: {s} <SUBCOMMAND> [OPTIONS]\n\nSubcommands:\n", .{self.prog});

                    comptime var max_subcmd_len: usize = 0;
                    inline for (@typeInfo(Options).@"union".fields) |ufield| {
                        if (ufield.name.len > max_subcmd_len) max_subcmd_len = ufield.name.len;
                    }

                    inline for (@typeInfo(Options).@"union".fields) |ufield| {
                        // Prefer union-level Options.help.subcmd_name, fall back to subcommand's ._cmd.
                        const has_union_help = @hasDecl(Options, "help") and
                            @hasField(@TypeOf(Options.help), ufield.name);
                        const has_cmd_help = !has_union_help and @hasDecl(ufield.type, "help") and
                            @hasField(@TypeOf(ufield.type.help), "_cmd");
                        const desc: []const u8 = if (has_union_help)
                            @field(Options.help, ufield.name)
                        else if (has_cmd_help)
                            @field(ufield.type.help, "_cmd")
                        else
                            "";
                        const flag_name = comptime fieldToFlag(ufield.name);
                        try buff.writer.print("  {s}", .{&flag_name});
                        const padding = max_subcmd_len - ufield.name.len + 3;
                        for (0..padding) |_| try buff.writer.writeByte(' ');
                        try buff.writer.print("{s}\n", .{desc});
                    }
                } else {
                    // Subcommand-level --help: show options for the active subcommand.
                    const tag = std.meta.activeTag(self.opts);
                    try buff.writer.print("Usage: {s} {s} [OPTIONS]\n\nOptions:\n", .{ self.prog, @tagName(tag) });

                    outer: inline for (@typeInfo(Options).@"union".fields) |ufield| {
                        if (tag == @field(std.meta.Tag(Options), ufield.name)) {
                            inline for (std.meta.fields(ufield.type)) |field| {
                                const has_help = @hasDecl(ufield.type, "help") and
                                    @hasField(@TypeOf(ufield.type.help), field.name);
                                const has_short = @hasDecl(ufield.type, "shorts") and @hasField(@TypeOf(ufield.type.shorts), field.name);
                                const desc = if (has_help) @field(ufield.type.help, field.name) else "";
                                const flag_name = comptime fieldToFlag(field.name);
                                if (has_short) {
                                    const s = @field(ufield.type.shorts, field.name);
                                    try buff.writer.print(" -{c} --{s}  {s}\n", .{ s, &flag_name, desc });
                                } else try buff.writer.print("  --{s}  {s}\n", .{ &flag_name, desc });
                            }
                            break :outer;
                        }
                    }
                }

                return buff.toOwnedSlice();
            }
        };

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
            var had_root_help = false;

            const program_name = self.iter.next() orelse return error.MissingProgramName;
            const opts: Options = blk: {
                if (cfg_help_enabled) {
                    if (self.iter.peek()) |peeked| {
                        if (strEql(peeked, "--help")) {
                            _ = self.iter.next();
                            had_help = true;
                            had_root_help = true;
                            while (self.iter.next()) |_| {}
                            const first = @typeInfo(Options).@"union".fields[0];
                            break :blk @unionInit(Options, first.name, .{});
                        }
                    }
                }
                // Need to replace '-' with '_' to match the struct field
                const subcmd = self.iter.next() orelse return error.MissingSubcommand;
                // Allocations are handled inside the arena so cleanup is easy
                const normalized_sub = if (strIndexOfScalar(subcmd, '-') != null) tmp: {
                    const buf = try allocator.dupe(u8, subcmd);
                    std.mem.replaceScalar(u8, buf, '-', '_');
                    break :tmp buf;
                } else subcmd;
                var result: Options = undefined;
                var matched = false;
                inline for (@typeInfo(Options).@"union".fields) |f| {
                    if (!matched and strEql(normalized_sub, f.name)) {
                        var sub: f.type = .{};
                        if (cfg_parse_env)
                            try initializeEnvOptsImpl(f.type, &sub, allocator);
                        try parseStructOptsImpl(
                            f.type,
                            cfg_help_enabled,
                            cfg_allow_unknown,
                            &self.iter,
                            &sub,
                            &positionals,
                            &unknown,
                            &had_help,
                            allocator,
                        );
                        result = @unionInit(Options, f.name, sub);
                        matched = true;
                    }
                }
                if (!matched)
                    return error.UnknownSubcommand;
                break :blk result;
            };

            const result: Result = .{
                .prog = path.basename(program_name),
                .opts = opts,
                .positionals = try positionals.toOwnedSlice(allocator),
                .unknown_options = try unknown.toOwnedSlice(allocator),
                .had_help = had_help,
                .had_root_help = had_root_help,
            };

            if (!result.had_help) {
                const tag = std.meta.activeTag(result.opts);
                inline for (@typeInfo(Options).@"union".fields) |ufield| {
                    if (tag == @field(std.meta.Tag(Options), ufield.name)) {
                        const sub = @field(result.opts, ufield.name);
                        inline for (std.meta.fields(ufield.type)) |field| {
                            const fn_name = comptime "validate_" ++ field.name;
                            if (comptime @hasDecl(ufield.type, fn_name)) {
                                switch (@typeInfo(field.type)) {
                                    .optional => {
                                        if (@field(sub, field.name)) |inner|
                                            try @field(ufield.type, fn_name)(inner);
                                    },
                                    else => try @field(ufield.type, fn_name)(@field(sub, field.name)),
                                }
                            }
                        }
                        break;
                    }
                }
            }

            return result;
        }
    };
}

/// Single-command parser. `Options` must be a struct where every field defines an
/// accepted flag and has a default value (enforced at compile time).
///
/// Use `?T = null` for logically required fields; the type system forces the caller
/// to handle the missing case.
///
/// `Options` may optionally declare:
/// - `pub const shorts` to map field names to single-character aliases
/// - `pub const help` to provide per-field descriptions for `Result.printHelp()`
/// - `pub const config` to control parser behaviour (see below)
/// - `pub fn validate_<field>(value: T) !void` to validate a parsed field value
///
/// Validation functions are called after parsing and may return any error, which
/// is propagated directly from `parse()`. The function signature must accept one
/// argument of the field's base type (unwrapped if optional).
///
/// ```zig
/// const Opts = struct {
///     host:    ?[]const u8        = null,
///     port:    u16                = 8080,
///     verbose: bool               = false,
///     tags:    []const []const u8 = &.{},
///
///     pub const shorts = .{ .host = 'h', .port = 'p' };
///     pub const help   = .{ .host = "Server host", .port = "Server port" };
///     pub const config = .{ .help_enabled = true, .allow_unknown = false };
/// };
///
/// var parser = Chip(Opts).init(&args, arena);
/// defer parser.deinit();
///
/// const result = try parser.parse();
/// const host = result.opts.host orelse return error.MissingHost;
/// ```
///
/// `config` fields (all optional, shown with defaults):
/// - `help_enabled = true`: intercept `--help` and set `Result.had_help`
/// - `allow_unknown = false`: collect unrecognised flags in `Result.unknown_options`
///   instead of returning `error.UnknownOption`
///
/// All heap values in `Result` are owned by the parser's arena and freed by `deinit()`.
pub fn Chip(comptime Options: type) type {
    if (@typeInfo(Options) != .@"struct") @compileError("Options must be a `struct`");

    const cfg_help_enabled = configFlag(Options, "help_enabled", true);
    const cfg_allow_unknown = configFlag(Options, "allow_unknown", false);
    const cfg_parse_env = configFlag(Options, "parse_env", true);

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
        checkShortsCollisions(Options, "");
        checkValidateFns(Options, "");
    }

    return struct {
        arena: std.heap.ArenaAllocator,
        iter: ErasedIter,
        parsed: bool = false,
        const Self = @This();

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
                @compileError("Chip.init: `inner` must be a pointer to an iterator.");
            const gen = struct {
                fn nextFn(ptr: *anyopaque) ?[]const u8 {
                    return @as(T, @ptrCast(@alignCast(ptr))).next();
                }
            };
            return .{
                .arena = arena,
                .iter = .{
                    .ptr = @ptrCast(inner),
                    .next_fn = gen.nextFn,
                },
            };
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
            /// `true` when `--help` appeared anywhere in argv.
            /// When true, `opts` may be partially populated; check this first.
            had_help: bool,

            /// Return a human-readable dump of the parsed result, useful for
            /// debugging. Caller owns the returned slice.
            pub fn emitParsed(self: *const @This(), allocator: Allocator) ![]const u8 {
                var buff = std.io.Writer.Allocating.init(allocator);
                errdefer buff.deinit();

                try emitResultHeader(self.prog, self.had_help, self.positionals, self.unknown_options, &buff.writer);

                try buff.writer.print("opts:\n", .{});
                inline for (fields(Options)) |field| {
                    const val = @field(self.opts, field.name);
                    try buff.writer.print("  {s}: ", .{field.name});
                    try emitValue(field.type, val, &buff.writer);
                    try buff.writer.print("\n", .{});
                }

                return buff.toOwnedSlice();
            }

            /// Generates the constructed help message. The caller is responsible
            /// for freeing all memory.
            pub fn printHelp(self: *const @This(), allocator: Allocator) ![]const u8 {
                comptime if (!@hasDecl(Options, "help"))
                    @compileError("printHelp requires `pub const help` in `Options`. " ++
                        "Add `pub const help = .{ .field_name = \"description\" };`.");

                var buff = std.io.Writer.Allocating.init(allocator);
                errdefer buff.deinit();

                try buff.writer.print("Usage: {s} [OPTIONS]\n\nOptions:\n", .{self.prog});

                comptime var max_name_len: usize = 0;
                inline for (fields(Options)) |field| {
                    if (field.name.len > max_name_len) max_name_len = field.name.len;
                }

                inline for (fields(Options)) |field| {
                    const has_help = @hasField(@TypeOf(Options.help), field.name);
                    const help: []const u8 = if (has_help) @field(Options.help, field.name) else "";
                    const has_short = @hasDecl(Options, "shorts") and
                        @hasField(@TypeOf(Options.shorts), field.name);
                    const flag_name = comptime fieldToFlag(field.name);
                    if (has_short) {
                        const s: u8 = @field(Options.shorts, field.name);
                        try buff.writer.print("  -{c}, --{s}", .{ s, &flag_name });
                    } else {
                        try buff.writer.print("      --{s}", .{&flag_name});
                    }

                    const padding = max_name_len - field.name.len + 3;
                    for (0..padding) |_| try buff.writer.writeByte(' ');
                    try buff.writer.print("{s}\n", .{help});
                }

                return buff.toOwnedSlice();
            }
        };

        pub fn parse(self: *Self) !Result {
            if (self.parsed) return error.AlreadyParsed;
            self.parsed = true;

            const allocator = self.arena.allocator();
            var positionals: std.ArrayList([]const u8) = .empty;
            var unknown: std.ArrayList([]const u8) = .empty;
            var had_help = false;

            const program_name = self.iter.next() orelse return error.MissingProgramName;
            // Tokens must be drained after a --help
            if (cfg_help_enabled) {
                if (self.iter.peek()) |peeked| {
                    if (strEql(peeked, "--help")) {
                        _ = self.iter.next();
                        while (self.iter.next()) |_| {}
                        return .{
                            .prog = path.basename(program_name),
                            .opts = .{},
                            .positionals = try positionals.toOwnedSlice(allocator),
                            .unknown_options = try unknown.toOwnedSlice(allocator),
                            .had_help = true,
                        };
                    }
                }
            }

            var opts: Options = .{};
            if (cfg_parse_env)
                try initializeEnvOptsImpl(Options, &opts, allocator);
            // Populate the options and overwrite initialized values.
            try parseStructOptsImpl(
                Options,
                cfg_help_enabled,
                cfg_allow_unknown,
                &self.iter,
                &opts,
                &positionals,
                &unknown,
                &had_help,
                allocator,
            );

            const result: Result = .{
                .prog = path.basename(program_name),
                .opts = opts,
                .positionals = try positionals.toOwnedSlice(allocator),
                .unknown_options = try unknown.toOwnedSlice(allocator),
                .had_help = had_help,
            };

            if (!result.had_help) {
                inline for (std.meta.fields(Options)) |field| {
                    const fn_name = comptime "validate_" ++ field.name;
                    if (comptime @hasDecl(Options, fn_name)) {
                        switch (@typeInfo(field.type)) {
                            .optional => {
                                if (@field(result.opts, field.name)) |inner|
                                    try @field(Options, fn_name)(inner);
                            },
                            else => try @field(Options, fn_name)(@field(result.opts, field.name)),
                        }
                    }
                }
            }

            return result;
        }

        /// Frees all memory allocated during `parse`.
        ///
        /// Must be called after all use of the returned `Result` is complete.
        /// Prefer `defer parser.deinit()` immediately after `init`.
        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }
    };
}

// --- Module-level helpers ---

/// Reads a boolean config flag from `Options.config`, returning `default` if absent.
fn configFlag(comptime Options: type, comptime field: []const u8, comptime default: bool) bool {
    return if (@hasDecl(Options, "config") and @hasField(@TypeOf(Options.config), field))
        @field(Options.config, field)
    else
        default;
}

/// Reads a string config value from `Options.config`, returning `default` if absent.
fn configStr(comptime Options: type, comptime field: []const u8, comptime default: []const u8) []const u8 {
    return if (@hasDecl(Options, "config") and @hasField(@TypeOf(Options.config), field))
        @field(Options.config, field)
    else
        default;
}

/// Compile-time check that no two fields in `T.shorts` share the same character.
/// `context` is appended to the error message (e.g. " in subcommand `serve`").
fn checkShortsCollisions(comptime T: type, comptime context: []const u8) void {
    if (!@hasDecl(T, "shorts")) return;
    const s_fields = fields(@TypeOf(T.shorts));
    for (s_fields, 0..) |fa, i| {
        const ca: u8 = @field(T.shorts, fa.name);
        // Short opts must be alphabetic
        if (!isAlphabetic(ca)) @compileError("Short flag for `" ++ fa.name ++ "`" ++ context ++ " must be an alphabetic character");

        for (s_fields[i + 1 ..]) |fb| {
            const cb: u8 = @field(T.shorts, fb.name);
            if (ca == cb) {
                @compileError("Duplicate short flag '" ++ [_]u8{ca} ++ "' on fields `" ++
                    fa.name ++ "` and `" ++ fb.name ++ "`" ++ context);
            }
        }
    }
}

/// Compile-time check that every `validate_<field>` declaration in `T` is a
/// function with the correct signature. `context` is appended to error messages.
fn checkValidateFns(comptime T: type, comptime context: []const u8) void {
    for (fields(T)) |field| {
        const fn_name = "validate_" ++ field.name;
        if (@hasDecl(T, fn_name)) {
            const Fn = @TypeOf(@field(T, fn_name));
            const fn_info = @typeInfo(Fn);
            if (fn_info != .@"fn")
                @compileError(fn_name ++ context ++ " must be a function");
            const params = fn_info.@"fn".params;
            const expected_type = switch (@typeInfo(field.type)) {
                .optional => |opt| opt.child,
                else => field.type,
            };
            if (params.len != 1 or params[0].type != expected_type)
                @compileError(fn_name ++ context ++ " must take one argument of type " ++
                    @typeName(expected_type));
        }
    }
}

fn initializeEnvOptsImpl(
    comptime T: type,
    target: *T,
    allocator: Allocator,
) !void {
    const prefix = comptime configStr(T, "env_prefix", "");
    var envMap = try std.process.getEnvMap(allocator);
    defer envMap.deinit();
    var iter = envMap.iterator();
    while (iter.next()) |env| {
        const key = env.key_ptr.*;
        if (comptime prefix.len > 0) {
            if (key.len < prefix.len) continue;
            if (!std.ascii.eqlIgnoreCase(key[0..prefix.len], prefix)) continue;
        }
        const unprefixed = if (comptime prefix.len > 0) key[prefix.len..] else key;
        fieldloop: inline for (fields(T)) |field| {
            // []const []const u8 has no meaningful single-value env representation; skip.
            if (comptime field.type == []const []const u8) continue;
            if (std.ascii.eqlIgnoreCase(unprefixed, field.name)) {
                @field(target.*, field.name) = try parseEnvValueImpl(field.type, env.value_ptr.*, allocator);
                break :fieldloop;
            }
        }
    }
}

fn parseEnvValueImpl(comptime FieldType: type, value: []const u8, allocator: Allocator) !FieldType {
    return switch (FieldType) {
        bool => std.ascii.eqlIgnoreCase(value, "1") or
            std.ascii.eqlIgnoreCase(value, "true") or
            std.ascii.eqlIgnoreCase(value, "yes"),
        []const u8 => try allocator.dupe(u8, value),
        else => switch (@typeInfo(FieldType)) {
            .int => try std.fmt.parseInt(FieldType, value, 10),
            .float => try std.fmt.parseFloat(FieldType, value),
            .@"enum" => blk: {
                if (std.meta.stringToEnum(FieldType, value)) |val| break :blk val;
                if (strIndexOfScalar(value, '-') != null) {
                    const normalized = try allocator.dupe(u8, value);
                    std.mem.replaceScalar(u8, normalized, '-', '_');
                    if (std.meta.stringToEnum(FieldType, normalized)) |val| break :blk val;
                }
                return error.InvalidEnumValue;
            },
            .optional => |opt| try parseEnvValueImpl(opt.child, value, allocator),
            else => @compileError("Unsupported env var type: " ++ @typeName(FieldType)),
        },
    };
}

/// Shared flag-parsing loop used by both `Chizel` and `Chip`.
fn parseStructOptsImpl(
    comptime T: type,
    comptime cfg_help_enabled: bool,
    comptime cfg_allow_unknown: bool,
    iter: *ErasedIter,
    target: *T,
    positionals: *std.ArrayList([]const u8),
    unknown: *std.ArrayList([]const u8),
    had_help: *bool,
    allocator: Allocator,
) !void {
    while (iter.next()) |opt| {
        if (strEql(opt, "--")) {
            while (iter.next()) |pos| try positionals.append(allocator, pos);
            break;
        }
        if (cfg_help_enabled and strEql(opt, "--help")) {
            had_help.* = true;
            // Tokens must be drained after a call to help
            while (iter.next()) |_| {}
            return;
        }
        if (startsWith(u8, opt, "--")) {
            var key = opt[2..];
            var inline_val: ?[]const u8 = null;
            if (strIndexOfScalar(key, '=')) |i| {
                inline_val = key[i + 1 ..];
                key = key[0..i];
            }
            // Capture original key in case it needs to get stored in unknown options

            const original_key = key;
            const negated = startsWith(u8, key, "no-");
            if (negated) key = key[3..];

            // Long opts arrive as --long-opt so convert `-` to `_` before
            // matching against struct field names. Save the original for
            // unknown-option reporting so callers see the flag as typed.
            // For better performance we only perform the normalization
            // if a '-' is found in the string.
            // Each normalization requires a heap allocation so if we can
            // skip for non-long options it's probably better.
            const normalized_key = if (strIndexOfScalar(key, '-') != null) blk: {
                const buff = try allocator.dupe(u8, key);
                std.mem.replaceScalar(u8, buff, '-', '_');
                break :blk buff;
            } else key;

            var matched = false;
            blk: inline for (std.meta.fields(T)) |field| {
                if (strEql(normalized_key, field.name)) {
                    const base_type = switch (@typeInfo(field.type)) {
                        .optional => |o| o.child,
                        else => field.type,
                    };
                    if (negated and base_type != bool) return error.CannotNegate;
                    @field(target.*, field.name) = try parseNextImpl(
                        field.type,
                        iter,
                        negated,
                        inline_val,
                        allocator,
                    );
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
                                    @field(target.*, field.name) = try parseNextImpl(
                                        field.type,
                                        iter,
                                        false,
                                        null,
                                        allocator,
                                    );
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
                                @field(target.*, field.name) = try parseNextImpl(
                                    field.type,
                                    iter,
                                    false,
                                    null,
                                    allocator,
                                );
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

/// Parses the next token(s) from `iter` as a value of type `FieldType`.
fn parseNextImpl(
    comptime FieldType: type,
    iter: *ErasedIter,
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
            const s = inline_val orelse iter.next() orelse return error.MissingValue;
            break :blk try allocator.dupe(u8, s);
        },

        // Consumes tokens until the next flag token or end of args.
        // looksLikeOptionToken allows negative numbers like "-1" or "-3.14"
        // to be consumed as values rather than stopping the slice early.
        // An inline value (--flag=foo) is treated as the first element.
        []const []const u8 => blk: {
            var list: std.ArrayList([]const u8) = .empty;
            if (inline_val) |v| {
                if (v.len == 0) return error.MissingValue;
                try list.append(allocator, try allocator.dupe(u8, v));
            }
            while (iter.peek()) |s| {
                if (looksLikeOptionToken(s)) break;
                _ = iter.next();
                try list.append(allocator, try allocator.dupe(u8, s));
            }
            if (list.items.len == 0) return error.MissingValue;
            break :blk try list.toOwnedSlice(allocator);
        },

        else => switch (@typeInfo(FieldType)) {
            .int => blk: {
                const s = inline_val orelse iter.next() orelse return error.MissingValue;
                break :blk try std.fmt.parseInt(FieldType, s, 10);
            },
            .float => blk: {
                const s = inline_val orelse iter.next() orelse return error.MissingValue;
                break :blk try std.fmt.parseFloat(FieldType, s);
            },
            .@"enum" => blk: {
                const s = inline_val orelse iter.next() orelse return error.MissingValue;
                if (std.meta.stringToEnum(FieldType, s)) |val| break :blk val;
                // Normalize hyphens to underscores and retry "json-pretty" -> "json_pretty"
                if (strIndexOfScalar(s, '-') != null) {
                    const normalized = try allocator.dupe(u8, s);
                    std.mem.replaceScalar(u8, normalized, '-', '_');
                    if (std.meta.stringToEnum(FieldType, normalized)) |val| break :blk val;
                }
                return error.InvalidEnumValue;
            },
            .optional => |opt| try parseNextImpl(
                opt.child,
                iter,
                negated,
                inline_val,
                allocator,
            ),
            else => @compileError("Unsupported type: " ++ @typeName(FieldType)),
        },
    };
}

/// Writes the common header of `emitParsed`
/// eg. (prog, had_help, positionals, unknown_options).
fn emitResultHeader(
    prog: []const u8,
    had_help: bool,
    positionals: []const []const u8,
    unknown_options: []const []const u8,
    writer: anytype,
) !void {
    try writer.print("prog: {s}\n", .{prog});
    try writer.print("had_help: {}\n", .{had_help});

    try writer.print("positionals: [", .{});
    for (positionals, 0..) |p, i| {
        if (i > 0) try writer.print(", ", .{});
        try writer.print("{s}", .{p});
    }
    try writer.print("]\n", .{});

    if (unknown_options.len > 0) {
        try writer.print("unknown_options: [", .{});
        for (unknown_options, 0..) |u, i| {
            if (i > 0) try writer.print(", ", .{});
            try writer.print("{s}", .{u});
        }
        try writer.print("]\n", .{});
    }
}

// Simple wrappers for string operations to maintain less verbose code.
fn strIndexOfScalar(key: []const u8, needle: u8) ?usize {
    return std.mem.indexOfScalar(u8, key, needle);
}

fn strEql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// Converts a Zig field name '_' to a CLI flag name '-' at comptime.
// "dry_run" -> "dry-run"
fn fieldToFlag(comptime name: []const u8) [name.len]u8 {
    comptime {
        var buf: [name.len]u8 = undefined;
        for (name, 0..) |c, i| buf[i] = if (c == '_') '-' else c;
        return buf;
    }
}

// Type erased iterator used by the parser.
// The type is resolved at compile time and the next function
// is stored as a function pointer.
// Very complex in the backend but this improves the usability of the
// library's API.
const ErasedIter = struct {
    ptr: *anyopaque,
    next_fn: *const fn (*anyopaque) ?[]const u8,
    peeked: ?[]const u8 = null,
    has_peeked: bool = false,

    fn next(self: *@This()) ?[]const u8 {
        if (self.has_peeked) {
            self.has_peeked = false;
            return self.peeked;
        }
        return self.next_fn(self.ptr);
    }

    fn peek(self: *@This()) ?[]const u8 {
        if (!self.has_peeked) {
            self.peeked = self.next_fn(self.ptr);
            self.has_peeked = true;
        }
        return self.peeked;
    }
};

const ParseError = struct {
    field: []const u8 = "",
    got: []const u8 = "",
    expected: []const u8 = "",
};

// Returns true when `token` looks like the start of a flag (`--anything`
// or `-<alpha>`). Values like `-1` or `-3.14` return false so they are
// not mistakenly treated as flag boundaries in string-slice parsing.
fn looksLikeOptionToken(token: []const u8) bool {
    if (!startsWith(u8, token, "-") or token.len < 2) return false;
    return token[1] == '-' or isAlphabetic(token[1]);
}

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
            .@"enum" => try writer.print("{s}", .{@tagName(val)}),
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
