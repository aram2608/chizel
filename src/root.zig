//! chizel — a lightweight CLI argument parser for Zig.
//!
//! ## Quick start
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
//! ## Value-resolution order
//!
//! For every registered option, chizel resolves the final value in this order:
//!
//!   CLI flag  >  environment variable (`env`)  >  static default (`default`)
//!
//! ## Lifetime
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
//! ## Supported types
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
pub const QuickParse = @import("chizel/QuickParse.zig");

test {
    _ = @import("chizel/tests.zig");
}
