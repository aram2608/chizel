const std = @import("std");
const defaultValue = std.builtin.Type.StructField.defaultValue;
const startsWith = std.mem.startsWith;
const Allocator = std.mem.Allocator;

/// ZiggyParse — comptime struct-driven CLI argument parser.
///
/// A lightweight alternative to `ArgParser` for simple use cases. Define your
/// options as a plain Zig struct with default values and ZiggyParse handles the rest.
/// All allocations are backed by an `ArenaAllocator` and freed with a single `deinit`.
///
/// ## Requirements
///
/// Every field in `Options` must have a default value. Fields without a default
/// cause a compile error. For fields that are logically required (no sensible default),
/// use `?T = null` — the type system then forces the caller to handle the missing case:
///
/// ```zig
/// const Opts = struct {
///     host: ?[]const u8 = null,   // required — caller must handle null
///     port: u16 = 8080,
///     verbose: bool = false,
/// };
/// ```
///
/// ## Usage
///
/// ```zig
/// var args = try std.process.ArgIterator.initWithAllocator(allocator);
/// defer args.deinit();
///
/// var arena = std.heap.ArenaAllocator.init(allocator);
/// var parser = ZiggyParse(Opts, *ArgIterator).init(&args, arena);
/// defer parser.deinit();
///
/// const opts = try parser.parse();
/// const host = opts.host orelse return error.MissingHost;
/// ```
///
/// ## Supported field types
///
/// | Zig type       | Behaviour                                      |
/// |----------------|------------------------------------------------|
/// | `bool`         | Flag presence sets `true`; absent keeps default |
/// | `[]const u8`   | Consumes next token; duped into arena           |
/// | `i*` / `u*`    | Parses next token as integer                   |
/// | `f*`           | Parses next token as float                     |
/// | `?T`           | Parses as `T` when flag present, else `null`   |
///
/// ## Lifetime
///
/// All `[]const u8` values in the returned `Options` are owned by the parser's
/// arena. Accessing them after `parser.deinit()` is undefined behaviour.
/// Always `defer parser.deinit()` before using the parsed result:
///
/// ```zig
/// var parser = ZiggyParse(Opts, *ArgIterator).init(&args, arena);
/// defer parser.deinit();              // runs last — correct
/// const opts = try parser.parse();    // opts borrows from arena
/// ```
pub fn ZiggyParse(
    comptime Options: type,
    comptime OptionsConfig: type,
    comptime IterType: type,
) type {
    if (@typeInfo(Options) != .@"struct") @compileError("ZiggyParse: `Options` must be a struct.");
    if (@typeInfo(OptionsConfig) != .@"struct") @compileError("ZiggyParse: `OptionsConfig` must be a struct.");

    // Require all fields to have defaults so initDefaults() is always safe.
    inline for (std.meta.fields(Options)) |field| {
        if (field.default_value_ptr == null) {
            @compileError("ZiggyParse: field `" ++ field.name ++ "` must have a default value. " ++
                "For required arguments use `?T = null` or switch to ArgParser.");
        }
    }

    return struct {
        // Allocated values are stored internally
        arena: std.heap.ArenaAllocator,
        iter: Iter(IterType),
        parsed: bool = false,
        const Self = @This();

        pub fn init(inner: IterType, arena: std.heap.ArenaAllocator) Self {
            return .{
                .arena = arena,
                .iter = .{ .inner = inner },
            };
        }

        /// Frees all memory allocated during `parse`.
        ///
        /// Must be called after all use of the returned `Options` is complete.
        /// Prefer `defer parser.deinit()` immediately after `init`.
        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }

        fn Iter(comptime T: type) type {
            return struct {
                inner: T,

                fn next(self: *@This()) ?[]const u8 {
                    return self.inner.next();
                }
            };
        }

        fn initDefaults() Options {
            var val: Options = undefined;
            inline for (std.meta.fields(Options)) |field| {
                // .? is safe — validated at comptime above that all fields have defaults.
                @field(val, field.name) = defaultValue(field).?;
            }
            return val;
        }

        /// Parse the argument iterator and return the populated `Options` struct.
        ///
        /// May only be called once. Returns `error.AlreadyParsed` on subsequent calls.
        /// Unknown flags and non-flag tokens are silently skipped.
        ///
        /// Errors:
        /// - `error.AlreadyParsed` — `parse` was called more than once.
        /// - `error.MissingValue`  — a non-boolean flag appeared without a following value.
        pub fn parse(self: *Self) !Options {
            if (self.parsed) return error.AlreadyParsed;

            const allocator = self.arena.allocator();
            self.parsed = true;
            var defaults = initDefaults();
            // Comptime-initialized so @field access in inline for is safe.
            const cfg: OptionsConfig = .{};

            while (self.iter.next()) |opt| {
                if (startsWith(u8, opt, "--")) {
                    const key = opt[2..];
                    inline for (std.meta.fields(Options)) |field| {
                        if (std.mem.eql(u8, key, field.name)) {
                            @field(defaults, field.name) = try self.parseNext(field.type, allocator);
                        }
                    }
                } else if (startsWith(u8, opt, "-")) {
                    const key = opt[1..];
                    inline for (std.meta.fields(Options)) |field| {
                        const field_cfg = @field(cfg, field.name);
                        if (field_cfg.short) |s| {
                            if (std.mem.eql(u8, key, s)) {
                                @field(defaults, field.name) = try self.parseNext(field.type, allocator);
                            }
                        }
                    }
                }
            }

            return defaults;
        }

        fn parseNext(self: *Self, comptime FieldType: type, allocator: Allocator) !FieldType {
            return switch (FieldType) {
                bool => true,

                []const u8 => blk: {
                    const s = self.iter.next() orelse return error.MissingValue;
                    break :blk try allocator.dupe(u8, s);
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
                    .optional => |opt| try self.parseNext(opt.child, allocator),
                    else => @compileError("Unsupported type: " ++ @typeName(FieldType)),
                },
            };
        }
    };
}
