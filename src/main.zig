const std = @import("std");
const chizel = @import("chizel");
const ArgIterator = std.process.ArgIterator;

const Opts = struct {
    host: []const u8 = "localhost",
    port: u16 = 8080,
    verbose: bool = false,
};

const FieldConfig = struct {
    short: ?[]const u8 = null,
    help: ?[]const u8 = null,
};

const OptConfig = struct {
    host: FieldConfig = .{ .short = "h", .help = "The host." },
    port: FieldConfig = .{ .short = "p", .help = "The port." },
    verbose: FieldConfig = .{},
};

// TODO: Positionals probably needs an extra field or something, I have no clue

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args: ArgIterator = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    const arena = std.heap.ArenaAllocator.init(alloc);
    var parser = chizel.ZiggyParse(Opts, OptConfig, *ArgIterator).init(&args, arena);
    defer parser.deinit();
    const opts = try parser.parse();

    _ = opts;
}
