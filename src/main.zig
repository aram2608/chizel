const std = @import("std");
const chizel = @import("chizel");
const ArgIterator = std.process.ArgIterator;

const Commands = union(enum) {
    foo: struct {
        foo: bool = false,
    },
    bar: struct {
        bar: bool = false,
    },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args: ArgIterator = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    const arena = std.heap.ArenaAllocator.init(alloc);
    var parser = chizel.Chizel(Commands).init(&args, arena);
    defer parser.deinit();
    const r = try parser.parse();

    switch (r.opts) {
        .foo => {
            if (r.opts.foo.foo) std.debug.print("FOO FOUND\n", .{});
        },
        .bar => {
            if (r.opts.bar.bar) std.debug.print("BAR FOUND\n", .{});
        },
    }

    const dump = try r.emitParsed(alloc);
    defer alloc.free(dump);
    std.debug.print("{s}\n", .{dump});
}
