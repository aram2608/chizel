const std = @import("std");
const defaultValue = std.builtin.Type.StructField.defaultValue;
const startsWith = std.mem.startsWith;
const Allocator = std.mem.Allocator;
const isAlphabetic = std.ascii.isAlphabetic;

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
///     // Only list fields that need a short flag — others are long-flag only.
///     pub const shorts = .{ .host = 'h', .port = 'p' };
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
/// var parser = ZiggyParse(Opts, *ArgIterator).init(&args, arena, false);
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
/// - `unknown_options` — unrecognised flag names (only populated when
///                       `allow_unknown = true`; otherwise `parse()` errors).
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
/// Applying `--no-` to a non-boolean flag is an error (`error.CanNotNegate`).
///
/// ## Unknown flags
///
/// Pass `allow_unknown = true` to `init` to collect unrecognised flags in
/// `Result.unknown_options` rather than returning `error.UnknownOption`.
/// Unknown short flags are stored without the leading `-`.
///
/// ## Lifetime
///
/// All heap values in the returned `Result` (strings, slices, positionals) are
/// owned by the parser's arena. Accessing them after `parser.deinit()` is
/// undefined behaviour. Always `defer parser.deinit()` immediately after `init`:
///
/// ```zig
/// var parser = ZiggyParse(Opts, *ArgIterator).init(&args, arena, false);
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

    return struct {
        arena: std.heap.ArenaAllocator,
        iter: Iter(IterType),
        parsed: bool = false,
        allow_unknown: bool,
        const Self = @This();

        /// Create a parser.
        ///
        /// - `inner`         — the token source; `argv[0]` is consumed on the
        ///                     first call to `parse()`.
        /// - `arena`         — taken by value; freed by `deinit()`.
        /// - `allow_unknown` — when `true`, unrecognised flags are collected in
        ///                     `Result.unknown_options`; when `false`, they
        ///                     return `error.UnknownOption`.
        pub fn init(inner: IterType, arena: std.heap.ArenaAllocator, allow_unknown: bool) Self {
            return .{
                .arena = arena,
                .iter = .{ .inner = inner },
                .allow_unknown = allow_unknown,
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
                    self.peeked = self.inner.next();
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

            pub fn printHelp(self: *const @This()) ![]const u8 {
                // _ = writer;
                // FOR DEVELOPMENT REMOVE THIS WHEN DONE //
                // A writer anytype should be passed in so that the caller can do whatever they
                // want with the output, this should also return !void
                var buff = std.io.Writer.Allocating.init(std.heap.page_allocator);
                try buff.writer.print("Usage: {s} [OPTIONS]\nOptions:\n", .{self.prog});

                if (@hasDecl(Options, "help")) {
                    inline for (std.meta.fields(Options)) |field| {
                        if (@hasField(@TypeOf(Options.help), field.name)) {
                            const help: []const u8 = @field(Options.help, field.name);
                            if (@hasField(@TypeOf(Options.shorts), field.name)) {
                                const s: u8 = @field(Options.shorts, field.name);
                                try buff.writer.print("-{c} --{s}  {s}\n", .{ s, field.name, help });
                            } else {
                                try buff.writer.print("--{s}{s:40}\n", .{ field.name, help });
                            }
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
            inline for (std.meta.fields(Options)) |field| {
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
        /// - `error.AlreadyParsed`      — `parse` was called more than once.
        /// - `error.MissingProgramName` — the iterator was empty (no `argv[0]`).
        /// - `error.MissingValue`       — a non-boolean flag had no following token.
        /// - `error.CanNotNegate`       — `--no-` was applied to a non-boolean field.
        /// - `error.UnknownOption`      — an unrecognised flag appeared and
        ///                               `allow_unknown` is `false`.
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
                if (std.mem.eql(u8, opt, "--")) {
                    while (self.iter.next()) |pos| try positionals.append(allocator, pos);
                    break;
                }
                if (std.mem.eql(u8, opt, "--help") or std.mem.eql(u8, opt, "-h")) {
                    had_help = true;
                    continue;
                }
                if (startsWith(u8, opt, "--")) {
                    var key = opt[2..];
                    const negated = startsWith(u8, key, "no-");
                    if (negated) key = key[3..];
                    var matched = false;
                    inline for (std.meta.fields(Options)) |field| {
                        if (std.mem.eql(u8, key, field.name)) {
                            if (negated and field.type != bool) return error.CanNotNegate;
                            @field(defaults, field.name) = try self.parseNext(field.type, negated, allocator);
                            matched = true;
                        }
                    }
                    if (!matched) {
                        if (self.allow_unknown) try unknown.append(allocator, key) else return error.UnknownOption;
                    }
                } else if (startsWith(u8, opt, "-")) {
                    const key = opt[1..];
                    var matched = false;
                    if (@hasDecl(Options, "shorts")) {
                        inline for (std.meta.fields(Options)) |field| {
                            if (@hasField(@TypeOf(Options.shorts), field.name)) {
                                const s: u8 = @field(Options.shorts, field.name);
                                if (key.len == 1 and key[0] == s) {
                                    @field(defaults, field.name) = try self.parseNext(field.type, false, allocator);
                                    matched = true;
                                }
                            }
                        }
                    }
                    if (!matched) {
                        if (self.allow_unknown) try unknown.append(allocator, key) else return error.UnknownOption;
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

        fn parseNext(self: *Self, comptime FieldType: type, negated: bool, allocator: Allocator) !FieldType {
            return switch (FieldType) {
                bool => !negated,

                []const u8 => blk: {
                    const s = self.iter.next() orelse return error.MissingValue;
                    break :blk try allocator.dupe(u8, s);
                },

                // Consumes tokens until the next flag token or end of args.
                // looksLikeOptionToken allows negative numbers like "-1" or "-3.14"
                // to be consumed as values rather than stopping the slice early.
                []const []const u8 => blk: {
                    var list: std.ArrayList([]const u8) = .empty;
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
                        const s = self.iter.next() orelse return error.MissingValue;
                        break :blk try std.fmt.parseInt(FieldType, s, 10);
                    },
                    .float => blk: {
                        const s = self.iter.next() orelse return error.MissingValue;
                        break :blk try std.fmt.parseFloat(FieldType, s);
                    },
                    .optional => |opt| try self.parseNext(opt.child, negated, allocator),
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
