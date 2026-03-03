const std = @import("std");
const chizel = @import("chizel");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.ArgIterator.initWithAllocator(allocator);
    defer args.deinit();
    var parser = try chizel.ArgParser.init(allocator, args);
    defer parser.deinit();

    try parser.addOption(.{
        .name = "foo",
        .tag = .boolean,
        .short = 'f',
        .default = .{ .boolean = true },
        .help = "Foo man",
    });
    try parser.addOption(.{ .name = "bar", .tag = .boolean, .help = "Bar bro" });
    try parser.addOption(.{ .name = "baz", .tag = .string, .help = "Baz baby" });
    try parser.addOption(.{ .name = "buzz", .tag = .string_slice, .help = "Buzz buzz" });

    var result = try parser.parse();
    defer result.deinit();

    try parser.createAutoCompletion(.zsh);

    if (result.hadHelp()) {
        try result.printHelp();
        return;
    }

    const foo_present = result.isPresent("foo");
    std.debug.print("foo: {}\n", .{foo_present});

    const bar_present = result.isPresent("bar");
    std.debug.print("bar present: {}\n", .{bar_present});

    if (result.getString("baz")) |s| {
        std.debug.print("baz: {s}\n", .{s});
    } else {
        std.debug.print("baz: not provided\n", .{});
    }

    if (result.getStringSlice("buzz")) |slice| {
        std.debug.print("buzz:", .{});
        for (slice) |s| {
            std.debug.print(" {s}", .{s});
        }
        std.debug.print("\n", .{});
    } else {
        std.debug.print("buzz: not provided\n", .{});
    }

    const positionals = result.getPositionals();
    if (positionals.len > 0) {
        std.debug.print("positionals:", .{});
        for (positionals) |p| std.debug.print(" {s}", .{p});
        std.debug.print("\n", .{});
    }
}
