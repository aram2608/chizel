const std = @import("std");
const chizel = @import("chizel");

const Format = enum { json, yaml, toml, csv };
const Color = enum { auto, always, never };

const FormatterOpts = struct {
    format: Format = .json,
    color: Color = .auto,
    indent: u8 = 2,
    compact: bool = false,

    pub const shorts = .{ .format = 'f', .color = 'c', .indent = 'i' };
    pub const help = .{
        .format = "Output format (json, yaml, toml, csv)",
        .color = "Color output (auto, always, never)",
        .indent = "Indentation width",
        .compact = "Compact output",
    };
    pub const config = .{ .help_enabled = true };
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    const arena = std.heap.ArenaAllocator.init(alloc);
    var parser = chizel.Chip(FormatterOpts).init(&args, arena);
    defer parser.deinit();

    const result = try parser.parse();

    if (result.had_help) {
        const help = try result.printHelp(alloc);
        defer alloc.free(help);
        std.debug.print("{s}\n", .{help});
        return;
    }

    const o = result.opts;
    std.debug.print("format={s} color={s} indent={} compact={}\n", .{
        @tagName(o.format),
        @tagName(o.color),
        o.indent,
        o.compact,
    });

    for (result.positionals) |file| {
        std.debug.print("  input: {s}\n", .{file});
    }
}
