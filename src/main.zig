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

    try parser.addOption("foo", .boolean, "Foo man");
    try parser.addOption("bar", .boolean, "Bar bro");
    try parser.addOption("baz", .string, "Baz baby");
    try parser.addOption("buzz", .string_slice, "Buzz buzz");

    var result = try parser.parse();
    defer result.deinit();

    if (result.hadHelp()) {
        result.printHelp();
        return;
    }

    const foo_val = result.getBool("foo") orelse false;
    std.debug.print("foo: {}\n", .{foo_val});

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
}
