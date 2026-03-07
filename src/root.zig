//! chizel: a lightweight, comptime struct-driven CLI argument parser for Zig.
//!
//! Two parsers are provided:
//!
//! - `Chip(Opts)` for simple single-command programs (struct-based options)
//! - `Chizel(Cmds)` for programs with subcommands (union-based)
//!
//! ## Quick start (single command)
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
//!     var parser = chizel.Chip(Opts).init(&args, arena);
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
//!
//! ## Quick start (subcommands)
//!
//! ```zig
//! const Cmds = union(enum) {
//!     serve: struct { port: u16 = 8080, pub const shorts = .{ .port = 'p' }; },
//!     build: struct { release: bool = false },
//! };
//!
//! const arena = std.heap.ArenaAllocator.init(alloc);
//! var parser = chizel.Chizel(Cmds).init(&args, arena);
//! defer parser.deinit();
//!
//! const result = try parser.parse();
//! switch (result.opts) {
//!     .serve => |s| std.debug.print("port={}\n", .{s.port}),
//!     .build => |b| std.debug.print("release={}\n", .{b.release}),
//! }
//! ```
pub const Chip = @import("chizel/chizel.zig").Chip;
pub const Chizel = @import("chizel/chizel.zig").Chizel;
pub const genCompletions = @import("chizel/completions.zig").genCompletions;

test {
    _ = @import("chizel/tests.zig");
}
