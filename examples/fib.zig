const std = @import("std");
const chizel = @import("chizel");

fn fibonacci(range: i32) i32 {
    if (range <= 1) return range;

    var a: i32 = 0;
    var b: i32 = 1;
    var c: i32 = 0;
    for (1..@intCast(range)) |_| {
        c = a + b;
        a = b;
        b = c;
    }

    return b;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var args = try std.process.ArgIterator.initWithAllocator(allocator);
    defer args.deinit();
    var parser = try chizel.ArgParser.init(allocator, args);
    defer parser.deinit();

    try parser.addOption("foo", .int, "The fibonacci index to compute");

    var result = try parser.parse();
    defer result.deinit();

    if (result.getInt("foo")) |num| {
        const fib = fibonacci(num);
        std.debug.print("The {} fibonacci number is {}\n", .{ num, fib });
    }
}
