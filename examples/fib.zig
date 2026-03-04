const std = @import("std");
const chizel = @import("chizel");

fn fibonacci(range: i64) i64 {
    if (range <= 1) return range;

    var a: i64 = 0;
    var b: i64 = 1;
    var c: i64 = 0;
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
    var parser = try chizel.ArgParser.init(allocator, args, .{ .allow_unknown = false });
    defer parser.deinit();

    try parser.addOption(.{
        .name = "fib",
        .tag = .int,
        .help = "The fibonacci index to compute",
        .required = true,
        .validate = struct {
            fn check(v: chizel.Option.Value) bool {
                return v.int >= 0 and v.int <= 92;
            }
        }.check,
    });

    var result = try parser.parse();
    defer result.deinit();

    if (result.hadHelp()) {
        try result.printHelp();
        return;
    }

    if (result.getInt("fib")) |num| {
        const fib = fibonacci(num);
        std.debug.print("The {} fibonacci number is {}\n", .{ num, fib });
    }
}
