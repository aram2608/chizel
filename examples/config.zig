const std = @import("std");
const chizel = @import("chizel");
const ArgIterator = std.process.ArgIterator;

const Config = struct {
    host: []const u8 = "localhost",
    port: u16 = 8080,
    verbose: bool = false,

    pub const shorts = .{ .host = 'h', .port = 'p' };
    pub const help = .{ .host = "The host", .port = "The port", .verbose = "Verbosity" };
    pub const config = .{ .help_enabled = false, .allow_unknown = true };
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args: ArgIterator = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    const arena = std.heap.ArenaAllocator.init(alloc);
    var parser = chizel.Chizel(Config).init(&args, arena);
    defer parser.deinit();
    const opts = try parser.parse();

    // For debugging and viewing parsed options
    const dump = try opts.emitParsed(alloc);
    defer alloc.free(dump);
    std.debug.print("{s}\n", .{dump});
}
