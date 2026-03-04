const std = @import("std");
const chizel = @import("chizel");
const ArgIterator = std.process.ArgIterator;

const Opts = struct {
    host: []const u8 = "localhost",
    port: u16 = 8080,
    verbose: bool = false,

    pub const shorts = .{ .host = 'h', .port = 'p' };
    pub const help = .{ .host = "The host", .port = "The port", .verbose = "Verbosity" };
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args: ArgIterator = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    const arena = std.heap.ArenaAllocator.init(alloc);
    var parser = chizel.ZiggyParse(Opts, *ArgIterator).init(&args, arena, false);
    defer parser.deinit();
    const opts = try parser.parse();

    if (opts.had_help) {
        const help = try opts.printHelp();
        std.debug.print("{s}\n", .{help});
    }

    std.debug.print("{}\n", .{opts});
}
