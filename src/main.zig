const std = @import("std");
const chizel = @import("chizel");
const ArgIterator = std.process.ArgIterator;

const Commands = union(enum) {
    foo: struct {
        foo: bool = false,

        pub const help = .{ .foo = "Nested bar bro" };
        pub const shorts = .{ .foo = 'f' };
    },
    bar: struct {
        bar: bool = false,

        pub const help = .{ .bar = "Nested bar bro" };
        pub const shorts = .{ .bar = 'b' };
    },

    long_name: struct {
        long_opt: bool = false,

        pub const help = .{ .long_opt = "I am a long opt " };
    },

    pub const help = .{ .foo = "Foo man", .bar = "Bar man", .long_name = "Long name" };
    pub const config = .{ .help_enabled = true };
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

    if (r.had_help) {
        const help = try r.printHelp(alloc);
        defer alloc.free(help);
        std.debug.print("{s}\n", .{help});
        return;
    }

    switch (r.opts) {
        .foo => |o| {
            if (o.foo) std.debug.print("FOO FOUND\n", .{});
        },
        .bar => |o| {
            if (o.bar) std.debug.print("BAR FOUND\n", .{});
        },
        .long_name => |o| {
            if (o.long_opt) std.debug.print("LONG OPT FOUND", .{});
        },
    }

    const dump = try r.emitParsed(alloc);
    defer alloc.free(dump);
    std.debug.print("{s}\n", .{dump});
}
