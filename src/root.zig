//! chizel: a lightweight, comptime struct-driven CLI argument parser for Zig.
//!
//! Define your options as a plain Zig struct with default values and chizel
//! handles the rest. No runtime setup, no registration calls. All config lives
//! in the struct itself.
//!
//! ## Quick start
//!
//! ```zig
//! const chizel = @import("chizel");
//! const std = @import("std");
//!
//! const Opts = struct {
//!     host: []const u8 = "localhost",
//!     port: u16        = 8080,
//!     verbose: bool    = false,
//!
//!     pub const shorts = .{ .host = 'h', .port = 'p' };
//!     pub const help   = .{ .host = "Server host", .port = "Server port", .verbose = "Verbose output" };
//! };
//!
//! pub fn main() !void {
//!     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//!     defer _ = gpa.deinit();
//!     const alloc = gpa.allocator();
//!
//!     var args = try std.process.argsWithAllocator(alloc);
//!     defer args.deinit();
//!
//!     const arena = std.heap.ArenaAllocator.init(alloc);
//!     var parser = chizel.Chizel(Opts).init(&args, arena);
//!     defer parser.deinit();
//!
//!     const result = try parser.parse();
//!
//!     if (result.had_help) {
//!         const help = try result.printHelp(alloc);
//!         defer alloc.free(help);
//!         std.debug.print("{s}\n", .{help});
//!         return;
//!     }
//!
//!     // result.prog:        argv[0] basename
//!     // result.opts:        populated Opts struct
//!     // result.positionals: non-flag tokens
//! }
//! ```
pub const Chizel = @import("chizel/chizel.zig").Chizel;
pub const genCompletions = @import("chizel/completions.zig").genCompletions;

test {
    _ = @import("chizel/tests.zig");
}
