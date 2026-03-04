//! chizel — a lightweight CLI argument parser for Zig.
//!
//! chizel provides two parsers depending on how much control you need:
//!
//! | Parser       | Style                  | Best for                              |
//! |--------------|------------------------|---------------------------------------|
//! | `ArgParser`  | Runtime, feature-rich  | Complex CLIs, env vars, help, validation |
//! | `ZiggyParse` | Comptime struct-driven | Simple scripts, minimal boilerplate   |
//!
//! ## ZiggyParse — quick start
//!
//! Define your options as a struct with defaults and parse in three lines:
//!
//! ```zig
//! const chizel = @import("chizel");
//! const ArgIterator = std.process.ArgIterator;
//!
//! const Opts = struct {
//!     host: []const u8 = "localhost",
//!     port: u16 = 8080,
//!     verbose: bool = false,
//! };
//!
//! var args = try ArgIterator.initWithAllocator(allocator);
//! defer args.deinit();
//!
//! var arena = std.heap.ArenaAllocator.init(allocator);
//! var parser = chizel.ZiggyParse(Opts, *ArgIterator).init(&args, arena);
//! defer parser.deinit();
//!
//! const opts = try parser.parse();
//! ```
//!
//! ## ArgParser — quick start
//!
//! Register options explicitly for full control over types, env vars, and help text:
//!
//! ```zig
//! const chizel = @import("chizel");
//!
//! var args = try std.process.ArgIterator.initWithAllocator(allocator);
//! defer args.deinit();
//!
//! var parser = try chizel.ArgParser.init(allocator, args, .{ .allow_unknown = false });
//! defer parser.deinit();
//!
//! try parser.addOption(.{ .name = "port", .tag = .int, .default = .{ .int = 8080 } });
//!
//! var result = try parser.parse();
//! defer result.deinit();
//!
//! if (result.hadHelp()) { try result.printHelp(); return; }
//!
//! const port = result.getInt("port") orelse 8080;
//! ```
//!
//! ## ArgParser — value-resolution order
//!
//! For every registered option, chizel resolves the final value in this order:
//!
//!   CLI flag  >  environment variable (`env`)  >  static default (`default`)
//!
//! ## ArgParser — lifetime
//!
//! `ParseResult` borrows memory from `ArgParser` for `string` and `string_slice`
//! values.  Always deinit in reverse declaration order:
//!
//! ```zig
//! var parser = try chizel.ArgParser.init(allocator, args, .{ .allow_unknown = false });
//! defer parser.deinit();       // runs second — correct
//!
//! var result = try parser.parse();
//! defer result.deinit();       // runs first  — correct
//! ```
//!
//! ## ArgParser — supported types
//!
//! | `Option.Tag`   | Zig type        | Accessor              |
//! |----------------|-----------------|-----------------------|
//! | `.boolean`     | `bool`          | `isPresent`           |
//! | `.int`         | `i64`           | `getInt`              |
//! | `.float`       | `f64`           | `getFloat`            |
//! | `.string`      | `[]const u8`    | `getString`           |
//! | `.string_slice`| `[][]const u8`  | `getStringSlice`      |

pub const ArgParser = @import("chizel/ArgParser.zig");
pub const ParseResult = @import("chizel/ParseResult.zig");
pub const Option = @import("chizel/Option.zig");
pub const Completions = @import("chizel/Completions.zig");
pub const ZiggyParse = @import("chizel/ziggyparse.zig").ZiggyParse;

test {
    _ = @import("chizel/tests.zig");
}
